import Foundation
import UserNotifications
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

// Update All from the Patched menu and from the notification's Update All button. Both are explicit
// clicks that end in the same controller.updateAll(); the scheduler never reaches it.

@MainActor final class FakeSummaryNotifier: UpdateSummaryNotifying {
    var posted: [UpdateAllSummary] = []
    func notify(summary: UpdateAllSummary) { posted.append(summary) }
}
@MainActor final class Tally { var n = 0 }
@MainActor final class KeysBox { var all: [Set<String>] = [] }

@MainActor func updateEvents(_ installer: FakeInstaller) -> [String] { installer.recorder.events.filter { $0.hasPrefix("update ") } }
/// The keys a notification advertising these rows (at `version`) would carry.
func advertised(_ apps: [InstalledApp], version: String = "2.0") -> Set<String> {
    Set(apps.map { AvailableUpdate(path: $0.path, name: $0.name, version: version, build: version).key })
}
@MainActor final class Opens { var n = 0 }
@MainActor func yieldAFewTimes() async { for _ in 0..<20 { await Task.yield() } }

/// Waits for a run and for the follow-up pass the entry point may start after it.
@MainActor func settleFollowUp(_ controller: AppUpdatesController) async {
    for _ in 0..<3 { await controller.waitUntilIdle(); await yieldAFewTimes() }
    await controller.waitUntilIdle()
}
/// Two updatable apps, "Open" being open until it is quit.
@MainActor func openAppRig() -> (rig: Rig, open: InstalledApp, closed: InstalledApp) {
    let open = app("Claude"), closed = app("Zed")
    let installer = FakeInstaller()
    installer.updateHandler = { outcome, quit in
        if outcome.app.name == "Claude", !quit { throw InstallRefusal.appRunning("open") }
        return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
    }
    let rig = Rig([outcome(open, .updateAvailable(offer("2.0"))), outcome(closed, .updateAvailable(offer("2.0")))], installer: installer)
    return (rig, open, closed)
}
@MainActor final class Asked { var questions: [String] = []; var answer = true }

