import Foundation
import Darwin
import UpdateSources

/// Where the installer keeps downloads, journals and backups. Tests and `--applications-root` runs
/// point these at a temporary state root so they never mix with the real ones.
public struct InstallerLocations: Sendable, Equatable {
    public let downloads: String
    public let transactions: String
    public let backups: String
    public let migrationNotice: String?
    var migrationLease: MigrationLease?

    public init(downloads: String, transactions: String, backups: String, migrationNotice: String? = nil) {
        self.downloads = downloads; self.transactions = transactions; self.backups = backups
        self.migrationNotice = migrationNotice
    }

    public static func == (lhs: InstallerLocations, rhs: InstallerLocations) -> Bool {
        lhs.downloads == rhs.downloads && lhs.transactions == rhs.transactions
            && lhs.backups == rhs.backups && lhs.migrationNotice == rhs.migrationNotice
    }

    /// The selected support root also holds the shared catalogue.
    public var supportRoot: String { (transactions as NSString).deletingLastPathComponent }

    /// Select Patched/Updater folders, resuming a safe legacy rename before returning paths.
    public static func standard() throws -> InstallerLocations {
        try RealStateTripwire.check("InstallerLocations.standard()")
        guard let home = accountHome() else { throw InstallRefusal.io("cannot find the current user's home folder") }
        return try standard(home: home)
    }

    /// Explicit home for isolated migration checks. Production callers use `standard()`.
    /// The checkpoint hook is for crash injection; it runs only after durable writes or renames.
    public static func standard(home: String, migrationCheckpoint: (String) throws -> Void = { _ in }) throws -> InstallerLocations {
        try LegacyStateMigration.locations(home: home, checkpoint: migrationCheckpoint)
    }

    /// Everything under one directory (tests, temporary applications roots).
    public static func under(_ root: String) -> InstallerLocations {
        InstallerLocations(downloads: root + "/downloads", transactions: root + "/transactions", backups: root + "/backups")
    }

    /// Home from the account database, never from `$HOME`.
    static func accountHome() -> String? {
        var entry = passwd(), found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 65_536)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(geteuid(), &entry, bytes.baseAddress!, bytes.count, &found) == 0,
                  found != nil, let path = entry.pw_dir else { return nil }
            return String(validatingCString: path)
        }
    }

    func prepare() throws {
        try FileSafety.makePrivateDirectory(downloads)
        try FileSafety.makePrivateDirectory(transactions)
        try FileSafety.makePrivateDirectory(backups)
    }
}

/// The handful of Info.plist facts the installer relies on, read straight from disk.
public struct BundleFacts: Sendable, Equatable {
    public let bundleID: String
    public let shortVersion: String?
    public let build: String?
    /// Sparkle `SUPublicEDKey` (base64), if the bundle has one.
    public let sparklePublicEDKey: String?

    public init(bundleID: String, shortVersion: String?, build: String?, sparklePublicEDKey: String?) {
        self.bundleID = bundleID; self.shortVersion = shortVersion; self.build = build
        self.sparklePublicEDKey = sparklePublicEDKey
    }

    public static func read(bundleAt path: String) throws -> BundleFacts {
        let plistPath = path + "/Contents/Info.plist"
        guard let data = FileSafety.readSmallFile(plistPath, limit: 2 * 1024 * 1024) else {
            throw InstallRefusal.unsafePath("\(plistPath) is missing, not a regular file, or too large")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw InstallRefusal.unsafePath("\(plistPath) is not a property list dictionary")
        }
        guard let id = plist["CFBundleIdentifier"] as? String, isSafeBundleID(id) else {
            throw InstallRefusal.unsafePath("\(plistPath) has no usable CFBundleIdentifier")
        }
        func text(_ key: String) -> String? {
            guard let value = plist[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return BundleFacts(bundleID: id, shortVersion: text("CFBundleShortVersionString"), build: text("CFBundleVersion"),
                           sparklePublicEDKey: plist["SUPublicEDKey"] == nil ? nil : (plist["SUPublicEDKey"] as? String ?? ""))
    }

    /// Bundle IDs become path components of the backup folder, so they must be plain.
    public static func isSafeBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 255 && id != "." && id != ".." && !id.hasPrefix(".")
            && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }
    }

    /// "1.2.3-456" with anything odd replaced, for the backup folder name.
    public var backupFolderName: String {
        func clean(_ s: String?) -> String {
            let raw = s ?? "unknown"
            let mapped = String(raw.unicodeScalars.map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "." || $0 == "_" ? Character($0) : "_" })
            let limited = String(mapped.prefix(64))
            return limited.allSatisfy({ $0 == "." }) ? "_" : limited
        }
        return clean(shortVersion) + "-" + clean(build)
    }
}
