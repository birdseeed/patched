import Foundation
import AppKit
import Darwin

/// Finds, quits and relaunches the instances of an app that run from one exact bundle path.
public protocol RunningAppControlling: Sendable {
    /// Process IDs of running apps with this bundle ID whose bundle is exactly `path`.
    func runningInstances(bundleID: String, path: String) -> [pid_t]
    /// Asks politely (never force-kills) and waits up to `timeout`. Returns true when none remain.
    func quit(bundleID: String, path: String, timeout: TimeInterval) async -> Bool
    func relaunch(path: String) async
    /// Processes that run an executable from inside the bundle at `path` (login items, XPC services, tools in
    /// Contents/MacOS). They need not be `NSRunningApplication` instances, so `quit` cannot ask them to go.
    /// The installer refuses while one runs and names it; it never kills a process.
    func bundleProcesses(path: String) -> [BundleProcess]
}

extension RunningAppControlling {
    /// Controllers that do not look for helper processes find none.
    public func bundleProcesses(path: String) -> [BundleProcess] { [] }
}

/// A process whose executable lives inside an app bundle.
public struct BundleProcess: Sendable, Equatable {
    public let pid: pid_t
    public let executablePath: String
    public init(pid: pid_t, executablePath: String) { self.pid = pid; self.executablePath = executablePath }

    /// "Helper (pid 123)" style text for a refusal: the executable's path inside the bundle, so the user can see
    /// which helper it is.
    public func description(inBundle bundle: String) -> String {
        let root = BundleProcessScan.normalised(bundle) + "/"
        let inside = executablePath.lowercased().hasPrefix(root.lowercased()) ? String(executablePath.dropFirst(root.count)) : executablePath
        return "\(inside) (pid \(pid))"
    }
}

/// Finds processes running from inside a bundle, with libproc (`proc_listallpids`, `proc_pidpath`).
public enum BundleProcessScan {
    static func normalised(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// True when `executable` is a path inside `bundle`. The bundle is compared with a trailing "/", so
    /// /Applications/Foo.app does not match /Applications/Foo.app2/x. Case is ignored (APFS usually is
    /// case-insensitive); the cost of a false match is only a refusal.
    public static func isInside(executable: String, bundle: String) -> Bool {
        let root = normalised(bundle).lowercased() + "/"
        return executable.lowercased().hasPrefix(root) && executable.count > root.count
    }

    /// The pure part: the processes among `pids` whose executable (from `pathOf`) is inside `bundle`.
    public static func filter(pids: [pid_t], bundle: String, pathOf: (pid_t) -> String?) -> [BundleProcess] {
        pids.compactMap { pid in
            guard let path = pathOf(pid), isInside(executable: path, bundle: bundle) else { return nil }
            return BundleProcess(pid: pid, executablePath: path)
        }
    }

    public static func allPIDs() -> [pid_t] {
        var capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        for _ in 0..<3 {
            capacity += 64
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listallpids(&buffer, Int32(capacity * MemoryLayout<pid_t>.size)))
            if count <= 0 { return [] }
            if count < capacity { return Array(buffer.prefix(count)).filter { $0 > 0 } }
            capacity *= 2
        }
        return []
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    /// Every process whose executable is inside the bundle at `path` (symlinks in `path` resolved first).
    public static func processes(inBundle path: String) -> [BundleProcess] {
        let bundle = FileSafety.realPath(path) ?? path
        return filter(pids: allPIDs(), bundle: bundle, pathOf: executablePath(of:))
    }
}

public struct WorkspaceRunningApps: RunningAppControlling {
    public init() {}

    private func matching(_ bundleID: String, _ path: String) -> [NSRunningApplication] {
        let wanted = FileSafety.realPath(path) ?? path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { app in
            guard let url = app.bundleURL else { return false }
            return (FileSafety.realPath(url.path) ?? url.standardizedFileURL.path) == wanted
        }
    }

    public func runningInstances(bundleID: String, path: String) -> [pid_t] {
        matching(bundleID, path).map(\.processIdentifier)
    }

    public func bundleProcesses(path: String) -> [BundleProcess] { BundleProcessScan.processes(inBundle: path) }

    public func quit(bundleID: String, path: String, timeout: TimeInterval) async -> Bool {
        await QuitPolling.waitUntilNoneRemain(timeout: timeout, interval: 0.25,
            enumerate: { matching(bundleID, path).map(\.processIdentifier) },
            requestQuit: { pid in
                // Polite only: never forceTerminate.
                _ = matching(bundleID, path).first(where: { $0.processIdentifier == pid })?.terminate()
            })
    }

    public func relaunch(path: String) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }
}

/// The quit loop, separate from AppKit so it can be tested. It re-enumerates instances on every poll, so a
/// replacement launched while the first one shuts down is noticed (and asked to quit too).
public enum QuitPolling {
    nonisolated(nonsending) public static func waitUntilNoneRemain(timeout: TimeInterval, interval: TimeInterval,
                                           enumerate: () -> [pid_t], requestQuit: (pid_t) -> Void) async -> Bool {
        var asked = Set<pid_t>()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let current = enumerate()
            if current.isEmpty { return true }
            for pid in current where !asked.contains(pid) { asked.insert(pid); requestQuit(pid) }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
