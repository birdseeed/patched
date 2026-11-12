import Foundation
import Darwin

public enum UnpackLimits {
    public static let dittoTimeout: TimeInterval = 15 * 60
    public static let attachTimeout: TimeInterval = 10 * 60
    public static let detachTimeout: TimeInterval = 60
}

/// Disk budget for unpacking, so a small archive cannot expand until the volume is full.
public struct UnpackBudget: Sendable, Equatable {
    /// Free space required before unpacking: `reserveBytes + reservePerDownloadByte × download size`.
    public var reserveBytes: Int64
    public var reservePerDownloadByte: Int64
    /// Staged bytes may not exceed `max(maxStagedFloor, maxStagedPerDownloadByte × download size)`.
    public var maxStagedFloor: Int64
    public var maxStagedPerDownloadByte: Int64
    /// Unpacking stops if free space falls below this.
    public var minFreeDuring: Int64
    /// Unpacked trees with more entries than this are refused; it also bounds every scan.
    public var maxEntries: Int
    public var pollInterval: TimeInterval

    public init(reserveBytes: Int64, reservePerDownloadByte: Int64, maxStagedFloor: Int64,
                maxStagedPerDownloadByte: Int64, minFreeDuring: Int64, maxEntries: Int = 200_000,
                pollInterval: TimeInterval = 0.25) {
        self.reserveBytes = reserveBytes; self.reservePerDownloadByte = reservePerDownloadByte
        self.maxStagedFloor = maxStagedFloor; self.maxStagedPerDownloadByte = maxStagedPerDownloadByte
        self.minFreeDuring = minFreeDuring; self.maxEntries = maxEntries; self.pollInterval = pollInterval
    }

    static let gib: Int64 = 1024 * 1024 * 1024
    public static let standard = UnpackBudget(reserveBytes: 2 * gib, reservePerDownloadByte: 4, maxStagedFloor: 8 * gib,
                                              maxStagedPerDownloadByte: 6, minFreeDuring: 1 * gib)

    public func maxStaged(downloadBytes: Int64) -> Int64 { max(maxStagedFloor, maxStagedPerDownloadByte * downloadBytes) }

    /// Refuses unless the staging volume has room for the expected expansion.
    public func preflight(volume: String, downloadBytes: Int64) throws {
        let needed = reserveBytes + reservePerDownloadByte * downloadBytes
        guard let free = FileSafety.freeBytes(volume) else { throw InstallRefusal.io("cannot read free space on \(volume)") }
        guard free >= needed else {
            throw InstallRefusal.unpackTooLarge("\(free) bytes free on the staging volume, \(needed) needed")
        }
    }

    /// One budget check: free space first (cheap), then a scan that stops as soon as it passes the byte
    /// or entry limit. A reason to stop, or nil.
    public func check(_ path: String, volume: String, downloadBytes: Int64) -> String? {
        if let free = FileSafety.freeBytes(volume), free < minFreeDuring { return "free space fell to \(free) bytes" }
        let limit = maxStaged(downloadBytes: downloadBytes)
        let scan = FileSafety.boundedTreeScan(path, maxBytes: limit, maxEntries: maxEntries)
        if scan.entries > maxEntries { return "more than \(maxEntries) entries" }
        if scan.bytes > limit { return "unpacked more than the \(limit) byte budget" }
        return nil
    }

    /// Polled on a separate thread while ditto runs, and once more after it exits.
    public func watchdog(watching path: String, volume: String, downloadBytes: Int64) -> @Sendable () -> String? {
        let budget = self
        return { budget.check(path, volume: volume, downloadBytes: downloadBytes) }
    }
}

