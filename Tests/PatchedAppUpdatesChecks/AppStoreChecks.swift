import Foundation
import SwiftUI
import UpdateSources
import UpdateInstaller
import PatchedShell
@_spi(Testing) import PatchedClient

// App Store updates (never installed by Patched), no-source labels and the Help & Support panel.
// The URL opener is a recorder: nothing here opens a real URL or app.

@MainActor final class RecordingOpener: ExternalURLOpening {
    var urls: [URL] = []
    var apps: [String] = []
    /// Every URL open fails (the App Store scheme stopped working).
    var failURLs = false
    /// Launching the App Store app by bundle ID fails too.
    var failApps = false
    func open(_ url: URL) -> Bool { urls.append(url); return !failURLs }
    func openApplication(bundleID: String) async -> Bool { apps.append(bundleID); return !failApps }
    /// Installed app bundles opened by path (an admin-required row's Open <app>).
    var appPaths: [String] = []
    /// What a launch by path reports.
    var appPathResult: AppOpenResult = .opened
    /// The bundle and team IDs each launch was asked to revalidate against.
    var appExpectations: [String] = []
    func openApplication(atPath path: String, expectedBundleID: String, expectedTeamID: String?) async -> AppOpenResult {
        appPaths.append(path); appExpectations.append(expectedBundleID + "/" + (expectedTeamID ?? "-")); return appPathResult
    }
    var nothingOpened: Bool { urls.isEmpty && apps.isEmpty && appPaths.isEmpty }
}

func storeApp(_ name: String) -> InstalledApp {
    InstalledApp(name: name, path: "/Fake/\(name).app", bundleID: "com.example.\(name.lowercased())",
                 shortVersion: "1.0", build: "1.0", isAppStore: true)
}
func storeOutcome(_ app: InstalledApp, version: String = "3.0", track: Int = 1234) -> AppCheckOutcome {
    let source = UpdateSource.appStore(trackID: track)
    return AppCheckOutcome(app: app, teamID: nil, source: source, lowConfidence: false, installable: false,
                           result: .updateAvailable(offer(version, source: source)))
}

