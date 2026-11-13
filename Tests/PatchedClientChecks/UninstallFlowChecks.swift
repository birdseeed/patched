import Foundation
import SwiftUI
import AppKit
import PatchedShell
import UpdateInstaller
@_spi(Testing) import PatchedClient

// The app's "Uninstall Patched…" flow, in a temporary library. The alert, the login item, launchd, the Bin and
// quitting are all test doubles; nothing real is touched.

private final class UninstallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func add(_ event: String) { lock.lock(); log.append(event); lock.unlock() }
}
@MainActor private final class FakeLoginItem: LoginItemControlling {
    let log: UninstallLog
    init(_ log: UninstallLog) { self.log = log }
    var status: LoginItemStatus { .enabled }
    func register() throws { log.add("register") }
    func unregister() throws { log.add("unregister") }
    func openSystemSettings() {}
}

@MainActor private struct UninstallRig {
    let root: String, library: String, app: String, backups: String
    let log = UninstallLog()
    var choice: UninstallFlow.Choice
    var flow: UninstallFlow!

    /// `refuseAtExecute`: another Patched appears between the alert and the removal, so the re-plan refuses.
    init(choice: UninstallFlow.Choice, unfinished: Bool = false, refuseAtExecute: Bool = false) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-flow-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = FileSafety.realPath(base) ?? base
        library = root + "/Library"; app = root + "/Applications/Patched.app"
        backups = library + "/Application Support/Patched/Updater/backups"
        self.choice = choice
        let fm = FileManager.default
        for path in [library + "/Logs/Patched", library + "/Caches/Patched/Updater", backups + "/com.vendor.tool/1.0-1", app + "/Contents",
                     library + "/Application Support/Patched/Updater/transactions"] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try Data("log".utf8).write(to: URL(fileURLWithPath: library + "/Logs/Patched/check.log"))
        try Data("backup".utf8).write(to: URL(fileURLWithPath: backups + "/com.vendor.tool/1.0-1/backup.json"))
        try Data("prefs".utf8).write(to: URL(fileURLWithPath: library + "/Application Support/Patched/Updater/catalogue.json"))
        if unfinished {
            var journal = TransactionJournal(id: "33333333-3333-3333-3333-333333333333", kind: .update, phase: .prepared,
                                             bundleID: "com.vendor.tool", teamID: "AAAAAAAAAA", targetPath: root + "/Applications/Tool.app",
                                             stagingDir: root + "/Applications/.mac-updater-Q", createdAt: "2026-01-01T00:00:00Z",
                                             updatedAt: "2026-01-01T00:00:00Z")
            try JournalStore(directory: library + "/Application Support/Patched/Updater/transactions").write(&journal)
        }
        let log = self.log, library = self.library, app = self.app
        let services = Uninstall.Services(
            bootOutAgent: { _ in true }, removeDefaults: { _ in },
            runningInstances: { log.add("running?"); return refuseAtExecute && log.events.filter { $0 == "running?" }.count > 1 ? [999] : [] },
            trash: { path in log.add(Thread.isMainThread ? "trash:main" : "trash"); try FileManager.default.removeItem(atPath: path) },
            deleteIfTrashFails: false)
        _ = (library, app)
        flow = nil
        flow = UninstallFlow(
            roots: { Uninstall.Roots(library: library, appBundle: app, applicationFolders: [], homebrewPrefixes: []) },
            services: services, loginItem: FakeLoginItem(log),
            ask: { [choice] prompt in log.add("ask:" + (prompt.hasBackups ? "backups" : "none")); return choice },
            tell: { title, detail in log.add("tell:" + title + "|" + detail) },
            quit: { log.add("quit") }, working: { log.add($0 ? "working" : "idle") })
    }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor func registerUninstallFlowChecks() {
    check("uninstall flow: an unfinished update shows the blocked alert, names recover, and changes nothing") {
        let rig = try UninstallRig(choice: .keepBackups, unfinished: true)
        try expect(await rig.flow.run() == .blocked, "not blocked")
        let tells = rig.log.events.filter { $0.hasPrefix("tell:") }
        try expect(tells.count == 1 && tells[0].hasPrefix("tell:Patched cannot be uninstalled yet")
                   && tells[0].contains("patched recover") && !rig.log.events.contains("unregister"), "events: \(rig.log.events)")
        try expect(rig.exists(rig.library + "/Logs/Patched/check.log") && rig.exists(rig.app) && rig.exists(rig.backups), "something was removed")
    }

    check("uninstall flow: the menu item opens the flow, and with a blocked plan only the blocked alert appears") {
        let rig = try UninstallRig(choice: .deleteBackups, unfinished: true)
        let session = NativeClientSession(navigation: ShellNavigation(destination: .support))
        let item = session.menuItems.first { $0.id == "uninstall" }
        try expect(item?.title == "Uninstall Patched…" && item?.action == .uninstall, "no menu item: \(session.menuItems.map(\.id))")
        let ids = session.menuItems.map(\.id)
        try expect(ids.firstIndex(of: "settings")! < ids.firstIndex(of: "uninstall")! && ids.firstIndex(of: "uninstall")! < ids.firstIndex(of: "quit")!, "item order \(ids)")
        let flow = rig.flow!
        var started: Task<UninstallFlow.Outcome, Never>?
        NativeClientMenuView(session: session, openWindow: {}, startUninstall: { started = Task { await flow.run() } }).perform(.uninstall)
        _ = await started?.value
        try expect(rig.log.events.filter { $0.hasPrefix("tell:") }.count == 1, "events: \(rig.log.events)")
        try expect(!rig.log.events.contains("unregister") && !rig.log.events.contains("quit") && rig.exists(rig.app), "acted on a blocked plan")
    }

    check("uninstall flow: Keep Backups unregisters the login item, removes data, trashes the app last, then quits") {
        let rig = try UninstallRig(choice: .keepBackups)
        try expect(await rig.flow.run() == .done, "events: \(rig.log.events)")
        let steps = rig.log.events.filter { !["working", "idle", "running?"].contains($0) }
        try expect(steps == ["ask:backups", "unregister", "trash", "quit"], "events: \(rig.log.events)")
        try expect(rig.log.events.contains("working") && rig.log.events.last != "working", "no progress shown, or left showing: \(rig.log.events)")
        try expect(!rig.exists(rig.library + "/Logs/Patched") && !rig.exists(rig.app) && !rig.exists(rig.library + "/Caches/Patched"), "data or app left")
        try expect(rig.exists(rig.backups + "/com.vendor.tool/1.0-1/backup.json") && !rig.exists(rig.library + "/Application Support/Patched/Updater/catalogue.json"),
                   "backups were not kept, or the catalogue was")
    }

    check("uninstall flow: Delete Backups removes them, and Cancel does nothing at all") {
        let all = try UninstallRig(choice: .deleteBackups)
        try expect(await all.flow.run() == .done && !all.exists(all.backups) && !all.exists(all.library + "/Application Support/Patched"), "backups kept")
        let cancel = try UninstallRig(choice: .cancel)
        try expect(await cancel.flow.run() == .cancelled && cancel.log.events.filter { !["working", "idle", "running?"].contains($0) } == ["ask:backups"], "events: \(cancel.log.events)")
        try expect(cancel.exists(cancel.app) && cancel.exists(cancel.backups) && cancel.exists(cancel.library + "/Logs/Patched/check.log"), "cancel removed something")
    }

    check("uninstall flow: files are measured and removed off the main thread, and a second start while one runs is refused") {
        let rig = try UninstallRig(choice: .keepBackups)
        async let first = rig.flow.run()
        let second = await rig.flow.run()
        let outcomes = [await first, second]
        try expect(outcomes.contains(.done) && outcomes.contains(.busy), "outcomes: \(outcomes)")
        try expect(rig.log.events.contains("trash") && !rig.log.events.contains("trash:main"), "ran on the main thread: \(rig.log.events)")
    }

    check("uninstall flow: if the removal refuses after the alert, the login item is switched back on and nothing is removed") {
        let rig = try UninstallRig(choice: .keepBackups, refuseAtExecute: true)
        try expect(await rig.flow.run() == .blocked, "events: \(rig.log.events)")
        let steps = rig.log.events.filter { $0 == "unregister" || $0 == "register" || $0 == "quit" || $0.hasPrefix("tell:") }
        try expect(steps.count == 3 && steps[0] == "unregister" && steps[1] == "register" && steps[2].hasPrefix("tell:Patched cannot be uninstalled yet"),
                   "events: \(rig.log.events)")
        try expect(rig.exists(rig.app) && rig.exists(rig.library + "/Logs/Patched/check.log"), "removed something")
    }
}
