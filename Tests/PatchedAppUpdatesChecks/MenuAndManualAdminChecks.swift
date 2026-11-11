import Foundation
import UpdateSources
import UpdateInstaller
import PatchedShell
@_spi(Testing) import PatchedClient

// Rows that need admin rights (Open <app> instead of Update) and the menu's list of waiting updates.
// The opener is a recorder: nothing here opens a real app or URL.

final class FakeVerifier: CodeVerifying, @unchecked Sendable {
    private let lock = NSLock(); private var _calls: [String] = []
    let refuse: Bool
    init(refuse: Bool = false) { self.refuse = refuse }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    func verifySignature(ofBundleAt path: String, teamID: String) throws {
        lock.lock(); _calls.append(path + "|" + teamID); lock.unlock()
        if refuse { throw InstallRefusal.signatureInvalid("fake refusal") }
    }
    func assessGatekeeper(ofBundleAt path: String) throws {}
}

@MainActor final class FakeLauncher { var launched: [String] = []; var succeed = true
    func launch(_ url: URL) async -> Bool { launched.append(url.path); return succeed } }

@MainActor func registerMenuAndManualAdminChecks() {
    check("admin required: Open <app> opens exactly that path on a click; checks and Update All open nothing") {
        let admin = app("Admin"), plain = app("Plain")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let rig = Rig([outcome(admin, .updateAvailable(offer("2.0"))), outcome(plain, .updateAvailable(offer("2.0")))], installer: installer)
        let controller = rig.controller, opener = rig.opener
        @MainActor func row(_ name: String) -> AppUpdateRow { controller.rows.first { $0.name == name }! }
        // Background checks: nothing opens, nothing is marked yet.
        rig.scheduler.start(); await rig.settle()
        try expect(opener.nothingOpened && !row("Admin").needsManualAdmin, "scheduled check opened \(opener.appPaths)")
        // A click on the (still ordinary) Update learns that this app needs admin rights.
        await runOperation(controller) { controller.update(id: admin.path) }
        try expect(row("Admin").needsManualAdmin && row("Admin").openAppActionTitle == "Open Admin", "row not marked: \(row("Admin"))")
        try expect(!controller.canUpdate(row("Admin")) && controller.canOpenApp(row("Admin")), "Update still offered or Open not offered")
        try expect(row("Admin").result?.text == "Admin: Needs admin rights. Open the app and use its own updater.", "text: \(String(describing: row("Admin").result))")
        try expect(opener.nothingOpened, "refusal opened something: \(opener.appPaths)")
        // Update All installs the other app, leaves this one, reports it as needing admin, opens nothing.
        var summary: UpdateAllSummary?
        await runOperation(controller) { controller.updateAll(onFinished: { summary = $0 }) }
        try expect(summary?.needsAdmin == 1 && summary?.updated == 1, "summary: \(String(describing: summary))")
        try expect(opener.nothingOpened, "Update All opened \(opener.appPaths) \(opener.urls)")
        // A later scheduled check keeps the mark and opens nothing.
        rig.clock.advance(UpdateCheckScheduler.interval)
        try rig.timer.fireActive(); await rig.settle()
        try expect(row("Admin").needsManualAdmin && opener.nothingOpened, "scheduled check changed the row or opened \(opener.appPaths)")
        // Only the click opens the app, once, by its installed path.
        controller.openApp(id: admin.path); await controller.waitUntilIdle()
        try expect(opener.appPaths == [admin.path] && opener.urls.isEmpty && opener.apps.isEmpty, "opened: \(opener.appPaths) \(opener.urls) \(opener.apps)")
        try expect(opener.appExpectations == ["com.example.admin/TEAM123456"], "bundle and team IDs not retained for revalidation: \(opener.appExpectations)")
        try expect(row("Admin").result?.kind != .failure, "success showed an error")
        // An ordinary row offers no Open.
        controller.openApp(id: plain.path); await controller.waitUntilIdle()
        try expect(opener.appPaths == [admin.path], "ordinary row opened: \(opener.appPaths)")
        // The installer never saw anything beyond the one refused attempt and the other app's update.
        try expect(installer.recorder.events.filter { $0.hasPrefix("admin") }.isEmpty, "consent passed: \(installer.recorder.events)")
    }

    check("admin required: an Open that fails shows an error message on the row") {
        let admin = app("Admin")
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("root-owned") }
        let controller = makeController(outcomes: [outcome(admin, .updateAvailable(offer("2.0")))], installer: installer)
        let opener = RecordingOpener(); opener.appPathResult = .failed
        controller.urlOpener = opener
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: admin.path) }
        controller.openApp(id: admin.path); await controller.waitUntilIdle()
        let result = controller.rows[0].result
        try expect(opener.appPaths == [admin.path], "attempts: \(opener.appPaths)")
        try expect(result?.kind == .failure && result?.text == "Couldn't open Admin. Open it from your Applications folder.", "result: \(String(describing: result))")
        // The view offers the button for these rows, with the caption, and not as an Update.
        let view = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/AppUpdatesView.swift", encoding: .utf8)
        try expect(view.contains("controller.openApp(id: row.id)") && view.contains("AppUpdateRow.needsAdminCaption") && view.contains("row.openAppActionTitle"),
                   "view lacks Open <app> or the caption")
    }

    check("admin required: an app that changed since the check is not opened; the row shows an error and needs a fresh check") {
        let admin = app("Admin")
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("root-owned") }
        let controller = makeController(outcomes: [outcome(admin, .updateAvailable(offer("2.0")))], installer: installer)
        let opener = RecordingOpener(); opener.appPathResult = .changed
        controller.urlOpener = opener
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: admin.path) }
        controller.openApp(id: admin.path); await controller.waitUntilIdle()
        let row = controller.rows[0]
        try expect(row.result?.kind == .failure && row.result?.text == "Admin has changed since the last check, so it was not opened. Check again.",
                   "result: \(String(describing: row.result))")
        try expect(row.status == .needsRecheck && !controller.canOpenApp(row) && !controller.canUpdate(row), "row still actionable: \(row.status)")
        controller.openApp(id: admin.path); await controller.waitUntilIdle()
        try expect(opener.appPaths == [admin.path], "second click reopened without a fresh check: \(opener.appPaths)")
        // The real opener runs the real revalidation right before launching.
        let links = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/ExternalLinks.swift", encoding: .utf8)
        let launch = links.range(of: "InstalledAppRevalidation.isStillTheSameApp(path: path")!.lowerBound
        let workspace = links.range(of: "NSWorkspace.shared.openApplication(at: url, configuration")!.lowerBound
        try expect(launch < workspace, "WorkspaceURLOpener does not revalidate before launching")
    }

    check("real revalidation: same bundle passes; a replaced bundle ID, a symlink, a non-.app, a missing plist or a different Team ID is refused") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("patched-revalidate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, id: String?) throws -> String {
            let contents = root.appendingPathComponent(name + "/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            if let id {
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
            }
            return root.appendingPathComponent(name).path
        }
        let good = try bundle("Good.app", id: "com.example.good")
        try expect(InstalledAppRevalidation.isStillTheSameApp(path: good, bundleID: "com.example.good", teamID: nil), "same bundle refused")
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: good, bundleID: "com.example.other", teamID: nil), "replaced bundle ID accepted")
        // Replacement in place: another app's bundle now sits at the checked path.
        let replaced = try bundle("Replaced.app", id: "com.example.good")
        try expect(InstalledAppRevalidation.isStillTheSameApp(path: replaced, bundleID: "com.example.good", teamID: nil), "setup")
        try Data().write(to: URL(fileURLWithPath: replaced + "/Contents/x"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.evil.app"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: replaced + "/Contents/Info.plist"))
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: replaced, bundleID: "com.example.good", teamID: nil), "replaced app accepted")
        // A symlink at the path, even to a good bundle.
        let link = root.appendingPathComponent("Link.app").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: good)
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: link, bundleID: "com.example.good", teamID: nil), "symlink accepted")
        // Not a .app directory, a regular file, a missing path and a bundle with no plist.
        let notApp = try bundle("Good.bundle", id: "com.example.good")
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: notApp, bundleID: "com.example.good", teamID: nil), ".bundle accepted")
        let file = root.appendingPathComponent("File.app").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: file, bundleID: "com.example.good", teamID: nil), "regular file accepted")
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: root.appendingPathComponent("Gone.app").path, bundleID: "x", teamID: nil), "missing path accepted")
        let bare = try bundle("Bare.app", id: nil)
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: bare, bundleID: "com.example.good", teamID: nil), "bundle without Info.plist accepted")
        // Team ID: the signature is read from the real bundle (unsigned here), so any expected Team ID mismatches.
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: good, bundleID: "com.example.good", teamID: "TEAM123456"), "unsigned replacement passed a Team ID check")
        try expect(InstalledAppRevalidation.isStillTheSameApp(path: good, bundleID: "com.example.good", teamID: "TEAM123456", verifier: FakeVerifier()), "validated signature refused")
        let seen = FakeVerifier(); _ = InstalledAppRevalidation.isStillTheSameApp(path: good, bundleID: "com.example.good", teamID: "TEAM123456", verifier: seen)
        try expect(seen.calls == [good + "|TEAM123456"], "verifier not asked for the retained Team ID: \(seen.calls)")
        let unsigned = FakeVerifier(); _ = InstalledAppRevalidation.isStillTheSameApp(path: good, bundleID: "com.example.good", teamID: nil, verifier: unsigned)
        try expect(unsigned.calls.isEmpty, "verifier used for an app with no Team ID")
        try expect(!InstalledAppRevalidation.isStillTheSameApp(path: good, bundleID: "com.example.good", teamID: "TEAM123456", verifier: FakeVerifier(refuse: true)), "invalid signature accepted")
    }

    check("real opener: a refused signature blocks the launch and shows the row error; a valid one launches exactly that path") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("patched-open-" + UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("Admin.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.admin"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let path = root.appendingPathComponent("Admin.app").path
        let admin = InstalledApp(name: "Admin", path: path, bundleID: "com.example.admin", shortVersion: "1.0", build: "1.0")
        for refuse in [true, false] {
            let installer = FakeInstaller()
            installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("root-owned") }
            let controller = makeController(outcomes: [outcome(admin, .updateAvailable(offer("2.0")))], installer: installer)
            let verifier = FakeVerifier(refuse: refuse), launcher = FakeLauncher()
            controller.urlOpener = WorkspaceURLOpener(verifier: verifier, launcher: { await launcher.launch($0) })
            await runCheck(controller)
            await runOperation(controller) { controller.update(id: path) }
            controller.openApp(id: path); await controller.waitUntilIdle()
            try expect(verifier.calls == [path + "|TEAM123456"], "refuse=\(refuse) verifier calls: \(verifier.calls)")
            if refuse {
                try expect(launcher.launched.isEmpty, "launched despite a refused signature: \(launcher.launched)")
                try expect(controller.rows[0].result?.kind == .failure && controller.rows[0].status == .needsRecheck,
                           "no row error: \(String(describing: controller.rows[0].result))")
            } else {
                try expect(launcher.launched == [path], "launched: \(launcher.launched)")
                try expect(controller.rows[0].result?.kind != .failure, "error shown for a valid open")
            }
        }
    }

    check("admin required: with the experimental admin path on, the row stays Update (admin) and never offers Open") {
        let admin = app("Admin")
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("root-owned") }
        let controller = makeController(outcomes: [outcome(admin, .updateAvailable(offer("2.0")))], installer: installer, adminUpdates: true)
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: admin.path) }
        try expect(controller.rows[0].privilege == .admin && !controller.rows[0].needsManualAdmin && !controller.canOpenApp(controller.rows[0]), "row: \(controller.rows[0])")
    }

    check("menu list: header, ordering, cap and counts") {
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        var outcomes = [outcome(app("Admin"), .updateAvailable(offer("2.0"))), storeOutcome(storeApp("Aardvark Store")),
                        outcome(app("Done"), .upToDate)]
        for name in ["Bravo", "Alpha", "Delta", "Charlie", "Echo", "Foxtrot", "Golf", "Hotel", "India"] {
            outcomes.append(outcome(app(name), .updateAvailable(offer("2.0"))))
        }
        let controller = makeController(outcomes: outcomes, installer: installer)
        let empty = controller.menuUpdates()
        try expect(empty.header == "No update check yet" && empty.rows.isEmpty && empty.moreCount == 0, "before check: \(empty)")
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: "/Fake/Admin.app") }   // learns that it needs admin rights
        let menu = controller.menuUpdates()
        try expect(menu.header == "11 updates available", "header: \(menu.header)")
        // Ordinary updates by name, then the one that needs admin, then App Store; the cap cuts from the end.
        try expect(menu.rows.map(\.name) == ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"], "rows: \(menu.rows.map(\.name))")
        try expect(menu.moreCount == 3 && menu.rows.count == NativeClientMenuUpdates.rowCap, "cap: \(menu.rows.count) more \(menu.moreCount)")
        try expect(menu.rows[0].versions == "1.0 → 2.0" && menu.rows[0].note == nil, "row: \(menu.rows[0])")
        let wide = controller.menuUpdates(cap: 50)
        try expect(wide.rows.suffix(3).map(\.name) == ["India", "Admin", "Aardvark Store"] && wide.moreCount == 0, "tail: \(wide.rows.suffix(3).map(\.name))")
        try expect(wide.rows[9].note == "Needs admin" && wide.rows[10].note == "App Store" && wide.rows[10].versions == "1.0 → 3.0", "notes: \(wide.rows.suffix(2))")
        let one = controller.menuUpdates(cap: 1)
        try expect(one.rows.count == 1 && one.moreCount == 10, "cap 1: \(one.rows.count) \(one.moreCount)")
    }

    check("menu list: up to date shows the check time, and a check in progress shows Checking") {
        let controller = makeController(outcomes: [outcome(app("Done"), .upToDate)])
        await runCheck(controller)
        let quiet = controller.menuUpdates(timeFormatter: { _ in "10:42" })
        try expect(quiet.header == "Up to date" && quiet.checkedAt == "10:42" && quiet.rows.isEmpty, "header: \(quiet.header)")
        let gate = Gate()
        let slow = AppUpdatesController(scan: { [AppUpdateScannedApp(app: app("Done"), icon: nil)] },
                                        check: { apps in await gate.wait(); return [outcome(app("Done"), .upToDate)] },
                                        recheck: { _ in nil }, installer: FakeInstaller())
        slow.check()
        try expect(slow.menuUpdates().header == "Checking…", "header: \(slow.menuUpdates().header)")
        gate.open(); await slow.waitUntilIdle()
    }

    check("menu list: failed checks never read as Up to date; package updates are listed with a note") {
        let clock: (Date) -> String = { _ in "10:42" }
        let down = RefusalReason.network("offline")
        // Every check failed: not "Up to date".
        let allFailed = makeController(outcomes: [outcome(app("Alpha"), .refused(down)), outcome(app("Bravo"), .refused(down))])
        await runCheck(allFailed)
        let failed = allFailed.menuUpdates(timeFormatter: clock)
        try expect(failed.header == "Couldn't check 2 apps" && failed.checkedAt == "10:42" && failed.rows.isEmpty, "all failed: \(failed.header)")
        // Some failed, the rest up to date or without a source.
        let some = makeController(outcomes: [outcome(app("Alpha"), .refused(down)), outcome(app("Bravo"), .upToDate), outcome(app("Echo"), .noSource, noSource: true)])
        await runCheck(some)
        try expect(some.menuUpdates(timeFormatter: clock).header == "Couldn't check 1 app", "partial: \(some.menuUpdates(timeFormatter: clock).header)")
        // Up to date and no-source only: the one case that says Up to date.
        let fine = makeController(outcomes: [outcome(app("Bravo"), .upToDate), outcome(app("Echo"), .noSource, noSource: true)])
        await runCheck(fine)
        try expect(fine.menuUpdates(timeFormatter: clock).header == "Up to date" && fine.menuUpdates(timeFormatter: clock).checkedAt == "10:42", "fine: \(fine.menuUpdates(timeFormatter: clock).header)")
        // Updates plus a failure: the updates lead, the failure is a second line. Package and unconfirmed updates are listed.
        let mixed = makeController(outcomes: [outcome(app("Alpha"), .refused(down)), outcome(app("Bravo"), .updateAvailable(offer("2.0"))),
            outcome(app("Delta"), .updateAvailable(offer("4.0", format: .pkg))),
            outcome(app("Charlie"), .updateAvailable(offer("3.0", source: .homebrewCask(token: "charlie"))), source: .homebrewCask(token: "charlie"), low: true)])
        await runCheck(mixed)
        let menu = mixed.menuUpdates(timeFormatter: clock)
        try expect(menu.header == "3 updates available" && menu.note == "Couldn't check 1 app" && menu.checkedAt == "10:42", "mixed: \(menu.header) / \(String(describing: menu.note))")
        try expect(menu.rows.map(\.name) == ["Bravo", "Charlie", "Delta"] && menu.rows[0].note == nil
                   && menu.rows[1].note == "Unconfirmed" && menu.rows[2].note == "Installer package", "rows: \(menu.rows)")
        // The catalogue is unreadable and nothing has been checked.
        let broken = makeController(outcomes: [outcome(app("Alpha"), .upToDate)], catalogue: { "unreadable" })
        await broken.refreshInstallerState()
        try expect(broken.menuUpdates().header == "Couldn't check for updates", "catalogue: \(broken.menuUpdates().header)")
    }

    check("menu list: row versions drop build numbers and carry the installed path") {
        let withBuild = InstalledApp(name: "Browser", path: "/Fake/Browser.app", bundleID: "com.example.browser",
                                     shortVersion: "156.0.8078.81", build: "8078.81")
        let controller = makeController(outcomes: [outcome(withBuild, .updateAvailable(offer("157.0.1", build: "9000")))])
        await runCheck(controller)
        let row = try controller.menuUpdates().rows.first.unwrap()
        try expect(row.versions == "156.0.8078.81 → 157.0.1" && !row.versions.contains("("), "versions: \(row.versions)")
        try expect(row.path == "/Fake/Browser.app", "path: \(row.path)")
        // Published versions are shown exactly, parentheses included; no build means the version as is.
        let beta = InstalledApp(name: "Beta", path: "/Fake/Beta.app", bundleID: "com.example.beta", shortVersion: "1.0 (beta)", build: "41")
        let plain = InstalledApp(name: "Plain", path: "/Fake/Plain.app", bundleID: "com.example.plain", shortVersion: "3.1", build: nil)
        let more = makeController(outcomes: [outcome(beta, .updateAvailable(offer("1.0 (stable)"))), outcome(plain, .updateAvailable(offer("3.2")))])
        await runCheck(more)
        let versions = Dictionary(uniqueKeysWithValues: more.menuUpdates().rows.map { ($0.name, $0.versions) })
        try expect(versions["Beta"] == "1.0 (beta) → 1.0 (stable)" && versions["Plain"] == "3.1 → 3.2", "versions: \(versions)")
    }

    check("menu list: a row click focuses that app in Updates and installs and opens nothing") {
        let installer = FakeInstaller(), opener = RecordingOpener()
        let a = app("Alpha"), b = app("Bravo")
        let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0"))), outcome(b, .updateAvailable(offer("2.0")))], installer: installer)
        let navigation = ShellNavigation(destination: .support)
        let session = NativeClientSession(navigation: navigation, appUpdates: controller, urlOpener: opener)
        await runCheck(controller)
        let events = installer.recorder.events
        let list = controller.menuUpdates()
        try expect(session.showUpdate(id: list.rows[1].id), "click not routed to the window")
        try expect(navigation.destination == .updates && controller.focusedRowID == "/Fake/Bravo.app", "focus: \(navigation.destination) \(String(describing: controller.focusedRowID))")
        // Picking the same app again is a fresh request, so the window scrolls back to it.
        let firstRequest = controller.focusRequest
        try expect(session.showUpdate(id: list.rows[1].id) && controller.focusRequest == firstRequest &+ 1, "repeat selection made no new focus request")
        try expect(installer.recorder.events == events && opener.nothingOpened && controller.updateAllInvocations == 0 && !controller.isWorking,
                   "click started work: \(installer.recorder.events) \(opener.appPaths)")
        // Check Now only checks; it does not ask for the window.
        let before = installer.recorder.events.filter { $0 == "check" }.count
        let asked = session.performMenuAction(.checkNow)
        await controller.waitUntilIdle()
        try expect(!asked && installer.recorder.events.filter { $0 == "check" }.count == before + 1, "Check Now: \(asked)")
        try expect(!installer.recorder.events.contains { $0.hasPrefix("update") }, "Check Now installed: \(installer.recorder.events)")
    }

    check("menu: native items: status lines, one item per update, Update All, then Open, Check Now, Settings and Quit") {
        let outcomes = (0..<10).map { outcome(app("App\($0)"), .updateAvailable(offer("2.0"))) }
        let controller = makeController(outcomes: outcomes)
        await runCheck(controller)
        let session = NativeClientSession(navigation: ShellNavigation(destination: .support), appUpdates: controller, urlOpener: RecordingOpener())
        let items = session.menuItems
        try expect(items.first?.kind == .text && items.first?.title == "10 updates available", "header: \(String(describing: items.first))")
        try expect(items.contains { $0.kind == .text && $0.title.hasPrefix("Checked ") }, "no checked time")
        let rows = items.filter { if case .showUpdate? = $0.action { return true }; return false }
        try expect(rows.count == NativeClientMenuUpdates.rowCap && rows[0].title == "App0  1.0 → 2.0" && rows[0].iconPath == "/Fake/App0.app"
                   && rows[0].action == .showUpdate(id: "/Fake/App0.app"), "rows: \(rows.map(\.title))")
        try expect(items.first { $0.title == "and 2 more…" }?.action == .openUpdates, "no 'and 2 more…'")
        let all = try items.first { $0.action == .updateAll }.unwrap()
        try expect(all.title == "Update All (10)" && all.enabled, "Update All: \(all)")
        let commands = items.compactMap { item -> String? in
            guard let action = item.action, [.openUpdates, .checkNow, .settings, .quit].contains(action), item.title != "and 2 more…" else { return nil }
            return item.title + (item.shortcut.map { " ⌘" + String($0) } ?? "")
        }
        try expect(commands == ["Open Patched", "Check Now ⌘r", "Settings… ⌘,", "Quit Patched ⌘q"], "commands: \(commands)")
        try expect(items.last?.kind == .text && items.last?.title == session.menuText.backgroundStatus, "background status last")
        try expect(items.filter { $0.kind == .separator }.count == 3, "separators: \(items.map(\.title))")
        // A native NSMenu, not a hand-drawn window.
        let app = try String(contentsOfFile: sourcesRoot() + "/PatchedApp/PatchedApp.swift", encoding: .utf8)
        try expect(app.contains(".menuBarExtraStyle(.menu)") && !app.contains(".menuBarExtraStyle(.window)"), "menu bar extra is not a menu")
        let menu = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/NativeClientMenu.swift", encoding: .utf8)
        for custom in ["MenuHoverButton", "MenuItemLabel", ".onHover", "EdgeInsets(", ".frame(width: 320"] {
            try expect(!menu.contains(custom), "menu still hand-draws \(custom)")
        }
    }

    check("menu: each command does only its own thing; Settings… opens the Settings window, not the main window") {
        let installer = FakeInstaller()
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0")))], installer: installer)
        let navigation = ShellNavigation(destination: .applications)
        let session = NativeClientSession(navigation: navigation, appUpdates: controller, urlOpener: RecordingOpener())
        await runCheck(controller)
        var windows = 0, settings = 0, asked = 0
        let menu = NativeClientMenuView(session: session, openWindow: { windows += 1 }, openSettings: { settings += 1 },
                                        confirmSelfUpdate: { _ in asked += 1; return true })
        let events = installer.recorder.events
        menu.perform(.settings)
        try expect(settings == 1 && windows == 0 && navigation.destination == .applications, "Settings…: \(settings) \(windows)")
        menu.perform(.showUpdate(id: "/Fake/Alpha.app"))
        try expect(windows == 1 && navigation.destination == .updates && controller.focusedRowID == "/Fake/Alpha.app", "row click")
        navigation.select(.applications)
        menu.perform(.openUpdates)
        try expect(windows == 2 && navigation.destination == .updates, "Open Patched")
        menu.perform(.checkNow); await controller.waitUntilIdle()
        try expect(windows == 2 && installer.recorder.events.filter { $0 == "check" }.count == events.filter { $0 == "check" }.count + 1, "Check Now")
        try expect(!installer.recorder.events.contains { $0.hasPrefix("update") } && asked == 0 && controller.updateAllInvocations == 0,
                   "a menu item installed: \(installer.recorder.events)")
    }

    check("menu: the checked time is dated unless it is today, in the user's locale") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let gb = Locale(identifier: "en_GB"), fr = Locale(identifier: "fr_FR")
        let now = at(9, 15, 0)
        func label(_ date: Date, _ locale: Locale = gb) -> String {
            AppUpdatesController.shortTime(date, now: now, calendar: calendar, locale: locale)
        }
        try expect(label(at(9, 10, 42)) == "10:42", "today: \(label(at(9, 10, 42)))")
        try expect(label(at(9, 0, 5)) == "00:05", "today, early: \(label(at(9, 0, 5)))")
        try expect(label(at(8, 23, 59)) == "Yesterday 23:59", "yesterday: \(label(at(8, 23, 59)))")
        try expect(label(at(8, 10, 42)) == "Yesterday 10:42", "yesterday: \(label(at(8, 10, 42)))")
        let older = label(at(5, 10, 42))
        try expect(older.contains("05/11") && older.contains("10:42") && !older.contains("Yesterday"), "older: \(older)")
        // The wording comes from the locale rather than the code.
        let french = label(at(8, 10, 42), fr)
        try expect(french.lowercased().hasPrefix("hier") && french.contains("10:42"), "French yesterday: \(french)")
        // Midnight is the boundary, not 24 hours.
        let early = AppUpdatesController.shortTime(at(8, 23, 0), now: at(9, 0, 30), calendar: calendar, locale: gb)
        try expect(early == "Yesterday 23:00", "across midnight: \(early)")
    }
}