@MainActor func registerAppStoreChecks() {
    let updatesPage = AppStoreLinks.updatesPageURL

    check("updates screen: installable updates first, then App Store ones, then the rest, alphabetical within each") {
        let controller = makeController(outcomes: [outcome(app("Alpha"), .upToDate), storeOutcome(storeApp("Bravo")),
                                                   outcome(app("Charlie"), .updateAvailable(offer("2.0"))),
                                                   outcome(app("Delta"), .upToDate),
                                                   outcome(app("Echo"), .updateAvailable(offer("2.0")))])
        await runCheck(controller)
        let shown = controller.updatesRows.updatesFirst.map(\.name)
        try expect(shown == ["Charlie", "Echo", "Bravo", "Alpha", "Delta"], "order: \(shown)")
        try expect(controller.rows.map(\.name) == ["Alpha", "Bravo", "Charlie", "Delta", "Echo"], "rows reordered: \(controller.rows.map(\.name))")
        let view = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/AppUpdatesView.swift", encoding: .utf8)
        try expect(view.contains("ForEach(controller.updatesRows.updatesFirst)"), "the Updates screen does not list updates first")
    }

    check("app store row: badge, status text, no Update; the installer is never reached") {
        let installer = FakeInstaller()
        let controller = makeController(outcomes: [storeOutcome(storeApp("Store")), outcome(app("Plain"), .updateAvailable(offer("2.0")))], installer: installer)
        await runCheck(controller)
        let row = try controller.rows.first { $0.name == "Store" }.unwrap()
        try expect(row.source == "App Store" && row.statusText == "Update in the App Store" && row.isAppStoreUpdate, "row: \(row.source) / \(row.statusText)")
        try expect(row.latestVersion == "3.0", "latest: \(String(describing: row.latestVersion))")
        try expect(!controller.canUpdate(row), "App Store row offers Update")
        controller.update(id: row.id); await controller.waitUntilIdle()
        try expect(!installer.recorder.events.contains { $0.hasPrefix("update") }, "installer reached: \(installer.recorder.events)")
        // The view offers Open in App Store for these rows, and its Update button is for the other statuses only.
        let view = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/AppUpdatesView.swift", encoding: .utf8)
        try expect(view.contains("if row.isAppStoreUpdate") && view.contains("Open in App Store") && view.contains("controller.openInAppStore(id: row.id)"),
                   "view lacks the Open in App Store button")
        try expect(view.contains("row.status == .updateAvailable || row.status == .notInstallable || row.status == .packageUnsupported"),
                   "Update button condition changed")
    }

    check("app store row: Open in App Store opens the app's macappstore URL once, and installs nothing") {
        let installer = FakeInstaller(), opener = RecordingOpener()
        let controller = makeController(outcomes: [storeOutcome(storeApp("Store"), track: 4242)], installer: installer)
        controller.urlOpener = opener
        await runCheck(controller)
        try expect(opener.nothingOpened, "checking opened something: \(opener.urls)")
        controller.openInAppStore(id: "/Fake/Store.app")
        try expect(opener.urls.map(\.absoluteString) == ["macappstore://apps.apple.com/app/id4242"] && opener.apps.isEmpty, "opened: \(opener.urls) \(opener.apps)")
        // Not an App Store row: nothing opens.
        let plain = makeController(outcomes: [outcome(app("Plain"), .updateAvailable(offer("2.0")))])
        plain.urlOpener = opener
        await runCheck(plain)
        plain.openInAppStore(id: "/Fake/Plain.app")
        try expect(opener.urls.count == 1, "opened for a non-App Store row")
        try expect(!installer.recorder.events.contains { $0.hasPrefix("update") }, "installed")
    }

    check("app store row: a failed open falls back to the Updates page, then the App Store app, and says so") {
        let opener = RecordingOpener(); opener.failURLs = true
        let controller = makeController(outcomes: [storeOutcome(storeApp("Store"))])
        controller.urlOpener = opener
        await runCheck(controller)
        controller.openInAppStore(id: "/Fake/Store.app"); await controller.waitUntilIdle()
        try expect(opener.urls.count == 2 && opener.urls[1] == updatesPage && opener.apps == [AppStoreLinks.appBundleID], "fallback: \(opener.urls) \(opener.apps)")
        try expect(controller.rows[0].result == nil, "failure shown although the App Store app opened: \(String(describing: controller.rows[0].result))")
        // Every fallback fails: the row says so.
        opener.failApps = true
        controller.openInAppStore(id: "/Fake/Store.app"); await controller.waitUntilIdle()
        try expect(controller.rows[0].result?.text == "Couldn't open the App Store. Open it and choose Updates.", "no failure text: \(String(describing: controller.rows[0].result))")
    }

    check("update all: installable updates first, then the App Store Updates page once; summary names the App Store") {
        let opener = RecordingOpener(), notifier = FakeSummaryNotifier()
        let installer = FakeInstaller()
        let seen = Tally()
        installer.updateHandler = { outcome, _ in
            await MainActor.run { seen.n += opener.urls.count }   // the page must not be open yet
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))),
            storeOutcome(storeApp("Store")), storeOutcome(storeApp("Store2"))], installer: installer)
        controller.urlOpener = opener
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: notifier)
        await runCheck(controller)
        try expect(entry.menu.title == "Update All (3)" && entry.menu.detail == "1 here, 2 via the App Store" && entry.menu.enabled, "menu: \(entry.menu)")
        entry.requestUpdateAll(); await controller.waitUntilIdle()
        try expect(updateEvents(installer) == ["update Alpha quit=false"], "installs: \(installer.recorder.events)")
        try expect(seen.n == 0, "App Store opened before the install finished")
        try expect(opener.urls == [updatesPage] && opener.apps.isEmpty, "opened: \(opener.urls) \(opener.apps)")
        try expect(notifier.posted.map(\.text) == ["Updated 1 app; 2 to update in the App Store"], "summary: \(notifier.posted.map(\.text))")
        // The window's own Update All: same rule, summary line on screen.
        let win = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))), storeOutcome(storeApp("Store"))])
        let winOpener = RecordingOpener(); win.urlOpener = winOpener
        await runCheck(win)
        try expect(win.canUpdateAll, "window Update All disabled")
        await runOperation(win) { win.updateAll() }
        try expect(winOpener.urls == [updatesPage] && win.summary.contains("1 to update in the App Store"), "window: \(winOpener.urls) \(win.summary)")
    }

    check("update all: only App Store updates just opens the Updates page, once, and installs nothing") {
        let opener = RecordingOpener(), notifier = FakeSummaryNotifier(), installer = FakeInstaller()
        let controller = makeController(outcomes: [storeOutcome(storeApp("Store")), outcome(app("Done"), .upToDate)], installer: installer)
        controller.urlOpener = opener
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: notifier)
        await runCheck(controller)
        try expect(entry.menu.visible && entry.menu.title == "Update All (1)" && entry.menu.detail == "1 via the App Store" && entry.menu.enabled, "menu: \(entry.menu)")
        entry.requestUpdateAll(); await controller.waitUntilIdle()
        try expect(opener.urls == [updatesPage], "opened: \(opener.urls)")
        try expect(!installer.recorder.events.contains { $0.hasPrefix("update") || $0.hasPrefix("recheck") }, "touched the installer: \(installer.recorder.events)")
        try expect(notifier.posted.map(\.text) == ["1 to update in the App Store"], "summary: \(notifier.posted.map(\.text))")
        try expect(!controller.isWorking && controller.updateAllProgress == nil, "left working")
        // Nothing to offer: no menu row, and Update All does not open anything.
        let none = makeController(outcomes: [outcome(app("Done"), .upToDate)])
        let noneOpener = RecordingOpener(); none.urlOpener = noneOpener
        await runCheck(none)
        try expect(!UpdateAllEntryPoint(controller: none, summaryNotifier: nil).menu.visible && !none.updateAll() && noneOpener.nothingOpened, "opened with nothing on offer")
    }

    check("update all: no admin consent is passed and a blocked state opens nothing") {
        let opener = RecordingOpener(), installer = FakeInstaller()
        let broken = Counter()
        let controller = makeController(outcomes: [storeOutcome(storeApp("Store"))], installer: installer,
                                        catalogue: { broken.value > 0 ? "/x/catalogue.json: not a JSON object" : nil })
        controller.urlOpener = opener
        await runCheck(controller)
        _ = broken.next(); await controller.refreshInstallerState()
        try expect(!controller.updateAll() && opener.nothingOpened, "opened while updates are paused: \(opener.urls)")
        try expect(!installer.recorder.events.contains { $0.hasPrefix("admin") }, "admin consent")
    }

    check("update all from a notification: opens the Updates page only when an advertised update is an App Store one") {
        let alpha = app("Alpha"), store = storeApp("Store")
        let opener = RecordingOpener()
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0"))), storeOutcome(store)])
        rig.controller.urlOpener = opener
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        await runCheck(rig.controller)
        // Advertised: only the installable one.
        entry.requestUpdateAll(only: advertised([alpha])); await rig.settle()
        try expect(updateEvents(rig.installer) == ["update Alpha quit=false"] && opener.nothingOpened, "installable-only scope opened: \(opener.urls)")
        // Advertised: only the App Store one (the key is what the notifier would carry).
        let storeKey = AvailableUpdate(path: store.path, name: store.name, version: "3.0", build: "3.0", appStore: true).key
        entry.requestUpdateAll(only: [storeKey]); await rig.settle()
        try expect(opener.urls == [updatesPage], "advertised App Store update did not open the page: \(opener.urls)")
        try expect(updateEvents(rig.installer) == ["update Alpha quit=false"], "extra installs: \(updateEvents(rig.installer))")
        // A different App Store version than advertised is not in scope.
        entry.requestUpdateAll(only: [AvailableUpdate(path: store.path, name: store.name, version: "2.5", build: "2.5").key]); await rig.settle()
        try expect(opener.urls.count == 1, "opened for an update that was not advertised")
    }

    check("update all: Stop Updating means the App Store is not opened afterwards") {
        let opener = RecordingOpener(), installer = FakeInstaller(), gate = Gate()
        installer.updateHandler = { _, _ in
            await gate.wait()
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))),
            outcome(app("Bravo"), .updateAvailable(offer("2.0"))), storeOutcome(storeApp("Store"))], installer: installer)
        controller.urlOpener = opener
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: nil)
        await runCheck(controller)
        entry.requestUpdateAll()
        for _ in 0..<200 where updateEvents(installer).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        entry.requestStop()
        gate.open(); await controller.waitUntilIdle()
        try expect(updateEvents(installer) == ["update Alpha quit=false"], "Stop did not stop: \(updateEvents(installer))")
        try expect(opener.nothingOpened, "App Store opened after Stop: \(opener.urls)")
    }

    check("update all: App Store only, with a known admin row and a pkg row, still counts them as needing admin") {
        let admin = app("Admin"), pkg = app("Pkgy")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [outcome(admin, .updateAvailable(offer("2.0"))),
            outcome(pkg, .updateAvailable(offer("2.0", format: .pkg))), storeOutcome(storeApp("Store"))],
            installer: installer, adminUpdates: true, packageUpdates: true)
        let opener = RecordingOpener(), notifier = FakeSummaryNotifier()
        controller.urlOpener = opener
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: admin.path) }   // learn that Admin needs admin
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: notifier)
        entry.requestUpdateAll(); await controller.waitUntilIdle()
        try expect(notifier.posted == [UpdateAllSummary(updated: 0, failed: 0, skippedOpen: 0, needsAdmin: 2, appStore: 1)]
                   && notifier.posted[0].text == "Updated 0 apps; 2 need admin; 1 to update in the App Store",
                   "summary: \(notifier.posted.map(\.text))")
        try expect(opener.urls == [updatesPage], "opened: \(opener.urls)")
    }

    check("window Update All is enabled exactly when the menu item is, for App Store rows in idle, blocked, busy and checking states") {
        let broken = Counter()
        let installer = FakeInstaller()
        let controller = makeController(outcomes: [storeOutcome(storeApp("Store"))], installer: installer,
                                        catalogue: { broken.value > 0 ? "/x/catalogue.json: not a JSON object" : nil })
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: nil)
        await runCheck(controller)
        try expect(controller.canUpdateAll && entry.menu.enabled, "idle: window \(controller.canUpdateAll) menu \(entry.menu.enabled)")
        _ = broken.next(); await controller.refreshInstallerState()
        try expect(!controller.canUpdateAll && !entry.menu.enabled, "blocked: window \(controller.canUpdateAll) menu \(entry.menu.enabled)")
        // Busy: an install in progress.
        let gate = Gate()
        let busyInstaller = FakeInstaller()
        busyInstaller.updateHandler = { _, _ in await gate.wait(); return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0") }
        let busy = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))), storeOutcome(storeApp("Store"))], installer: busyInstaller)
        let busyEntry = UpdateAllEntryPoint(controller: busy, summaryNotifier: nil)
        await runCheck(busy)
        busy.update(id: "/Fake/Alpha.app")
        for _ in 0..<200 where updateEvents(busyInstaller).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try expect(busy.isWorking && !busy.canUpdateAll && !busyEntry.menu.enabled, "busy: window \(busy.canUpdateAll) menu \(busyEntry.menu.enabled)")
        gate.open(); await busy.waitUntilIdle()
        try expect(busy.canUpdateAll == busyEntry.menu.enabled, "after: window \(busy.canUpdateAll) menu \(busyEntry.menu.enabled)")
        // Checking.
        let rig = Rig([storeOutcome(storeApp("Store"))])
        let rigEntry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        await runCheck(rig.controller)
        let hold = rig.hold()
        rig.controller.check()
        try expect(rig.controller.phase == .checking && !rig.controller.canUpdateAll && !rigEntry.menu.enabled,
                   "checking: window \(rig.controller.canUpdateAll) menu \(rigEntry.menu.enabled)")
        hold.open(); await rig.settle()
    }

    check("update all: a failing Updates page URL opens the App Store app by bundle ID, once") {
        let opener = RecordingOpener(); opener.failURLs = true
        let notifier = FakeSummaryNotifier()
        let controller = makeController(outcomes: [storeOutcome(storeApp("Store"))])
        controller.urlOpener = opener
        let entry = UpdateAllEntryPoint(controller: controller, summaryNotifier: notifier)
        await runCheck(controller)
        entry.requestUpdateAll(); await controller.waitUntilIdle()
        try expect(opener.urls == [updatesPage] && opener.apps == [AppStoreLinks.appBundleID], "fallback: \(opener.urls) \(opener.apps)")
        try expect(notifier.posted.map(\.text) == ["1 to update in the App Store"], "summary: \(notifier.posted.map(\.text))")
        // Both the URL and the bundle-ID launch fail: not reported as handed over.
        opener.failApps = true
        entry.requestUpdateAll(); await controller.waitUntilIdle()
        try expect(notifier.posted.last == UpdateAllSummary(updated: 0, failed: 0, skippedOpen: 0, needsAdmin: 0, appStoreFailed: 1)
                   && notifier.posted.last?.text == "couldn't open the App Store for 1", "failed summary: \(notifier.posted.map(\.text))")
        try expect(controller.summary == "Couldn't open the App Store. Open it and choose Updates.", "window summary: \(controller.summary)")
        // Mixed run with everything failing counts the failure too.
        let mixed = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))), storeOutcome(storeApp("Store"))])
        let mixedOpener = RecordingOpener(); mixedOpener.failURLs = true; mixedOpener.failApps = true
        mixed.urlOpener = mixedOpener
        let mixedNotifier = FakeSummaryNotifier()
        let mixedEntry = UpdateAllEntryPoint(controller: mixed, summaryNotifier: mixedNotifier)
        await runCheck(mixed)
        mixedEntry.requestUpdateAll(); await mixed.waitUntilIdle()
        try expect(mixedNotifier.posted.map(\.text) == ["Updated 1 app; couldn't open the App Store for 1"], "mixed failed: \(mixedNotifier.posted.map(\.text))")
    }

    check("notifications: App Store updates are advertised, named, deduplicated and counted in the badge; the scheduler never opens anything") {
        let alpha = app("Alpha"), store = storeApp("Windows App")
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0"))), storeOutcome(store, version: "11.2")])
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "notifications: \(rig.notifier.posted.count)")
        let sent = rig.notifier.posted[0]
        try expect(sent.map(\.name) == ["Alpha", "Windows App"] && sent.map(\.appStore) == [false, true], "advertised: \(sent)")
        try expect(rig.controller.availableUpdateCount == 2, "badge: \(rig.controller.availableUpdateCount)")
        let storeKey = AvailableUpdate(path: store.path, name: store.name, version: "11.2", build: "11.2").key
        try expect(rig.store.notifiedKeys.contains(storeKey), "App Store key not recorded: \(rig.store.notifiedKeys)")
        try expect(SystemUpdateNotifier.body(sent) == "Alpha 2.0, plus Windows App 11.2 in the App Store", "body: \(SystemUpdateNotifier.body(sent))")
        try expect(SystemUpdateNotifier.body(Array(sent.suffix(1))) == "Windows App 11.2 in the App Store", "store-only body")
        try expect(SystemUpdateNotifier.body(Array(sent.prefix(1))) == "Alpha 2.0", "plain body changed")
        // Unchanged next check: silent. A new App Store version: notified.
        rig.clock.advance(UpdateCheckScheduler.interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "repeat notification for an unchanged App Store update")
        rig.world[store.path] = storeOutcome(store, version: "11.3")
        rig.clock.advance(UpdateCheckScheduler.interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 2 && rig.notifier.posted[1].last?.version == "11.3", "new App Store version not notified")
        // An App Store update alone is enough to notify.
        let only = Rig([storeOutcome(storeApp("Solo"))])
        only.scheduler.start(); await only.settle()
        try expect(only.notifier.posted.count == 1 && only.controller.availableUpdateCount == 1, "store-only did not notify")
        try rig.noInstallerActivity()
        try only.noInstallerActivity()
    }

    check("scheduler source never knows the URL opener, and only the click paths use it") {
        let root = sourcesRoot()
        let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String]) ?? []
        var users: [String] = []
        for relative in files where relative.hasSuffix(".swift") {
            let text = try String(contentsOfFile: root + "/" + relative, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if relative == "PatchedClient/BackgroundUpdateChecks.swift" {
                try expect(!code.contains("urlOpener") && !code.contains("openAppStoreUpdates") && !code.contains("ExternalURLOpening")
                           && !code.contains("openInAppStore"), "\(relative) can open URLs")
            }
            if code.contains("openAppStoreUpdates()") || code.contains("openInAppStore(") { users.append(relative) }
        }
        try expect(users.sorted() == ["PatchedClient/AppUpdatesController.swift", "PatchedClient/AppUpdatesView.swift", "PatchedClient/AppsListView.swift", "PatchedClient/ExternalLinks.swift"],
                   "App Store openers: \(users.sorted())")
    }

    check("no-source labels, in the rows") {
        func noSource(_ name: String, _ reason: NoSourceReason, id: String? = nil) -> AppCheckOutcome {
            AppCheckOutcome(app: app(name, id: id), teamID: nil, source: nil, lowConfidence: false, installable: false, result: .noSource, noSourceReason: reason)
        }
        let cask = UpdateSource.homebrewCask(token: "low")
        let controller = makeController(outcomes: [
            noSource("Feedless", .noPublicFeed), noSource("Unlisted", .appStoreNotListed), noSource("Skipped", .ignored),
            noSource("Patched", .thisApp, id: NoSourceReason.patchedBundleID),
            outcome(app("Brew"), .updateAvailable(offer("3.0", source: cask)), source: cask, low: true),
            outcome(app("Mystery"), .noSource, noSource: true)])
        await runCheck(controller)
        @MainActor func text(_ name: String) throws -> String { try controller.rows.first { $0.name == name }.unwrap().statusText }
        try expect(try text("Feedless") == "No public update feed", "feedless: \(try text("Feedless"))")
        try expect(try text("Unlisted") == "Updates through the App Store", "unlisted")
        try expect(try text("Skipped") == "Hidden", "ignored")
        try expect(try text("Patched") == "This app", "this app")
        try expect(try text("Brew") == "Homebrew (unconfirmed) — add a catalogue entry to enable updates", "brew: \(try text("Brew"))")
        try expect(try text("Mystery") == "No public update feed", "default reason")
    }

    check("help & support: honest panel with the coffee, problem-report and source links") {
        let opener = RecordingOpener()
        let session = NativeClientSession(navigation: ShellNavigation(destination: .support),
                                           urlOpener: opener)
        let content = session.supportContent
        try expect(PublicLinks.repository?.absoluteString == "https://github.com/birdseeed/patched", "repository link: \(String(describing: PublicLinks.repository))")
        try expect(content.links.map(\.title) == ["Buy me a coffee", "Report a problem", "Source code"], "links: \(content.links.map(\.title))")
        try expect(content.links[0].url.absoluteString == "https://buymeacoffee.com/andybridson" && content.links[0].detail.contains("Apple Developer ID"), "coffee link")
        try expect(content.links[1].url.absoluteString == "https://github.com/birdseeed/patched/issues", "issues link: \(content.links[1].url)")
        try expect(content.links[2].url.absoluteString == "https://github.com/birdseeed/patched", "source link: \(content.links[2].url)")
        try expect(content.about.contains("free, open source community project") && content.about.contains("no company"), "about: \(content.about)")
        try expect(opener.nothingOpened, "building the panel opened something")
        try expect(session.openSupportLink(content.links[0]) && opener.urls == [PublicLinks.coffee], "click: \(opener.urls)")
        // Without a repository the two links are left out.
        let without = SupportContent.make(repository: nil)
        try expect(without.links.map(\.title) == ["Buy me a coffee"], "without repository: \(without.links.map(\.title))")
        let later = SupportContent.make(repository: URL(string: "https://example.org/patched")!)
        try expect(later.links.map(\.title) == ["Buy me a coffee", "Report a problem", "Source code"], "with repository: \(later.links.map(\.title))")
        let png = try paintView(NativeClientRootView(session: session), width: 900, height: 640)
        try expect(png.count > 3_000, "support panel looks blank")
        if let dir = ProcessInfo.processInfo.environment["PATCHED_SELFCHECK_PNG_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir + "/selfcheck-support.png"))
        }
        // The session shows the panel (not the old preview text) for the Help & Support destination.
        let root = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/NativeClientSession.swift", encoding: .utf8)
        try expect(root.contains("supportPanel") && !root.contains("Support submission is unavailable"), "root does not show the panel")
    }

    check("offscreen: an Updates list with an App Store row and a no-feed row paints in light and dark") {
        let installer = FakeInstaller()
        let controller = makeController(outcomes: [outcome(app("Alpha"), .upToDate), storeOutcome(storeApp("Windows App"), version: "11.2"),
            outcome(app("Feedless"), .noSource, noSource: true), outcome(app("Plain"), .updateAvailable(offer("2.0")))], installer: installer)
        controller.urlOpener = RecordingOpener()
        await runCheck(controller)
        let empty = makeController(outcomes: [], installer: FakeInstaller())
        let light = try paint(controller, dark: false), dark = try paint(controller, dark: true)
        try expect(light.count > 5_000 && dark.count > 5_000 && light != dark, "renders look blank or identical")
        try expect(light != (try paint(empty, dark: false)), "rows did not change the pixels")
        if let dir = ProcessInfo.processInfo.environment["PATCHED_APP_UPDATES_PNG_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try light.write(to: URL(fileURLWithPath: dir + "/updates-appstore-light.png")); try dark.write(to: URL(fileURLWithPath: dir + "/updates-appstore-dark.png"))
        }
        try expect(!installer.recorder.events.contains { $0.hasPrefix("update") }, "painting installed")
    }

    check("icons: a row with no inventory icon asks the provider for exactly its installed path") {
        let fake = FakeIconProvider()
        let controller = makeController(outcomes: [outcome(app("Bravo"), .updateAvailable(offer("2.0")))])
        controller.iconProvider = fake
        await runCheck(controller)
        try expect(controller.rows.count == 1 && controller.rows[0].icon == nil, "fixture row should have no inventory icon")
        let png = try paintView(AppUpdatesView(controller: controller), width: 720, height: 300)
        try expect(png.count > 3_000, "render looks blank")
        try expect(Set(fake.requested) == ["/Fake/Bravo.app"], "provider asked for: \(fake.requested)")
        // The provider's picture is what is drawn: a different icon changes the pixels.
        let other = FakeIconProvider(red: false)
        controller.iconProvider = other
        let again = try paintView(AppUpdatesView(controller: controller), width: 720, height: 300)
        try expect(again != png, "icon pixels did not come from the provider")
    }

    check("icons: the menu rows ask the provider for each row's installed path") {
        let fake = FakeIconProvider()
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))),
                                                   outcome(app("Bravo"), .updateAvailable(offer("2.0")))])
        controller.iconProvider = fake
        await runCheck(controller)
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates),
                                           appUpdates: controller, urlOpener: RecordingOpener())
        _ = try paintView(NativeClientMenuView(session: session, openWindow: {}), width: 320, height: 420)
        try expect(Set(fake.requested) == ["/Fake/Alpha.app", "/Fake/Bravo.app"], "provider asked for: \(fake.requested)")
    }

    check("icons: the workspace provider loads only real .app folders, off the render path, and caches") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("patched-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Real.app"), link = root.appendingPathComponent("Link.app")
        let plain = root.appendingPathComponent("NotAnApp")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        try expect(WorkspaceAppIconProvider.bundleStamp(app.path) != nil, "real .app refused")
        for bad in [link.path, plain.path, "Relative.app", root.appendingPathComponent("Missing.app").path] {
            try expect(WorkspaceAppIconProvider.bundleStamp(bad) == nil, "accepted \(bad)")
        }
        let provider = WorkspaceAppIconProvider(countLimit: 4)
        try expect(provider.cachedIcon(forPath: app.path) == nil, "cache answered before any load")
        let loaded = await provider.loadIcon(forPath: app.path)
        try expect(loaded != nil && provider.cachedIcon(forPath: app.path) === loaded, "load did not fill the cache")
        // Updated in place: a new modification date makes the next load re-read, not reuse, the icon.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: app.path)
        let reloaded = await provider.loadIcon(forPath: app.path)
        try expect(reloaded != nil && reloaded !== loaded && provider.cachedIcon(forPath: app.path) === reloaded, "stale icon reused after an update")
        // Both views tie the icon lookup to the installed version, so an in-place update reruns it.
        let updatesSource = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/PatchedAppUpdatesChecks/AppStoreChecks.swift", with: "Sources/PatchedClient/AppUpdatesView.swift"), encoding: .utf8)
        let menuSource = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/PatchedAppUpdatesChecks/AppStoreChecks.swift", with: "Sources/PatchedClient/NativeClientMenu.swift"), encoding: .utf8)
        try expect(updatesSource.contains("revision: row.installedVersion") && menuSource.contains("iconProvider.cachedIcon(forPath: path)"),
                   "icon lookup not tied to the installed version (the menu reads the cache each time it is built)")
        let symlinked = await provider.loadIcon(forPath: link.path)
        try expect(symlinked == nil && provider.cachedIcon(forPath: link.path) == nil, "symlinked app produced an icon")
    }
    check("screenshots: menu, Updates and Help & Support render; written when PATCHED_APP_UPDATES_PNG_DIR is set") {
        let down = RefusalReason.network("offline")
        func sized(_ name: String, _ short: String, _ build: String) -> InstalledApp {
            InstalledApp(name: name, path: "/Fake/\(name).app", bundleID: "com.example.\(name.filter(\.isLetter).lowercased())",
                         shortVersion: short, build: build)
        }
        let apps = [sized("Google Chrome", "156.0.8078.81", "8078.81"), sized("DisplayLink Manager Graphics Connectivity", "1.12.4", "1.12.4"),
                    sized("Keynote", "14.2", "7029"), sized("Admin Tool", "2.0", "2.0"), sized("Unsure", "3.1", "3.1")]
        let outcomes = [outcome(apps[0], .updateAvailable(offer("157.0.8120.40", build: "8120.40"))),
                        outcome(apps[1], .updateAvailable(offer("1.13.0"))),
                        outcome(apps[2], .updateAvailable(offer("14.3", build: "7100"))),
                        outcome(apps[3], .updateAvailable(offer("2.1")), installable: false),
                        outcome(apps[4], .updateAvailable(offer("3.2")), low: true),
                        storeOutcome(storeApp("Windows App"), version: "11.2"),
                        outcome(app("Broken"), .refused(down))]
        let controller = makeController(outcomes: outcomes)
        controller.urlOpener = RecordingOpener()
        controller.iconProvider = FakeIconProvider()
        await runCheck(controller)
        let session = NativeClientSession(navigation: ShellNavigation(destination: .support),
                                           appUpdates: controller, urlOpener: RecordingOpener())
        let menuLight = try paintView(NativeClientMenuView(session: session, openWindow: {}), width: 320, height: 520)
        let menuDark = try paintView(NativeClientMenuView(session: session, openWindow: {}), width: 320, height: 520, dark: true)
        let updates = try paintView(AppUpdatesView(controller: controller), width: 820, height: 560)
        let support = try paintView(NativeClientRootView(session: session), width: 900, height: 640)
        try expect(menuLight != menuDark && menuLight.count > 5_000 && updates.count > 5_000 && support.count > 5_000, "renders look blank")
        if let dir = ProcessInfo.processInfo.environment["PATCHED_APP_UPDATES_PNG_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (name, data) in [("menu-light", menuLight), ("menu-dark", menuDark), ("updates", updates), ("support", support)] {
                try data.write(to: URL(fileURLWithPath: dir + "/tidy-\(name).png"))
            }
        }
    }
}

func sourcesRoot() -> String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources").path
}
extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw CheckFailure(description: "missing value") }
        return self
    }
}

/// Records every path it is asked for and paints a flat coloured tile; no real file is read.
@MainActor final class FakeIconProvider: AppIconProviding {
    private(set) var requested: [String] = []
    private let tile: NSImage
    init(red: Bool = true) {
        tile = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            (red ? NSColor.systemRed : NSColor.systemGreen).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            return true
        }
    }
    func cachedIcon(forPath path: String) -> NSImage? { requested.append(path); return tile }
    func loadIcon(forPath path: String) async -> NSImage? { tile }
}

@MainActor func paintView<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool = false) throws -> Data {
    let app = NSApplication.shared
    if app.activationPolicy() != .prohibited { _ = app.setActivationPolicy(.prohibited) }
    let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top)
        .background(dark ? Color.black : Color.white).environment(\.colorScheme, dark ? .dark : .light))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let deadline = Date().addingTimeInterval(0.3)
    while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure(description: "bitmap unavailable") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(description: "png unavailable") }
    return png
}