/// zip and dmg unpacking with fixed tools. Nothing here decides which bundle to trust.
public enum Unpacker {
    /// `ditto -x -k <zip> <destination>`; destination must be an empty private directory.
    public static func extractZip(_ archive: String, into destination: String, budget: UnpackBudget? = nil,
                                  downloadBytes: Int64 = 0) throws {
        let result = ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", archive, destination], timeout: UnpackLimits.dittoTimeout,
                                       pollInterval: budget?.pollInterval ?? 0.25,
                                       watchdog: budget?.watchdog(watching: destination, volume: destination, downloadBytes: downloadBytes))
        if let reason = result.abortedBy { throw InstallRefusal.unpackTooLarge(reason) }
        guard result.succeeded else { throw InstallRefusal.unpackFailed("ditto: \(result.summary)") }
    }

    /// `ditto <source bundle> <destination bundle>`, optionally under an unpack budget.
    public static func copyBundle(_ source: String, to destination: String, budget: UnpackBudget? = nil,
                                  downloadBytes: Int64 = 0) throws {
        let volume = (destination as NSString).deletingLastPathComponent
        let result = ProcessRunner.run("/usr/bin/ditto", [source, destination], timeout: UnpackLimits.dittoTimeout,
                                       pollInterval: budget?.pollInterval ?? 0.25,
                                       watchdog: budget?.watchdog(watching: destination, volume: volume, downloadBytes: downloadBytes))
        if let reason = result.abortedBy { throw InstallRefusal.unpackTooLarge(reason) }
        guard result.succeeded else { throw InstallRefusal.unpackFailed("ditto copy: \(result.summary)") }
    }

    /// True when something is mounted at `path` (its device differs from its parent's).
    public static func isMountPoint(_ path: String) -> Bool {
        guard let here = FileSafety.lstatInfo(path), let parent = FileSafety.lstatInfo((path as NSString).deletingLastPathComponent) else {
            return false
        }
        return here.st_dev != parent.st_dev
    }

    /// Attaches read-only, unbrowsed, with verification on and stdin closed so a licence agreement or
    /// password prompt fails instead of hanging. On any failure the image is detached before returning.
    public static func attachDiskImage(_ image: String, at mountPoint: String) throws {
        let result = ProcessRunner.run("/usr/bin/hdiutil",
                                       ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noautofsck",
                                        // Encrypted images read an (empty) password from /dev/null and fail
                                        // instead of showing a password dialog.
                                        "-stdinpass",
                                        "-mountpoint", mountPoint, image],
                                       timeout: UnpackLimits.attachTimeout)
        guard result.succeeded, isMountPoint(mountPoint) else {
            detachDiskImage(at: mountPoint)
            let detail = result.timedOut ? "timed out (licence agreement or prompt?)" : result.summary
            throw InstallRefusal.unpackFailed("hdiutil attach: \(detail)")
        }
    }

    /// Detaches, then forces if the polite detach fails. Safe to call when nothing is mounted.
    @discardableResult
    public static func detachDiskImage(at mountPoint: String) -> Bool {
        guard isMountPoint(mountPoint) else { return true }
        _ = ProcessRunner.run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"], timeout: UnpackLimits.detachTimeout)
        if !isMountPoint(mountPoint) { return true }
        _ = ProcessRunner.run("/usr/bin/hdiutil", ["detach", mountPoint, "-force", "-quiet"], timeout: UnpackLimits.detachTimeout)
        return !isMountPoint(mountPoint)
    }
}

/// Picks the one bundle in an unpacked archive that is an update for the installed app.
public enum BundleSelector {
    /// Candidates are real (non-symlink) `.app` directories at the top level, or one level down inside a
    /// plain folder. Exactly one may have the installed app's bundle ID. With no bundle ID (a Self Service entry
    /// that names none) there must be exactly one readable app in the download.
    public static func select(in root: String, bundleID: String?) throws -> String {
        var candidates: [String] = []
        func appsIn(_ directory: String) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names.sorted().compactMap { name in
                let path = directory + "/" + name
                guard let info = FileSafety.lstatInfo(path), FileSafety.isDirectory(info) else { return nil }
                return path
            }
        }
        for entry in appsIn(root) {
            if entry.lowercased().hasSuffix(".app") { candidates.append(entry); continue }
            for inner in appsIn(entry) where inner.lowercased().hasSuffix(".app") { candidates.append(inner) }
        }
        var matches: [String] = []
        var seen: [String] = []
        for candidate in candidates {
            guard let facts = try? BundleFacts.read(bundleAt: candidate) else { continue }
            seen.append("\((candidate as NSString).lastPathComponent)=\(facts.bundleID)")
            if bundleID == nil || facts.bundleID == bundleID { matches.append(candidate) }
        }
        if matches.isEmpty {
            throw InstallRefusal.bundleNotFound("expected \(bundleID ?? "an app"), found " + (seen.isEmpty ? "no apps" : seen.joined(separator: ", ")))
        }
        if matches.count > 1 {
            throw InstallRefusal.ambiguousBundle(matches.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        }
        let chosen = matches[0]
        try FileSafety.requireContainedSymlinks(chosen)
        return chosen
    }
}
