import Foundation
import Darwin
import SwiftUI
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

// Open in App Store for App Store apps with no confirmed status, wrapped iPhone/iPad apps, and ignoring apps.
// Fakes and temporary folders only; nothing real is opened, looked up or written.

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    func note(_ path: String) { lock.lock(); _paths.append(path); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
}

private final class CountingFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [String] = []
    private let body: Data?
    init(body: Data? = nil) { self.body = body }
    var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
    func reset() { lock.withLock { _urls = [] } }
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        lock.withLock { _urls.append(url.absoluteString) }
        if url.absoluteString.hasPrefix(AppStoreResolver.lookupBase), let body { return body }
        throw FetchError.transport("test")
    }
}
private struct NoIndex: CaskIndexProviding { func index() async -> Result<CaskIndex, RefusalReason> { .failure(.network("test")) } }

private func unconfirmed(_ name: String, track: Int? = nil) -> AppCheckOutcome {
    AppCheckOutcome(app: storeApp(name), teamID: nil, source: nil, lowConfidence: false, installable: false, result: .noSource,
                    noSourceReason: .appStoreNotListed, appStoreTrackID: track)
}
private func ignoredOutcome(_ app: InstalledApp) -> AppCheckOutcome {
    AppCheckOutcome(app: app, teamID: nil, source: nil, lowConfidence: false, installable: false, result: .noSource, noSourceReason: .ignored)
}
private func writePlist(_ dict: [String: Any], to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
}
private func tempRoot() throws -> String {
    let tmp = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
    let root = tmp + "/patched-nosource-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}
private func mode(_ path: String) -> Int {
    var info = stat()
    return lstat(path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
}

@MainActor func registerNoSourceActionChecks() {
    let updatesPage = AppStoreLinks.updatesPageURL

    check("no-source App Store rows: Open in App Store chooses the listing, then Spotlight's ID, then the Updates page") {
        let calls = Calls()
        let opener = RecordingOpener()
        let controller = makeController(outcomes: [unconfirmed("WhatsApp", track: 310633997), unconfirmed("Pages"), unconfirmed("Numbers"), unconfirmed("Keynote"),
                                                   outcome(app("Plain"), .upToDate)])
        controller.urlOpener = opener
        controller.appStoreAdamID = { path in
            calls.note(path)
            switch path { case "/Fake/Pages.app": return 409201541; case "/Fake/Keynote.app": return -5; default: return nil }
        }
        await runCheck(controller)
        try expect(controller.rows.filter(\.canOpenInAppStore).map(\.name) == ["Keynote", "Numbers", "Pages", "WhatsApp"], "rows offering it: \(controller.rows.filter(\.canOpenInAppStore).map(\.name))")
        try expect(opener.nothingOpened && calls.paths.isEmpty, "checking opened or asked Spotlight: \(opener.urls) \(calls.paths)")
        // 1. The lookup's listing wins and Spotlight is not asked.
        controller.openInAppStore(id: "/Fake/WhatsApp.app"); await controller.waitUntilIdle()
        try expect(opener.urls.map(\.absoluteString) == ["macappstore://apps.apple.com/app/id310633997"] && calls.paths.isEmpty, "listing: \(opener.urls) \(calls.paths)")
        // 2. Spotlight's positive ID.
        controller.openInAppStore(id: "/Fake/Pages.app"); await controller.waitUntilIdle()
        try expect(opener.urls.last?.absoluteString == "macappstore://apps.apple.com/app/id409201541" && opener.urls.count == 2, "spotlight: \(opener.urls)")
        // 3. Nothing known (or a non-positive ID): the Updates page.
        controller.openInAppStore(id: "/Fake/Numbers.app"); await controller.waitUntilIdle()
        try expect(opener.urls.count == 3 && opener.urls[2] == updatesPage, "no id: \(opener.urls)")
        controller.openInAppStore(id: "/Fake/Keynote.app"); await controller.waitUntilIdle()
        try expect(opener.urls.count == 4 && opener.urls[3] == updatesPage, "negative id: \(opener.urls)")
        // A row that is not an App Store row opens nothing.
        controller.openInAppStore(id: "/Fake/Plain.app"); await controller.waitUntilIdle()
        try expect(opener.urls.count == 4 && opener.apps.isEmpty, "opened for a plain row: \(opener.urls)")
    }

    check("no-source App Store rows: nothing opens without a click (Update All, notifications and the scheduler never do)") {
        let installer = FakeInstaller(), opener = RecordingOpener()
        let controller = makeController(outcomes: [unconfirmed("WhatsApp", track: 310633997), unconfirmed("Pages")], installer: installer)
        controller.urlOpener = opener
        controller.appStoreAdamID = { _ in 409201541 }
        await runCheck(controller)
        try expect(!controller.canUpdateAll && controller.availableUpdateCount == 0, "unconfirmed rows count as updates")
        try expect(!controller.updateAll(), "Update All ran for unconfirmed rows")
        await controller.waitUntilIdle()
        try expect(opener.nothingOpened && installer.recorder.events.filter { $0.hasPrefix("update") }.isEmpty, "something happened: \(opener.urls) \(installer.recorder.events)")
        let view = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/AppUpdatesView.swift", encoding: .utf8)
        try expect(view.contains("row.isAppStoreUpdate || row.isAppStoreUnconfirmed") && view.contains("controller.openInAppStore(id: row.id)"), "Updates view lacks the button")
        let list = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/AppsListView.swift", encoding: .utf8)
        try expect(list.contains("Button(\"Open in App Store\")") && list.contains("Button(\"Hide\")") && list.contains("Button(\"Unhide\")"), "Applications menu lacks actions")
    }

    check("Spotlight's App Store ID is used only when it is a positive whole number") {
        for (value, want) in [(NSNumber(value: 409201541), 409201541 as Int?), (NSNumber(value: 0), nil), (NSNumber(value: -3), nil),
                              (NSNumber(value: 1.5), nil), (NSNumber(value: true), nil)] {
            try expect(SpotlightAppStoreID.positiveInteger(value) == want, "\(value) -> \(String(describing: SpotlightAppStoreID.positiveInteger(value)))")
        }
        try expect(SpotlightAppStoreID.positiveInteger("409201541") == nil && SpotlightAppStoreID.positiveInteger(nil) == nil, "text or nil accepted")
        // The real attribute read refuses under the tripwire, so no test reads Spotlight.
        try expect(SpotlightAppStoreID.adamID(forPath: "/System/Applications/Mail.app") == nil, "read Spotlight under the tripwire")
    }

    check("a wrapped iPhone/iPad app is found on disk, is an App Store update from the iOS listing, and is never installed") {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let wrapper = root + "/Apps/WiFiman.app/Wrapper"
        try writePlist(["CFBundleIdentifier": "com.ubnt.wifiman", "CFBundleName": "WiFiman", "CFBundleShortVersionString": "1.37.1", "CFBundleVersion": "202605136"],
                       to: wrapper + "/WiFiman.app/Info.plist")
        try writePlist(["itemId": 1385561119, "softwareVersionBundleId": "com.ubnt.wifiman", "bundleShortVersionString": "1.37.1", "kind": "software"],
                       to: wrapper + "/iTunesMetadata.plist")
        let item = #"{"kind":"software","bundleId":"com.ubnt.wifiman","trackId":1385561119,"version":"1.38.0","trackViewUrl":"https://apps.apple.com/gb/app/wifiman/id1385561119"}"#
        let fetcher = CountingFetcher(body: Data(#"{"resultCount":1,"results":[\#(item)]}"#.utf8))
        let installer = UpdateInstaller(locations: .under(root + "/state"))
        let controller = AppUpdatesController(applicationsRoot: root + "/Apps", fetcher: fetcher, caskIndex: NoIndex(), installer: installer)
        let opener = RecordingOpener(); controller.urlOpener = opener
        await runCheck(controller)
        let row = try controller.rows.first.unwrap()
        try expect(controller.rows.count == 1 && row.bundleID == "com.ubnt.wifiman" && row.installedVersion == "1.37.1 (202605136)", "row: \(row)")
        try expect(row.status == .appStoreUpdate && row.latestVersion == "1.38.0" && row.sourceBadge == "App Store", "status: \(row.status) \(row.statusText)")
        try expect(!controller.canUpdate(row), "update was possible")
        controller.openInAppStore(id: row.id)
        try expect(opener.urls.map(\.absoluteString) == ["macappstore://apps.apple.com/app/id1385561119"], "opened \(opener.urls)")
        // The installer itself refuses it, whatever the caller says.
        let wrapped = InstalledApp(name: "WiFiman", path: row.path, bundleID: "com.ubnt.wifiman", shortVersion: "1.37.1", build: "202605136", isWrappedIOSApp: true)
        let o = offer("1.38.0", format: .zip)
        let forced = AppCheckOutcome(app: wrapped, teamID: nil, source: o.source, lowConfidence: false, installable: true, result: .updateAvailable(o))
        do { _ = try await installer.update(forced, quitIfRunning: false); throw CheckFailure(description: "installer accepted") }
        catch let refusal as InstallRefusal { try expect(refusal.code == "app_store_managed", "refusal: \(refusal)") }
        try expect(installer.allBackups().isEmpty && installer.unfinishedTransactionCount() == 0, "installer state changed")
    }

    check("ignore: the row leaves Updates, shows as Ignored in Applications, and drops out of Update All and notifications") {
        let a = app("Alpha"), helper = app("Helper"), plain = InstalledApp(name: "NoID", path: "/Fake/NoID.app", bundleID: nil, shortVersion: "1", build: "1")
        let world = World([outcome(a, .updateAvailable(offer("2.0"))), outcome(helper, .updateAvailable(offer("2.0"))), outcome(plain, .upToDate)])
        let edits = Calls()
        let installer = FakeInstaller()
        let controller = makeController(outcomes: [outcome(a, .upToDate), outcome(helper, .upToDate), outcome(plain, .upToDate)], installer: installer, world: world,
                                        editCatalogue: { id, ignored in
            edits.note("\(ignored ? "ignore" : "unignore") \(id)")
            if ignored { world["/Fake/Helper.app"] = ignoredOutcome(helper) } else { world["/Fake/Helper.app"] = outcome(helper, .updateAvailable(offer("2.0"))) }
        })
        await runCheck(controller)
        @MainActor func row(_ n: String) throws -> AppUpdateRow { try controller.rows.first { $0.name == n }.unwrap() }
        try expect(controller.canIgnore(try row("Helper")) && !controller.canIgnore(try row("NoID")), "bundle ID rule")
        try expect(!controller.canStopIgnoring(try row("Helper")), "stop ignoring offered for a normal row")
        try expect(controller.updateAllCount == 2 && controller.availableUpdateCount == 2, "before: \(controller.updateAllCount)")
        controller.ignore(id: "/Fake/NoID.app"); await controller.waitUntilIdle()
        try expect(edits.paths.isEmpty, "ignored an app without a bundle ID")
        controller.ignore(id: "/Fake/Helper.app"); await controller.waitUntilIdle()
        try expect(edits.paths == ["ignore com.example.helper"], "edits: \(edits.paths)")
        let ignored = try row("Helper")
        try expect(ignored.isIgnored && ignored.statusText == "Hidden" && ignored.listStatus == "Hidden", "row: \(ignored.statusText)")
        try expect(!controller.updatesRows.contains { $0.name == "Helper" } && controller.updatesRows.count == 2, "still listed in Updates")
        try expect(!AppsListModel.visibleRows(controller.rows, query: "", filter: .all).contains { $0.name == "Helper" }
                   && AppsListModel.visibleRows(controller.rows, query: "", filter: .hidden).map(\.name) == ["Helper"], "hidden app in wrong Applications segment")
        try expect(controller.updateAllCount == 1 && controller.availableUpdateCount == 1, "Update All or notifications still include it")
        try expect(controller.canStopIgnoring(ignored) && !controller.canIgnore(ignored), "stop ignoring not offered")
        await runOperation(controller) { controller.updateAll() }
        try expect(installer.recorder.events.filter { $0.hasPrefix("update") } == ["update Alpha quit=false"], "Update All touched the ignored app: \(installer.recorder.events)")
        try expect(controller.summary.hasPrefix("2 updated") || controller.summary.contains("updated"), "summary: \(controller.summary)")
        controller.stopIgnoring(id: "/Fake/Helper.app"); await controller.waitUntilIdle()
        try expect(edits.paths == ["ignore com.example.helper", "unignore com.example.helper"] && !(try row("Helper")).isIgnored, "stop ignoring: \(edits.paths)")
        // While a check is running nothing can be ignored.
        controller.check()
        try expect(!controller.canIgnore(try row("Alpha")), "ignored mid-check")
        await controller.waitUntilIdle()
    }

    check("ignore: every installed copy sharing the bundle ID is rechecked, and Update All's App Store branch skips ignored bundle IDs") {
        let one = InstalledApp(name: "Dup", path: "/Fake/Dup1.app", bundleID: "com.example.dup", shortVersion: "1.0", build: "1.0")
        let two = InstalledApp(name: "Dup", path: "/Fake/Dup2.app", bundleID: "com.example.dup", shortVersion: "1.0", build: "1.0")
        let world = World([outcome(one, .updateAvailable(offer("2.0"))), outcome(two, .updateAvailable(offer("2.0")))])
        let controller = makeController(outcomes: [outcome(one, .upToDate), outcome(two, .upToDate)], world: world, editCatalogue: { _, ignored in
            for a in [one, two] { world[a.path] = ignored ? ignoredOutcome(a) : outcome(a, .updateAvailable(offer("2.0"))) }
        })
        await runCheck(controller)
        try expect(controller.updateAllCount == 2, "fixture")
        controller.ignore(id: "/Fake/Dup1.app"); await controller.waitUntilIdle()
        try expect(controller.rows.allSatisfy(\.isIgnored) && controller.updatesRows.isEmpty && controller.updateAllCount == 0, "a copy was left behind: \(controller.rows.map(\.statusText))")
        controller.stopIgnoring(id: "/Fake/Dup2.app"); await controller.waitUntilIdle()
        try expect(controller.rows.allSatisfy { !$0.isIgnored } && controller.updateAllCount == 2, "copies not restored")
        // A stale App Store row of an ignored bundle ID is not opened by Update All.
        let storeCopy = storeApp("Store"), twin = InstalledApp(name: "Store", path: "/Fake/Store2.app", bundleID: storeCopy.bundleID, shortVersion: "1.0", build: "1.0", isAppStore: true)
        let w2 = World([storeOutcome(storeCopy), storeOutcome(twin)])
        let opener = RecordingOpener()
        let c2 = makeController(outcomes: [storeOutcome(storeCopy), storeOutcome(twin)], world: w2, editCatalogue: { _, _ in w2[storeCopy.path] = ignoredOutcome(storeCopy) })
        c2.urlOpener = opener
        await runCheck(c2)
        try expect(c2.appStoreRows.count == 2 && c2.canUpdateAll, "fixture: two App Store rows")
        c2.ignore(id: storeCopy.path); await c2.waitUntilIdle()
        // The twin is refreshed too, but the world still calls it an App Store update: the ignored ID wins.
        try expect(c2.appStoreRows.isEmpty && !c2.canUpdateAll && !c2.updateAll() && opener.nothingOpened, "Update All reached an ignored bundle ID: \(opener.urls)")
    }

    check("ignore: an edit that commits and then fails to sync still refreshes every copy, and shows the warning") {
        let one = storeApp("Synced"), two = InstalledApp(name: "Synced", path: "/Fake/Synced2.app", bundleID: one.bundleID, shortVersion: "1.0", build: "1.0", isAppStore: true)
        let world = World([storeOutcome(one), storeOutcome(two)])
        let opener = RecordingOpener()
        let controller = makeController(outcomes: [storeOutcome(one), storeOutcome(two)], world: world, editCatalogue: { _, _ in
            for a in [one, two] { world[a.path] = ignoredOutcome(a) }
            throw CatalogueError(message: "the change was saved but may not survive a power cut")
        })
        controller.urlOpener = opener
        await runCheck(controller)
        controller.ignore(id: one.path); await controller.waitUntilIdle()
        try expect(controller.rows.allSatisfy(\.isIgnored) && controller.appStoreRows.isEmpty && !controller.updateAll() && opener.nothingOpened,
                   "committed edit not reflected: \(controller.rows.map(\.statusText))")
        let row = try controller.row(id: one.path).unwrap()
        try expect(row.result?.kind == .failure && row.result?.text.contains("may not survive a power cut") == true, "warning lost: \(String(describing: row.result))")
        // The row is hidden from Updates now, so the warning is shown on both screens, not only on the row.
        try expect(controller.ignoreEditFailure?.contains("may not survive a power cut") == true, "warning not surfaced")
        for source in ["AppUpdatesView.swift", "AppsListView.swift"] {
            let text = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/PatchedAppUpdatesChecks/NoSourceActionChecks.swift", with: "Sources/PatchedClient/" + source), encoding: .utf8)
            try expect(text.contains("IgnoreEditFailureBanner(message: failure)"), "\(source) does not show the edit failure")
        }
        controller.dismissIgnoreEditFailure()
        try expect(controller.ignoreEditFailure == nil, "dismiss")
    }

    check("ignore: a failing edit leaves the row as it was and shows the error") {
        let a = app("Alpha")
        let controller = makeController(outcomes: [outcome(a, .upToDate)], editCatalogue: { _, _ in throw CatalogueError(message: "/x/catalogue.json: not a JSON object, so it was not changed") })
        await runCheck(controller)
        controller.ignore(id: a.path); await controller.waitUntilIdle()
        let row = try controller.rows.first.unwrap()
        try expect(!row.isIgnored && row.status == .upToDate, "row changed")
        try expect(row.result?.kind == .failure && row.result?.text == "Couldn't hide Alpha. /x/catalogue.json: not a JSON object, so it was not changed", "error: \(String(describing: row.result))")
        try expect(!controller.isWorking, "still working")
    }

    check("ignore through the real wiring: one 0600 entry, others kept, no lookup for the ignored app, Stop ignoring removes only it, a broken file is refused") {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        for (folder, id, receipt) in [("Simple Dialler", "com.example.dialler", true), ("Claude Code URL Handler", "com.anthropic.claudecode.urlhandler", true), ("Other", "com.example.other", true)] {
            try writePlist(["CFBundleIdentifier": id, "CFBundleName": folder, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"],
                           to: root + "/Apps/\(folder).app/Contents/Info.plist")
            if receipt { try fm.createDirectory(atPath: root + "/Apps/\(folder).app/Contents/_MASReceipt", withIntermediateDirectories: true) }
        }
        let catalogue = root + "/catalogue.json"
        let seed = #"{"version":1,"apps":[{"bundleID":"com.keep.cask","source":{"homebrewCask":"example"}},{"bundleID":"com.keep.ignored","ignore":true}]}"#
        try Data(seed.utf8).write(to: URL(fileURLWithPath: catalogue))
        let before = try UserCatalogue.load(from: URL(fileURLWithPath: catalogue))
        let fetcher = CountingFetcher()
        let controller = AppUpdatesController.live(catalogueURL: URL(fileURLWithPath: catalogue), applicationsRoot: root + "/Apps", fetcher: fetcher,
                                                   caskIndex: NoIndex(), installerLocations: .under(root + "/state"))
        await runCheck(controller)
        let dialler = "/Apps/Simple Dialler.app"
        let id = try controller.rows.first { $0.path.hasSuffix(dialler) }.unwrap().id
        try expect(fetcher.urls.contains { $0.contains("com.example.dialler") }, "fixture: the App Store was not asked before ignoring: \(fetcher.urls)")
        controller.ignore(id: id); await controller.waitUntilIdle()
        var expected = before.entries; expected["com.example.dialler"] = .ignore
        try expect(try UserCatalogue.load(from: URL(fileURLWithPath: catalogue)).entries == expected, "catalogue entries after ignoring")
        try expect(mode(catalogue) == 0o600, "mode \(String(mode(catalogue), radix: 8))")
        try expect(try controller.row(id: id).unwrap().isIgnored, "row not ignored: \(String(describing: controller.row(id: id)?.statusText))")
        // A fresh check: the ignored app is listed as Ignored and nothing about it is sent anywhere.
        fetcher.reset()
        await runCheck(controller)
        try expect(!fetcher.urls.isEmpty && !fetcher.urls.contains { $0.contains("com.example.dialler") }, "requests: \(fetcher.urls)")
        try expect(controller.updatesRows.count == 2 && controller.rows.count == 3, "rows \(controller.rows.count) updates rows \(controller.updatesRows.count)")
        // Stop ignoring removes only that entry.
        controller.stopIgnoring(id: id); await controller.waitUntilIdle()
        try expect(try UserCatalogue.load(from: URL(fileURLWithPath: catalogue)).entries == before.entries, "stop ignoring changed other entries")
        try expect(try !controller.row(id: id).unwrap().isIgnored, "still ignored")
        // The file breaks behind the app's back: the edit is refused, the file is untouched, and the error shows.
        let broken = "{ definitely not json"
        try Data(broken.utf8).write(to: URL(fileURLWithPath: catalogue))
        controller.ignore(id: id); await controller.waitUntilIdle()
        try expect(String(decoding: try Data(contentsOf: URL(fileURLWithPath: catalogue)), as: UTF8.self) == broken, "a broken catalogue was overwritten")
        let shown = try controller.row(id: id).unwrap()
        try expect(shown.result?.kind == .failure && shown.result?.text.contains("so it was not changed") == true && !shown.isIgnored, "error: \(String(describing: shown.result))")
        try expect(try fm.contentsOfDirectory(atPath: root).filter { $0.hasSuffix(".tmp") || $0.hasPrefix(".catalogue-") }.isEmpty, "temporary files left")
        await controller.refreshInstallerState()
        try expect(controller.catalogueError != nil, "the broken catalogue is not reported")
    }

    check("offscreen: Updates rows with Open in App Store and Applications rows with Ignored paint, and ignored rows leave Updates") {
        let ignoredApp = app("Simple Dialler", id: "com.example.dialler")
        let controller = makeController(outcomes: [outcome(app("Alpha"), .upToDate), unconfirmed("WhatsApp", track: 310633997), unconfirmed("Pages"),
            storeOutcome(storeApp("Windows App"), version: "11.2"), ignoredOutcome(ignoredApp), ignoredOutcome(app("Claude Code URL Handler", id: "com.anthropic.claudecode.urlhandler")),
            outcome(app("Plain"), .updateAvailable(offer("2.0")))], editCatalogue: { _, _ in })
        controller.urlOpener = RecordingOpener()
        await runCheck(controller)
        let updates = try paintView(AppUpdatesView(controller: controller), width: 820, height: 480)
        let list = try paintView(AppsListView(controller: controller, revealer: FakeRevealer(), showUpdate: { _ in }), width: 820, height: 480)
        try expect(updates.count > 5_000 && list.count > 5_000 && updates != list, "renders look blank")
        if let dir = ProcessInfo.processInfo.environment["PATCHED_NOSOURCE_PNG_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try updates.write(to: URL(fileURLWithPath: dir + "/nosource-updates.png")); try list.write(to: URL(fileURLWithPath: dir + "/nosource-applications.png"))
            try paintView(AppUpdatesView(controller: controller), width: 820, height: 480, dark: true).write(to: URL(fileURLWithPath: dir + "/nosource-updates-dark.png"))
            try paintView(AppsListView(controller: controller, revealer: FakeRevealer(), showUpdate: { _ in }), width: 820, height: 480, dark: true)
                .write(to: URL(fileURLWithPath: dir + "/nosource-applications-dark.png"))
        }
        let text = try paintedText(AppUpdatesView(controller: controller))
        try expect(text.contains("Open in App Store") && !text.contains("Simple Dialler") && !text.contains("Claude Code URL Handler"), "Updates text: \(text)")
        let apps = try paintedText(AppsListView(controller: controller, revealer: FakeRevealer(), showUpdate: { _ in }))
        try expect(!apps.contains("Simple Dialler") && apps.contains("Hidden") && controller.rows.filter { $0.listStatus == "Hidden" }.map(\.name) == ["Claude Code URL Handler", "Simple Dialler"], "Applications text: \(apps)")
    }
}