@MainActor func registerUpdateAllEntryChecks() {
    check("update-all open apps: yes quits, updates and reopens the open app after the others; one merged summary") {
        let (rig, _, _) = openAppRig()
        let notifier = FakeSummaryNotifier(), asked = Asked()
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: notifier)
        entry.confirmOpenApps = { asked.questions.append($0); return asked.answer }
        rig.controller.check(); await rig.settle()
        entry.requestUpdateAll(); await settleFollowUp(rig.controller)
        try expect(asked.questions == ["Claude is open. Quit it, update and reopen it?"], "asked: \(asked.questions)")
        try expect(updateEvents(rig.installer) == ["update Claude quit=false", "update Zed quit=false", "update Claude quit=true"],
                   "events: \(updateEvents(rig.installer))")
        try expect(notifier.posted.count == 1 && notifier.posted[0].updated == 2 && notifier.posted[0].skippedOpen == 0
                   && notifier.posted[0].failed == 0 && notifier.posted[0].openPaths.isEmpty, "summary: \(notifier.posted)")
    }

    check("update-all open apps: no leaves the open app alone and reports it skipped") {
        let (rig, _, _) = openAppRig()
        let notifier = FakeSummaryNotifier(), asked = Asked()
        asked.answer = false
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: notifier)
        entry.confirmOpenApps = { asked.questions.append($0); return asked.answer }
        rig.controller.check(); await rig.settle()
        entry.requestUpdateAll(); await settleFollowUp(rig.controller)
        try expect(asked.questions.count == 1, "asked \(asked.questions.count) times")
        try expect(updateEvents(rig.installer) == ["update Claude quit=false", "update Zed quit=false"], "events: \(updateEvents(rig.installer))")
        try expect(notifier.posted.count == 1 && notifier.posted[0].updated == 1 && notifier.posted[0].skippedOpen == 1, "summary: \(notifier.posted)")
    }

    check("update-all open apps: with no confirm hook nothing is asked or quit") {
        let (rig, _, _) = openAppRig()
        let notifier = FakeSummaryNotifier()
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: notifier)
        rig.controller.check(); await rig.settle()
        entry.requestUpdateAll(); await settleFollowUp(rig.controller)
        try expect(!rig.installer.recorder.events.contains { $0.hasSuffix("quit=true") }, "quit: \(rig.installer.recorder.events)")
        try expect(notifier.posted.count == 1 && notifier.posted[0].skippedOpen == 1 && notifier.posted[0].updated == 1, "summary: \(notifier.posted)")
        try expect(rig.controller.pendingQuit == nil, "entry-point run raised a window alert")
    }

    check("update-all open apps: nothing open means nothing asked") {
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        let asked = Asked()
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: FakeSummaryNotifier())
        entry.confirmOpenApps = { asked.questions.append($0); return true }
        rig.controller.check(); await rig.settle()
        entry.requestUpdateAll(); await settleFollowUp(rig.controller)
        try expect(asked.questions.isEmpty, "asked: \(asked.questions)")
    }

    check("update-all open apps: Stop during the run means no question") {
        let open = app("Claude"), a = app("Alpha"), b = app("Bravo")
        let installer = FakeInstaller()
        let gate = Gate()
        installer.updateHandler = { outcome, quit in
            if outcome.app.name == "Claude", !quit { throw InstallRefusal.appRunning("open") }
            if outcome.app.name == "Bravo" { await gate.wait() }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [open, a, b].map { outcome($0, .updateAvailable(offer("2.0"))) }, installer: installer)
        let asked = Asked()
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: FakeSummaryNotifier())
        entry.confirmOpenApps = { asked.questions.append($0); return true }
        await runCheck(controller)
        entry.requestUpdateAll()
        for _ in 0..<200 where !updateEvents(installer).contains("update Bravo quit=false") { try await Task.sleep(nanoseconds: 5_000_000) }
        entry.requestStop()
        gate.open(); await settleFollowUp(controller)
        try expect(asked.questions.isEmpty, "asked after Stop: \(asked.questions)")
        try expect(!installer.recorder.events.contains { $0.hasSuffix("quit=true") }, "quit after Stop: \(installer.recorder.events)")
    }

    check("update-all open apps: the Updates window raises one alert after the run, and confirming updates with quit") {
        let (rig, open, _) = openAppRig()
        rig.controller.check(); await rig.settle()
        await runOperation(rig.controller) { rig.controller.updateAll() }
        let pending = rig.controller.pendingQuit
        try expect(pending?.action == .updateOpen && pending?.paths == [open.path], "pending: \(String(describing: pending))")
        try expect(pending?.message == "Claude is open. Quit it, update and reopen it?", "message: \(pending?.message ?? "nil")")
        try expect(!updateEvents(rig.installer).contains("update Claude quit=true"), "quit before confirming")
        await runOperation(rig.controller) { rig.controller.confirmQuit() }
        try expect(updateEvents(rig.installer).last == "update Claude quit=true", "events: \(updateEvents(rig.installer))")
        try expect(rig.controller.pendingQuit == nil, "alert left behind")
    }

    check("update-all open apps: the question names one, two or three apps") {
        try expect(AppUpdatesController.openAppsQuestion(names: ["Claude"]) == "Claude is open. Quit it, update and reopen it?", "one")
        try expect(AppUpdatesController.openAppsQuestion(names: ["Claude", "Slack"]) == "Claude and Slack are open. Quit them, update and reopen them?", "two")
        try expect(AppUpdatesController.openAppsQuestion(names: ["Claude", "Slack", "Zoom"])
                   == "Claude, Slack and Zoom are open. Quit them, update and reopen them?", "three")
    }

    check("update-all menu: hidden with nothing waiting, otherwise 'Update All (N)' and enabled") {
        let rig = Rig([outcome(app("Alpha"), .upToDate)])
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        try expect(!entry.menu.visible, "visible before any check")
        rig.controller.check(); await rig.settle()
        try expect(!entry.menu.visible, "visible with nothing to update: \(entry.menu)")
        let two = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("Bravo"), .updateAvailable(offer("2.0")))])
        let e2 = UpdateAllEntryPoint(controller: two.controller, summaryNotifier: nil)
        two.controller.check(); await two.settle()
        let m = e2.menu
        try expect(m.visible && m.title == "Update All (2)" && m.enabled && m.reason == nil && !m.showsStop && m.progressText == nil, "menu: \(m)")
    }

    check("update-all menu: disabled with a reason while checking, while blocked, and when only admin rows remain") {
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        rig.controller.check(); await rig.settle()
        let gate = rig.hold()
        rig.controller.check()
        try expect(rig.controller.phase == .checking, "not checking")
        try expect(entry.menu.visible && entry.menu.title == "Update All (1)" && !entry.menu.enabled && entry.menu.reason == "Checking for updates…",
                   "while checking: \(entry.menu)")
        gate.open(); await rig.settle()
        try expect(entry.menu.enabled, "not re-enabled after the check: \(entry.menu)")
        // Blocked by a catalogue problem.
        let broken = Counter()
        let blocked = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0")))],
                                      catalogue: { broken.value > 0 ? "/x/catalogue.json: not a JSON object" : nil })
        await runCheck(blocked)
        _ = broken.next(); await blocked.refreshInstallerState()
        let be = UpdateAllEntryPoint(controller: blocked, summaryNotifier: nil)
        try expect(be.menu.visible && !be.menu.enabled && be.menu.reason == "Updates are paused. See the Updates window.", "blocked: \(be.menu)")
        // Only an admin row waiting: counted, but Update All has nothing it may install.
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("root-owned") }
        let admin = makeController(outcomes: [outcome(app("Admin"), .updateAvailable(offer("2.0")))], installer: installer, adminUpdates: true)
        await runCheck(admin)
        await runOperation(admin) { admin.updateAll() }
        let ae = UpdateAllEntryPoint(controller: admin, summaryNotifier: nil)
        try expect(admin.availableUpdateCount == 1, "badge changed: \(admin.availableUpdateCount)")
        try expect(!ae.menu.visible, "Update All offered with only an admin row, which it would not install: \(ae.menu)")
    }

    check("update-all menu: the count is only what Update All will install (no admin, pkg or low-confidence rows); the badge is unchanged") {
        let ok = app("Ok"), admin = app("Admin"), pkg = app("Pkgy"), low = app("Low")
        let cask = UpdateSource.homebrewCask(token: "low")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [
            outcome(ok, .updateAvailable(offer("2.0"))), outcome(admin, .updateAvailable(offer("2.0"))),
            outcome(pkg, .updateAvailable(offer("2.0", format: .pkg))),
            outcome(low, .updateAvailable(offer("2.0", source: cask)), source: cask, low: true)],
            installer: installer, adminUpdates: true, packageUpdates: true)
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: admin.path) }   // learn that Admin needs admin
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: nil)
        try expect(controller.availableUpdateCount == 3, "badge: \(controller.availableUpdateCount)")
        try expect(entry.menu.title == "Update All (1)" && entry.menu.enabled, "menu: \(entry.menu)")
    }

    check("update-all menu: progress and Stop Updating while a run is in progress; Stop ends it after the current app") {
        let a = app("Alpha"), b = app("Bravo"), c = app("Charlie")
        let installer = FakeInstaller()
        let gate = Gate()
        installer.updateHandler = { outcome, _ in
            await gate.wait()
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [a, b, c].map { outcome($0, .updateAvailable(offer("2.0"))) }, installer: installer)
        let notifier = FakeSummaryNotifier()
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: notifier)
        await runCheck(controller)
        entry.requestUpdateAll()
        for _ in 0..<200 where updateEvents(installer).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let running = entry.menu
        try expect(running.progressText == "Updating 1 of 3…" && running.showsStop && running.stopEnabled && !running.enabled, "running: \(running)")
        entry.requestStop()
        try expect(entry.menu.progressText == "Stopping after this app…" && entry.menu.showsStop && !entry.menu.stopEnabled, "stopping: \(entry.menu)")
        gate.open(); await controller.waitUntilIdle()
        try expect(updateEvents(installer) == ["update Alpha quit=false"], "Stop did not stop: \(updateEvents(installer))")
        try expect(controller.updateAllProgress == nil && !entry.menu.showsStop, "progress left behind")
        try expect(notifier.posted == [UpdateAllSummary(updated: 1, failed: 0, skippedOpen: 0, needsAdmin: 0, stopped: 2)], "summary: \(notifier.posted)")
    }

    check("update-all menu: the action calls updateAll exactly once and installs each app once") {
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("Bravo"), .updateAvailable(offer("2.0")))])
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        rig.controller.check(); await rig.settle()
        let before = rig.controller.updateAllInvocations
        entry.requestUpdateAll(); await rig.settle()
        try expect(rig.controller.updateAllInvocations == before + 1, "updateAll called \(rig.controller.updateAllInvocations - before) times")
        try expect(updateEvents(rig.installer) == ["update Alpha quit=false", "update Bravo quit=false"], "installs: \(rig.installer.recorder.events)")
        try expect(!entry.menu.visible, "item still offered after everything updated: \(entry.menu)")
    }

    check("update-all entry points keep Update All's rules: open apps skipped and never quit, admin rows skipped, rechecked first, failures do not stop") {
        let open = app("Open"), admin = app("Admin"), bad = app("Bad"), good = app("Good"), pkg = app("Pkgy")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, quit in
            switch outcome.app.name {
            case "Open": throw InstallRefusal.appRunning("open")
            case "Bad": throw FakeNetworkDown()   // an ordinary failure
            default: return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
            }
        }
        let controller = makeController(outcomes: [
            outcome(admin, .updateAvailable(offer("2.0"))), outcome(bad, .updateAvailable(offer("2.0"))), outcome(good, .updateAvailable(offer("2.0"))),
            outcome(open, .updateAvailable(offer("2.0"))), outcome(pkg, .updateAvailable(offer("2.0", format: .pkg)))],
            installer: installer, adminUpdates: true, packageUpdates: true)
        let notifier = FakeSummaryNotifier()
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: notifier)
        await runCheck(controller)
        // Make "Admin" a known admin row, as an earlier click would have.
        installer.updateHandler = { [base = installer.updateHandler] outcome, quit in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return try await base(outcome, quit)
        }
        entry.requestUpdateAll(); await controller.waitUntilIdle()
        try expect(installer.recorder.events.filter { $0.hasPrefix("admin") }.isEmpty, "consent passed: \(installer.recorder.events)")
        try expect(installer.recorder.events.filter { $0.hasPrefix("update ") && !$0.hasSuffix("quit=false") }.isEmpty, "an app was quit: \(installer.recorder.events)")
        for name in ["Admin", "Bad", "Good", "Open"] {
            try expect(installer.recorder.events.contains("recheck \(name).app"), "\(name) not rechecked: \(installer.recorder.events)")
        }
        try expect(installer.recorder.events.contains("update Good quit=false"), "failure stopped the rest: \(installer.recorder.events)")
        let installerRows = controller.rows.first { $0.name == "Pkgy" }
        try expect(installerRows?.privilege == .installer && !installer.recorder.events.contains { $0.contains("Pkgy") && $0.hasPrefix("update") }, "pkg row was installed")
        try expect(controller.rows.first { $0.name == "Open" }?.result?.text.contains("is open") == true, "open app not reported")
        try expect(notifier.posted == [UpdateAllSummary(updated: 1, failed: 1, skippedOpen: 1, needsAdmin: 2, openPaths: [open.path])], "summary: \(notifier.posted)")
    }

    check("update-all summary text, and one summary notification per run, only from these entry points") {
        let full = UpdateAllSummary(updated: 3, failed: 0, skippedOpen: 1, needsAdmin: 1)
        try expect(full.text == "Updated 3 apps; 1 skipped because it is open; 1 needs admin", "text: \(full.text)")
        try expect(UpdateAllSummary(updated: 0, failed: 0, skippedOpen: 0, needsAdmin: 0, changed: 2).text
                   == "Updated 0 apps; 2 changed since the notification, not installed", "changed text")
        try expect(UpdateAllSummary(updated: 1, failed: 2, skippedOpen: 2, needsAdmin: 2).text
                   == "Updated 1 app; 2 failed; 2 skipped because they are open; 2 need admin", "plural text")
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        let notifier = FakeSummaryNotifier()
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: notifier)
        rig.controller.check(); await rig.settle()
        entry.requestUpdateAll(); await rig.settle()
        try expect(notifier.posted.count == 1 && notifier.posted[0].text == "Updated 1 app", "posted: \(notifier.posted)")
        rig.controller.check(); await rig.settle(); await yieldAFewTimes()
        entry.requestUpdateAll(); await rig.settle()
        try expect(notifier.posted.count == 1, "repeated, or posted for a run with nothing to do: \(notifier.posted)")
        // The Updates window's own Update All posts no summary: the same summary-delivery dependency is
        // attached to this controller, and only the entry point's own run may use it.
        let win = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        let windowSummaries = FakeSummaryNotifier()
        _ = UpdateAllEntryPoint(controller: win.controller, summaryNotifier: windowSummaries)
        win.controller.check(); await win.settle()
        await runOperation(win.controller) { win.controller.updateAll() }   // what the Updates window's button calls
        try expect(updateEvents(win.installer).count == 1, "window run did not install")
        try expect(windowSummaries.posted.isEmpty, "window run posted a summary: \(windowSummaries.posted)")
    }

    check("update-all summary: an app refused as needs_admin counts as needs admin with admin updates off (default settings)") {
        let admin = app("Admin"), good = app("Good"), pkg = app("Pkgy")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [
            outcome(admin, .updateAvailable(offer("2.0"))), outcome(good, .updateAvailable(offer("2.0"))),
            outcome(pkg, .updateAvailable(offer("2.0", format: .pkg)))], installer: installer)   // adminUpdates default false
        let notifier = FakeSummaryNotifier()
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: notifier)
        await runCheck(controller)
        entry.requestUpdateAll(); await controller.waitUntilIdle()
        try expect(notifier.posted == [UpdateAllSummary(updated: 1, failed: 0, skippedOpen: 0, needsAdmin: 2)],
                   "summary: \(notifier.posted.map(\.text))")
    }

    check("update-all notification: only the Update All button routes to updateAll; the body tap only opens Updates") {
        let notifier = SystemUpdateNotifier()
        let opens = Tally(), updates = Tally()
        notifier.onOpenUpdates = { opens.n += 1 }
        notifier.onUpdateAll = { _ in updates.n += 1 }
        let id = SystemUpdateNotifier.requestIdentifier
        notifier.handle(requestIdentifier: id, actionIdentifier: UNNotificationDefaultActionIdentifier)
        try expect(opens.n == 1 && updates.n == 0, "body tap: opens \(opens.n) updates \(updates.n)")
        notifier.handle(requestIdentifier: id, actionIdentifier: SystemUpdateNotifier.updateAllActionIdentifier)
        try expect(opens.n == 1 && updates.n == 1, "button: opens \(opens.n) updates \(updates.n)")
        notifier.handle(requestIdentifier: "someone.else", actionIdentifier: SystemUpdateNotifier.updateAllActionIdentifier)
        notifier.handle(requestIdentifier: SystemUpdateNotifier.summaryIdentifier, actionIdentifier: SystemUpdateNotifier.updateAllActionIdentifier)
        notifier.handle(requestIdentifier: id, actionIdentifier: UNNotificationDismissActionIdentifier)
        try expect(opens.n == 1 && updates.n == 1, "foreign or dismiss response acted: opens \(opens.n) updates \(updates.n)")
        // The summary notification opens Updates when tapped but never offers Update All.
        notifier.handle(requestIdentifier: SystemUpdateNotifier.summaryIdentifier, actionIdentifier: UNNotificationDefaultActionIdentifier)
        try expect(opens.n == 2 && updates.n == 1, "summary tap")
        let category = SystemUpdateNotifier.makeCategory()
        try expect(category.identifier == SystemUpdateNotifier.categoryIdentifier && category.actions.count == 1
                   && category.actions[0].identifier == SystemUpdateNotifier.updateAllActionIdentifier
                   && category.actions[0].title == "Update All" && !category.actions[0].options.contains(.foreground), "category")
    }

    check("update-all notification: the button carries the advertised keys (userInfo), queued with them if pressed before the handler is ready") {
        let id = SystemUpdateNotifier.requestIdentifier
        let key = SystemUpdateNotifier.updateKeysUserInfoKey
        let notifier = SystemUpdateNotifier()
        let got = KeysBox()
        notifier.handle(requestIdentifier: id, actionIdentifier: SystemUpdateNotifier.updateAllActionIdentifier, userInfo: [key: ["a", "b"]])
        try expect(got.all.isEmpty, "ran with no handler")
        notifier.onUpdateAll = { got.all.append($0) }
        try expect(got.all == [["a", "b"]], "queued press did not run once with its keys: \(got.all)")
        notifier.onUpdateAll = { got.all.append($0) }
        try expect(got.all.count == 1, "queued press ran twice")
        // A response with no advertised keys advertises nothing.
        notifier.handle(requestIdentifier: id, actionIdentifier: SystemUpdateNotifier.updateAllActionIdentifier)
        try expect(got.all.last == [], "keyless response carried keys: \(got.all)")
    }

    check("update-all notification: cold launch queues the click with its keys, checks first, and runs only the advertised updates once") {
        let alpha = app("Alpha"), bravo = app("Bravo")
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0"))), outcome(bravo, .updateAvailable(offer("2.0")))])
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        let opens = Opens(); entry.openUpdates = { opens.n += 1 }
        let gate = rig.hold()
        let late = SystemUpdateNotifier()
        late.handle(requestIdentifier: SystemUpdateNotifier.requestIdentifier, actionIdentifier: SystemUpdateNotifier.updateAllActionIdentifier,
                    userInfo: [SystemUpdateNotifier.updateKeysUserInfoKey: Array(advertised([alpha]))])
        late.onUpdateAll = { entry.requestUpdateAll(only: $0) }   // the wiring at launch, before the first check
        try expect(rig.controller.phase == .checking && rig.controller.updateAllQueued && entry.menu.progressText == UpdateAllMenuState.queuedText,
                   "click on a fresh launch was not held for the first check: phase \(rig.controller.phase) menu \(entry.menu)")
        try expect(updateEvents(rig.installer).isEmpty, "installed before any check")
        gate.open(); await rig.settle(); await yieldAFewTimes(); await rig.settle()
        try expect(updateEvents(rig.installer) == ["update Alpha quit=false"] && rig.controller.updateAllInvocations == 1 && opens.n == 0,
                   "after the first check: \(updateEvents(rig.installer)) calls \(rig.controller.updateAllInvocations) opens \(opens.n)")
        try expect(!rig.controller.updateAllQueued, "queue left behind")
    }

    check("update-all notification: cold launch whose first check fails drops the click and opens Updates") {
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        rig.checks.failing = true
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        let opens = Opens(); entry.openUpdates = { opens.n += 1 }
        entry.requestUpdateAll(only: advertised([app("Alpha")]))
        await rig.settle(); await yieldAFewTimes()
        try expect(updateEvents(rig.installer).isEmpty && !rig.controller.updateAllQueued && opens.n == 1,
                   "failed check: installs \(updateEvents(rig.installer)) queued \(rig.controller.updateAllQueued) opens \(opens.n)")
        // A later successful check must not resurrect it.
        rig.checks.failing = false
        rig.controller.check(); await rig.settle(); await yieldAFewTimes()
        try expect(updateEvents(rig.installer).isEmpty, "dropped click ran after a later check")
    }

    check("update-all notification: pressed while a check runs, waits, then installs only the advertised updates still offered, once") {
        let alpha = app("Alpha"), bravo = app("Bravo"), charlie = app("Charlie")
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0"))), outcome(bravo, .updateAvailable(offer("2.0"))),
                       outcome(charlie, .updateAvailable(offer("2.0")))])
        rig.controller.check(); await rig.settle()
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        let gate = rig.hold()
        rig.controller.check()
        let keys = advertised([alpha, bravo])   // the notification advertised Alpha and Bravo, not Charlie
        entry.requestUpdateAll(only: keys); entry.requestUpdateAll(only: keys)
        try expect(rig.controller.updateAllInvocations == 0 && updateEvents(rig.installer).isEmpty, "ran during a check")
        rig.world.install(bravo.path, version: "2.0")   // Bravo was updated elsewhere meanwhile
        gate.open(); await rig.settle(); await yieldAFewTimes(); await rig.settle()
        try expect(updateEvents(rig.installer) == ["update Alpha quit=false"] && rig.controller.updateAllInvocations == 1,
                   "after the check: \(updateEvents(rig.installer)) calls \(rig.controller.updateAllInvocations)")
    }

    check("update-all notification: a different update set (new app, or a newer version of an advertised app) is not installed") {
        let alpha = app("Alpha"), bravo = app("Bravo")
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0"))), outcome(bravo, .updateAvailable(offer("2.0")))])
        rig.controller.check(); await rig.settle()
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        let opens = Opens(); entry.openUpdates = { opens.n += 1 }
        // Alpha's offer moves on to 3.0 after the notification advertised 2.0 (found by the per-app recheck).
        rig.world[alpha.path] = outcome(alpha, .updateAvailable(offer("3.0")))
        entry.requestUpdateAll(only: advertised([alpha])); await rig.settle()
        try expect(updateEvents(rig.installer).isEmpty,
                   "installed a version that was not advertised: \(updateEvents(rig.installer))")
        try expect(!updateEvents(rig.installer).contains { $0.contains("Bravo") }, "installed an unadvertised app")
        // It is reported as changed since the notification, not as a failure.
        let r2 = Rig([outcome(alpha, .updateAvailable(offer("2.0")))])
        r2.controller.check(); await r2.settle()
        let summaries = FakeSummaryNotifier()
        let reporting = UpdateAllEntryPoint(controller: r2.controller, summaryNotifier: summaries)
        r2.world[alpha.path] = outcome(alpha, .updateAvailable(offer("3.0")))
        reporting.requestUpdateAll(only: advertised([alpha])); await r2.settle()
        try expect(summaries.posted.count == 1 && summaries.posted[0].changed == 1 && summaries.posted[0].failed == 0
                   && summaries.posted[0].text == "Updated 0 apps; 1 changed since the notification, not installed",
                   "summary: \(summaries.posted.map(\.text))")
        // Nothing advertised is installable any more: install nothing, open Updates.
        entry.requestUpdateAll(only: advertised([app("Ghost")])); await rig.settle()
        try expect(updateEvents(rig.installer).isEmpty && opens.n == 1, "empty intersection: \(updateEvents(rig.installer)) opens \(opens.n)")
    }

    check("update-all queued: cancelling the check, or Cancel in the menu, leaves nothing installed; a successful check releases it once") {
        let alpha = app("Alpha")
        // Queue during a check, then cancel the check (the Updates window's Cancel).
        let a = Rig([outcome(alpha, .updateAvailable(offer("2.0")))])
        a.controller.check(); await a.settle()
        let ea = UpdateAllEntryPoint(controller: a.controller, summaryNotifier: nil)
        let opensA = Opens(); ea.openUpdates = { opensA.n += 1 }
        let gateA = a.hold()
        a.controller.check()
        ea.requestUpdateAll(only: advertised([alpha]))
        try expect(a.controller.updateAllQueued && ea.menu.showsCancelQueued && ea.menu.progressText == UpdateAllMenuState.queuedText, "not shown as queued: \(ea.menu)")
        a.controller.cancelCheck()
        gateA.open(); await a.settle(); await yieldAFewTimes(); await a.settle()
        try expect(updateEvents(a.installer).isEmpty && !a.controller.updateAllQueued && !ea.menu.showsCancelQueued,
                   "cancelled check released the click: \(updateEvents(a.installer))")
        // Queue during a check, then Cancel from the menu.
        let b = Rig([outcome(alpha, .updateAvailable(offer("2.0")))])
        b.controller.check(); await b.settle()
        let eb = UpdateAllEntryPoint(controller: b.controller, summaryNotifier: nil)
        let gateB = b.hold()
        b.controller.check()
        eb.requestUpdateAll(only: advertised([alpha]))
        eb.requestStop()
        try expect(!b.controller.updateAllQueued && !eb.menu.showsCancelQueued, "menu Cancel left it queued: \(eb.menu)")
        gateB.open(); await b.settle(); await yieldAFewTimes(); await b.settle()
        try expect(updateEvents(b.installer).isEmpty, "menu-cancelled click ran: \(updateEvents(b.installer))")
        // Queue during a check that succeeds: one scoped run.
        let c = Rig([outcome(alpha, .updateAvailable(offer("2.0")))])
        c.controller.check(); await c.settle()
        let ec = UpdateAllEntryPoint(controller: c.controller, summaryNotifier: nil)
        let gateC = c.hold()
        c.controller.check()
        ec.requestUpdateAll(only: advertised([alpha]))
        gateC.open(); await c.settle(); await yieldAFewTimes(); await c.settle()
        try expect(updateEvents(c.installer) == ["update Alpha quit=false"] && c.controller.updateAllInvocations == 1, "success: \(updateEvents(c.installer))")
    }

    check("update-all: a stale offer is rechecked and not installed when it changed after the notification") {
        let alpha = app("Alpha"), bravo = app("Bravo")
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0"))), outcome(bravo, .updateAvailable(offer("2.0")))])
        rig.controller.check(); await rig.settle()
        rig.world.install(bravo.path, version: "2.0")   // updated elsewhere since the notification
        UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil).requestUpdateAll(); await rig.settle()
        try expect(updateEvents(rig.installer) == ["update Alpha quit=false"], "stale row installed: \(rig.installer.recorder.events)")
    }

    check("update-all: with automatic updates off the scheduler path never reaches updateAll, the installer or a summary; only the click paths and the gated automatic run call it") {
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        rig.scheduler.start(); await rig.settle()
        rig.clock.advance(UpdateCheckScheduler.interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "no notification posted")
        try rig.noInstallerActivity()
        try expect(rig.controller.updateAllInvocations == 0, "scheduler called updateAll")
        // Source guard: the scheduler file calls Update All in exactly one place, the automatic run (gated on the
        // setting, in its narrow `automatic: true` form). Otherwise only the Updates window and the entry point call it.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String]) ?? []
        var callers: [String] = []
        for relative in files where relative.hasSuffix(".swift") {
            let text = try String(contentsOfFile: sources.path + "/" + relative, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if relative == "PatchedClient/BackgroundUpdateChecks.swift" {
                let calls = code.components(separatedBy: "updateAll(").count - 1
                try expect(calls == 1 && code.contains("updateAll(only: nil, askInWindow: false, automatic: true)"),
                           "\(relative) must call updateAll once, in its automatic form: \(calls) calls")
                let guarded = code.components(separatedBy: "private func runAutomaticIfDue()")
                try expect(guarded.count == 2 && guarded[1].contains("guard started, let automatic, automaticRunWouldStart()")
                           && guarded[0].components(separatedBy: "updateAll(").count == 1,
                           "\(relative): the install call is not inside the setting-gated runAutomaticIfDue()")
            }
            if code.contains("updateAll(") { callers.append(relative) }
        }
        try expect(callers.sorted() == ["PatchedClient/AppUpdatesController.swift", "PatchedClient/AppUpdatesView.swift", "PatchedClient/BackgroundUpdateChecks.swift", "PatchedClient/UpdateAllEntryPoints.swift"],
                   "callers of updateAll: \(callers.sorted())")
    }
}
