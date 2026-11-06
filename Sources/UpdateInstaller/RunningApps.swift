import Foundation
import AppKit

/// Finds, quits and relaunches the instances of an app that run from one exact bundle path.
public protocol RunningAppControlling: Sendable {
    /// Process IDs of running apps with this bundle ID whose bundle is exactly `path`.
    func runningInstances(bundleID: String, path: String) -> [pid_t]
    /// Asks politely (never force-kills) and waits up to `timeout`. Returns true when none remain.
    func quit(bundleID: String, path: String, timeout: TimeInterval) async -> Bool
    func relaunch(path: String) async
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
