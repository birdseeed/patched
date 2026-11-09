import Foundation
import Darwin
import SwiftUI
import UserNotifications
import PatchedShell
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

// Notify-only check for new Patched releases. A fake lookup stands in for GitHub; nothing is requested,
// opened or installed for real.

private let patchedID = NoSourceReason.patchedBundleID
private let page020 = URL(string: "https://github.com/birdseeed/patched/releases/tag/v0.2.0")!
private func record(_ page: String) -> Data {
    Data(#"{"tag_name":"v0.2.0","html_url":"\#(page)","draft":false,"prerelease":false}"#.utf8)
}
private let page030 = URL(string: "https://github.com/birdseeed/patched/releases/tag/v0.3.0")!

private func patchedOutcome(_ version: String = "0.1.0") -> AppCheckOutcome {
    AppCheckOutcome(app: app("Patched", id: patchedID, version: version), teamID: nil, source: nil, lowConfidence: false,
                    installable: false, result: .noSource, noSourceReason: .thisApp)
}
private func newer(_ version: String, _ page: URL) -> PatchedReleaseResult { .newer(PatchedRelease(version: version, pageURL: page)) }
private func signedAssets(_ version: String) -> PatchedReleaseAssets {
    let zip = "https://github.com/birdseeed/patched/releases/download/v\(version)/Patched-\(version).zip"
    return PatchedReleaseAssets(zipURL: URL(string: zip)!, signatureURL: URL(string: zip + ".sig")!)
}
private func signed(_ version: String) -> PatchedReleaseResult {
    .newer(PatchedRelease(version: version, pageURL: URL(string: "https://github.com/birdseeed/patched/releases/tag/v\(version)")!,
                          assets: signedAssets(version)))
}

/// Stands in for `SelfUpdater`: records what it was asked to do and never touches a file.
private final class FakeSelfInstaller: SelfInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _installs: [PatchedRelease] = []
    private var _relaunches: [String] = []
    var failure: InstallRefusal?
    var relaunchFails = false
    var gate: Gate?
    var installs: [PatchedRelease] { lock.withLock { _installs } }
    var relaunches: [String] { lock.withLock { _relaunches } }
    func install(_ release: PatchedRelease, progress: @escaping @Sendable (SelfUpdateStep) -> Void) async throws -> SelfUpdateReport {
        lock.withLock { _installs.append(release) }
        progress(.verifying); progress(.installing)
        if let gate { await gate.wait() }
        if let failure { throw failure }
        return SelfUpdateReport(appPath: "/Applications/Patched.app", fromVersion: "0.1.0", toVersion: release.version, backupPath: nil, note: nil)
    }
    func relaunch(_ report: SelfUpdateReport) throws {
        lock.withLock { _relaunches.append(report.appPath) }
        if relaunchFails { throw InstallRefusal.io("open failed") }
    }
}
@MainActor private final class QuitCounter { var count = 0; func bump() { count += 1 } }

/// A fake lookup whose answer can change, counting its calls.
private final class FakeLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: PatchedReleaseResult
    private var _calls = 0
    init(_ result: PatchedReleaseResult) { _result = result }
    var result: PatchedReleaseResult { get { lock.withLock { _result } } set { lock.withLock { _result = newValue } } }
    var calls: Int { lock.withLock { _calls } }
    var check: SelfUpdateCheck { { [self] in lock.withLock { _calls += 1; return _result } } }
}

private final class URLLog: @unchecked Sendable {
    private let lock = NSLock(); private var _urls: [String] = []
    func note(_ url: URL) { lock.withLock { _urls.append(url.absoluteString) } }
    var urls: [String] { lock.withLock { _urls } }
}
private struct LoggingFetcher: HTTPFetching {
    let log: URLLog
    let release: Data?
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        log.note(url)
        if url.host == "api.github.com", let release { return release }
        throw FetchError.transport("test")
    }
}
private struct NoIndex: CaskIndexProviding { func index() async -> Result<CaskIndex, RefusalReason> { .failure(.network("test")) } }

@MainActor func registerSelfUpdateChecks() {
    func controller(_ lookup: FakeLookup?, others: [AppCheckOutcome] = [], installer: FakeInstaller = FakeInstaller()) -> AppUpdatesController {
        let controller = makeController(outcomes: [patchedOutcome()] + others, installer: installer)
        controller.selfUpdateCheck = lookup?.check
        controller.urlOpener = RecordingOpener()
        return controller
    }

    check("self update: newer, equal, older and no news decide whether the banner and row appear") {
        let cases: [(String, PatchedReleaseResult, String?)] = [
            ("newer", newer("0.2.0", page020), "0.2.0"), ("equal", .noNews, nil), ("older", .noNews, nil)]
        for (name, result, expected) in cases {
            let c = controller(FakeLookup(result))
            await runCheck(c)
            try expect(c.selfUpdate?.version == expected, "\(name): \(String(describing: c.selfUpdate))")
            let row = try c.rows.first { $0.bundleID == patchedID }.unwrap()
            try expect(row.statusText == (expected.map { "Update to " + $0 } ?? "This app"), "\(name) row: \(row.statusText)")
            try expect(row.listStatus == row.statusText, "\(name) list status: \(row.listStatus)")
        }
        let c = controller(FakeLookup(newer("0.2.0", page020)))
        await runCheck(c)
        try expect(c.selfUpdate?.text == "Patched 0.2.0 is available" && c.selfUpdate?.url == page020, "text/url: \(String(describing: c.selfUpdate))")
    }

    check("self update: no lookup configured, no news, or a failed lookup; a failure keeps what was known") {
        let none = controller(nil)
        await runCheck(none)
        try expect(none.selfUpdate == nil, "no lookup shows something")
        let lookup = FakeLookup(newer("0.2.0", page020))
        let c = controller(lookup)
        await runCheck(c)
        lookup.result = .unavailable
        await runCheck(c)
        try expect(c.selfUpdate?.version == "0.2.0", "a failed lookup cleared the news")
        lookup.result = .noNews
        await runCheck(c)
        try expect(c.selfUpdate == nil, "no news did not clear")
        try expect(c.rows.first { $0.bundleID == patchedID }?.statusText == "This app", "row after clearing")
    }

    check("self update: one lookup per check, started by the check and nothing else") {
        let lookup = FakeLookup(newer("0.2.0", page020))
        let c = controller(lookup)
        try expect(lookup.calls == 0, "construction looked")
        await runCheck(c)
        try expect(lookup.calls == 1, "first check: \(lookup.calls)")
        await runCheck(c)
        try expect(lookup.calls == 2, "second check: \(lookup.calls)")
        c.downloadSelfUpdate(); await c.refreshInstallerState()
        try expect(lookup.calls == 2, "download or refresh looked again: \(lookup.calls)")
    }

    check("self update: Download opens exactly the validated release page, and only on a click") {
        let opener = RecordingOpener()
        let lookup = FakeLookup(newer("0.2.0", page020))
        let c = controller(lookup)
        c.urlOpener = opener
        c.downloadSelfUpdate()
        try expect(opener.nothingOpened, "downloaded with nothing announced")
        await runCheck(c)
        try expect(opener.nothingOpened, "the check opened something: \(opener.urls)")
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), appUpdates: c, urlOpener: opener)
        _ = try paintView(NativeClientMenuView(session: session, openWindow: {}), width: 320, height: 420)
        _ = try paintView(AppUpdatesView(controller: c), width: 720, height: 300)
        try expect(opener.nothingOpened, "painting opened something: \(opener.urls)")
        c.downloadSelfUpdate()
        try expect(opener.urls == [page020] && opener.apps.isEmpty && opener.appPaths.isEmpty, "click opened \(opener.urls)")
    }

    check("self update: a release page that fails validation shows nothing and Download opens nothing") {
        // The same bytes through the real parser: every unsafe page is dropped before the controller sees it.
        let opener = RecordingOpener()
        for page in ["https://evil.example/birdseeed/patched/releases/tag/v0.2.0", "https://github.com/birdseeed/patched/releases/tag/v0.9.9",
                     "https://github.com/birdseeed/patched/releases/download/v0.2.0/Patched.zip", "http://github.com/birdseeed/patched/releases/tag/v0.2.0"] {
            let c = controller(nil)
            c.urlOpener = opener
            c.selfUpdateCheck = { PatchedReleaseChecker.evaluate(record(page), currentVersion: "0.1.0") }
            await runCheck(c)
            c.downloadSelfUpdate()
            try expect(c.selfUpdate == nil, "\(page) was announced")
        }
        try expect(opener.nothingOpened, "opened \(opener.urls)")
        let good = controller(nil)
        good.urlOpener = opener
        good.selfUpdateCheck = { PatchedReleaseChecker.evaluate(record(page020.absoluteString), currentVersion: "0.1.0") }
        await runCheck(good); good.downloadSelfUpdate()
        try expect(opener.urls == [page020], "good page: \(opener.urls)")
    }

    check("self update: Update All, the badge and every install gate ignore Patched's own row") {
        let installer = FakeInstaller()
        let c = controller(FakeLookup(newer("0.2.0", page020)), installer: installer)
        await runCheck(c)
        let row = try c.rows.first { $0.bundleID == patchedID }.unwrap()
        try expect(!c.canUpdate(row) && !row.hasUpdate && !row.canOpenInAppStore && row.status == .noSource, "row is actionable: \(row.status)")
        try expect(c.updatableRows.isEmpty && c.updateAllCount == 0 && c.availableUpdateCount == 0 && !c.canUpdateAll,
                   "counted: \(c.updatableRows.count) \(c.updateAllCount) \(c.availableUpdateCount)")
        c.update(id: row.id); await c.waitUntilIdle()
        try expect(!c.updateAll(), "Update All accepted with only Patched's row")
        try expect(installer.recorder.events.allSatisfy { !$0.hasPrefix("update") && !$0.hasPrefix("admin") }, "installer used: \(installer.recorder.events)")
        // Next to a real update, Update All installs only that one.
        let installer2 = FakeInstaller()
        let c2 = controller(FakeLookup(newer("0.2.0", page020)), others: [outcome(app("Plain"), .updateAvailable(offer("2.0")))], installer: installer2)
        await runCheck(c2)
        try expect(c2.updateAllCount == 1 && c2.availableUpdateCount == 1, "counts: \(c2.updateAllCount) \(c2.availableUpdateCount)")
        _ = c2.updateAll(); await c2.waitUntilIdle()
        let updates = installer2.recorder.events.filter { $0.hasPrefix("update") }
        try expect(updates.count == 1 && updates[0].contains("Plain"), "Update All installed: \(updates)")
    }

    check("self update: the menu line, the Updates banner and the Applications row show the same words") {
        let c = controller(FakeLookup(newer("0.2.0", page020)), others: [outcome(app("Plain"), .updateAvailable(offer("2.0")))])
        await runCheck(c)
        try expect(c.menuUpdates().selfUpdateText == "Patched 0.2.0 is available", "menu: \(String(describing: c.menuUpdates().selfUpdateText))")
        let none = controller(FakeLookup(.noNews))
        await runCheck(none)
        try expect(none.menuUpdates().selfUpdateText == nil, "menu line without news")
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), appUpdates: c, urlOpener: RecordingOpener())
        let menu = try paintedText(NativeClientMenuView(session: session, openWindow: {}))
        try expect(menu.contains("Patched 0.2.0 is available") && menu.contains("Download"), "menu text: \(menu)")
        let updates = try paintedText(AppUpdatesView(controller: c))
        try expect(updates.contains("Patched 0.2.0 is available") && updates.contains("Download"), "updates text: \(updates)")
        let apps = try paintedText(AppsListView(controller: c, revealer: FakeRevealer(), showUpdate: { _ in }))
        try expect(apps.contains("Update to 0.2.0"), "applications text: \(apps)")
        let plain = try paintedText(AppUpdatesView(controller: none))
        try expect(!plain.contains("Download") && !plain.contains("is available"), "banner without news: \(plain)")
        if let dir = ProcessInfo.processInfo.environment["PATCHED_SELFCHECK_PNG_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (name, dark) in [("light", false), ("dark", true)] {
                try paintView(NativeClientMenuView(session: session, openWindow: {}), width: 320, height: 420, dark: dark)
                    .write(to: URL(fileURLWithPath: dir + "/selfcheck-menu-\(name).png"))
                try paintView(AppUpdatesView(controller: c), width: 820, height: 420, dark: dark)
                    .write(to: URL(fileURLWithPath: dir + "/selfcheck-updates-\(name).png"))
                try paintView(AppsListView(controller: c, revealer: FakeRevealer(), showUpdate: { _ in }), width: 820, height: 420, dark: dark)
                    .write(to: URL(fileURLWithPath: dir + "/selfcheck-applications-\(name).png"))
            }
        }
    }

    check("self update: scheduled checks notify once per new version, and never open anything") {
        let rig = Rig([patchedOutcome()])
        let lookup = FakeLookup(newer("0.2.0", page020))
        rig.controller.selfUpdateCheck = lookup.check
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.postedSelf.map(\.version) == ["0.2.0"], "launch: \(rig.notifier.postedSelf)")
        try expect(rig.notifier.posted.isEmpty, "app notification posted for Patched's own release")
        // Later scheduled checks do not repeat it.
        for _ in 0..<3 { rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle() }
        try expect(rig.notifier.postedSelf.count == 1 && lookup.calls == 4, "repeat: \(rig.notifier.postedSelf.count) posts, \(lookup.calls) lookups")
        // A newer version is a new announcement.
        lookup.result = newer("0.3.0", page030)
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.map(\.version) == ["0.2.0", "0.3.0"], "new version: \(rig.notifier.postedSelf.map(\.version))")
        // A flaky lookup neither clears nor repeats the announcement.
        lookup.result = .unavailable
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        lookup.result = newer("0.3.0", page030)
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.count == 2, "flaky: \(rig.notifier.postedSelf.map(\.version))")
        try rig.noInstallerActivity()
    }

    check("self update: a denied notification is retried until it is delivered") {
        let rig = Rig([patchedOutcome()])
        rig.notifier.delivers = false
        rig.controller.selfUpdateCheck = FakeLookup(newer("0.2.0", page020)).check
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.postedSelf.count == 1, "first attempt")
        rig.notifier.delivers = true
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.count == 2, "retry: \(rig.notifier.postedSelf.count)")
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.count == 2, "repeated after delivery")
    }

    check("self update: a user-started check is not notified, but the version is then known") {
        let rig = Rig([patchedOutcome()])
        let lookup = FakeLookup(.noNews)
        rig.controller.selfUpdateCheck = lookup.check
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.postedSelf.isEmpty, "no news notified")
        lookup.result = newer("0.2.0", page020)
        rig.controller.check(); await rig.settle()             // Check Now
        try expect(rig.controller.selfUpdate?.version == "0.2.0" && rig.notifier.postedSelf.isEmpty, "Check Now notified: \(rig.notifier.postedSelf)")
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.isEmpty, "announced a version the user already saw: \(rig.notifier.postedSelf)")
    }

    check("self update: a release that goes away and comes back is announced once; a newer one is announced again") {
        let rig = Rig([patchedOutcome()])
        let lookup = FakeLookup(newer("0.2.0", page020))
        rig.controller.selfUpdateCheck = lookup.check
        @MainActor func next() async throws { rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle() }
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.postedSelf.map(\.version) == ["0.2.0"], "launch: \(rig.notifier.postedSelf.map(\.version))")
        lookup.result = .noNews
        try await next()
        try expect(rig.controller.selfUpdate == nil, "no news did not clear the banner")
        lookup.result = newer("0.2.0", page020)
        try await next()
        try expect(rig.controller.selfUpdate?.version == "0.2.0" && rig.notifier.postedSelf.count == 1, "re-announced 0.2.0: \(rig.notifier.postedSelf.map(\.version))")
        lookup.result = newer("0.3.0", page030)
        try await next()
        try expect(rig.notifier.postedSelf.map(\.version) == ["0.2.0", "0.3.0"], "0.3.0: \(rig.notifier.postedSelf.map(\.version))")
        // An older release does not come back as news either.
        lookup.result = newer("0.2.0", page020)
        try await next()
        try expect(rig.notifier.postedSelf.count == 2, "older version announced: \(rig.notifier.postedSelf.map(\.version))")
        try rig.noInstallerActivity()
    }

    check("self update: 401, 403 and 429 keep the banner; only a 404 clears it") {
        final class Switch: @unchecked Sendable {
            private let lock = NSLock(); private var _error: FetchError?
            var error: FetchError? { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
        }
        struct Fetcher: HTTPFetching {
            let state: Switch
            func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
                if let error = state.error { throw error }
                return Data(#"{"tag_name":"v0.2.0","html_url":"https://github.com/birdseeed/patched/releases/tag/v0.2.0","draft":false,"prerelease":false}"#.utf8)
            }
        }
        let state = Switch()
        let rig = Rig([patchedOutcome()])
        rig.controller.selfUpdateCheck = { await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: Fetcher(state: state)) }
        rig.scheduler.start(); await rig.settle()
        try expect(rig.controller.selfUpdate?.version == "0.2.0", "found")
        for code in [401, 403, 429, 500] {
            state.error = .http(code)
            rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
            try expect(rig.controller.selfUpdate?.version == "0.2.0", "HTTP \(code) cleared the banner")
        }
        try expect(rig.notifier.postedSelf.count == 1, "re-announced after errors: \(rig.notifier.postedSelf.count)")
        state.error = .http(404)
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.controller.selfUpdate == nil, "404 did not clear")
    }

    check("self update: the app rows never wait for the lookup, and a lookup that never returns times out") {
        let c = controller(nil)
        c.selfLookupTimeout = 0.3
        c.selfUpdateCheck = { await withCheckedContinuation { (_: CheckedContinuation<PatchedReleaseResult, Never>) in } }
        c.check()
        var waited = 0
        while c.phase != .idle && waited < 200 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        try expect(c.phase == .idle && c.hasChecked && c.rows.count == 1, "phase \(c.phase), rows \(c.rows.count) while the lookup hangs")
        try expect(c.selfLookupPending, "the lookup should still be pending")
        await c.waitUntilIdle()
        try expect(!c.selfLookupPending && c.selfUpdate == nil, "timeout left it pending or invented news")
        // A timeout is `unavailable`: it keeps what was known.
        let lookup = FakeLookup(newer("0.2.0", page020))
        c.selfUpdateCheck = lookup.check
        await runCheck(c)
        c.selfUpdateCheck = { await withCheckedContinuation { (_: CheckedContinuation<PatchedReleaseResult, Never>) in } }
        await runCheck(c)
        try expect(c.selfUpdate?.version == "0.2.0", "a timeout cleared the banner")
    }

    check("self update: a delivery still waiting (first permission prompt) is not posted again") {
        let rig = Rig([patchedOutcome()])
        rig.notifier.holdSelf = true
        rig.controller.selfUpdateCheck = FakeLookup(newer("0.2.0", page020)).check
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.postedSelf.count == 1, "first post")
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.count == 1, "posted again while the first was still waiting: \(rig.notifier.postedSelf.count)")
        for completion in rig.notifier.heldSelf { completion(true) }
        rig.notifier.heldSelf = []; rig.notifier.holdSelf = false
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.count == 1, "repeated after delivery")
    }

    check("self update: an older release's late delivery never lowers the remembered version") {
        let rig = Rig([patchedOutcome()])
        rig.notifier.holdSelf = true
        let lookup = FakeLookup(newer("0.2.0", page020))
        rig.controller.selfUpdateCheck = lookup.check
        rig.scheduler.start(); await rig.settle()                       // 0.2.0 posted, delivery waiting
        lookup.result = newer("0.3.0", page030)
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.map(\.version) == ["0.2.0", "0.3.0"], "fixture: \(rig.notifier.postedSelf.map(\.version))")
        let held = rig.notifier.heldSelf; rig.notifier.heldSelf = []; rig.notifier.holdSelf = false
        held[1](true); held[0](true)                                    // 0.3.0 completes first, then 0.2.0 late
        rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.postedSelf.count == 2, "0.3.0 announced again: \(rig.notifier.postedSelf.map(\.version))")
    }

    check("self update: a lookup cancelled before it starts still finishes (no leaked continuation)") {
        final class Done: @unchecked Sendable {
            private let lock = NSLock(); private var value = false
            func set() { lock.withLock { value = true } }
            var isSet: Bool { lock.withLock { value } }
        }
        let gate = Gate(), done = Done()
        // Unstructured on purpose: if the race leaks, this task never finishes and the check must not wait on it.
        let task = Task<Void, Never> {
            await gate.wait()                              // cancelled while parked here, before the race begins
            _ = await AppUpdatesController.raced({ await withCheckedContinuation { (_: CheckedContinuation<PatchedReleaseResult, Never>) in } },
                                                 timeout: 60)
            done.set()
        }
        task.cancel(); gate.open()
        var waited = 0
        while !done.isSet && waited < 300 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        try expect(done.isSet, "the race never resumed after an early cancel")
    }

    check("self update: a late answer from an older check is ignored") {
        final class Order: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func next() -> Int { lock.withLock { n += 1; return n } }
        }
        let gate = Gate(), order = Order()
        let c = controller(nil)
        c.selfUpdateCheck = {
            if order.next() == 1 { await gate.wait(); return newer("0.2.0", page020) }
            return .noNews
        }
        c.check()
        var waited = 0
        while c.phase != .idle && waited < 200 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        c.check()                                    // a newer check; its lookup answers "no news" at once
        await c.waitUntilIdle()
        gate.open()                                  // the first lookup now answers, late
        try await Task.sleep(nanoseconds: 200_000_000)
        try expect(c.selfUpdate == nil, "a stale lookup overwrote the newer check: \(String(describing: c.selfUpdate))")
        try expect(c.rows.first { $0.bundleID == patchedID }?.statusText == "This app", "row shows the stale answer")
    }

    check("self update: its notification opens Updates; its one button only asks, and Update All never applies to it") {
        let id = SystemUpdateNotifier.selfUpdateIdentifier
        try expect(SystemUpdateNotifier.route(requestIdentifier: id, actionIdentifier: UNNotificationDefaultActionIdentifier) == .openUpdates, "body tap")
        try expect(SystemUpdateNotifier.route(requestIdentifier: id, actionIdentifier: SystemUpdateNotifier.updateAllActionIdentifier) == nil, "update all on it")
        try expect(SystemUpdateNotifier.route(requestIdentifier: id, actionIdentifier: SystemUpdateNotifier.selfUpdateActionIdentifier) == .selfUpdate, "update button")
        try expect(SystemUpdateNotifier.route(requestIdentifier: SystemUpdateNotifier.requestIdentifier,
                                              actionIdentifier: SystemUpdateNotifier.selfUpdateActionIdentifier) == nil, "self button on the apps notification")
        try expect(SystemUpdateNotifier.route(requestIdentifier: id, actionIdentifier: UNNotificationDismissActionIdentifier) == nil, "dismiss")
        try expect(id != SystemUpdateNotifier.requestIdentifier && id != SystemUpdateNotifier.summaryIdentifier, "shares an identifier")
        let category = SystemUpdateNotifier.makeSelfUpdateCategory()
        try expect(category.identifier == SystemUpdateNotifier.selfUpdateCategoryIdentifier && category.actions.count == 1
                   && category.actions[0].identifier == SystemUpdateNotifier.selfUpdateActionIdentifier
                   && category.actions[0].options.contains(.foreground), "category: \(category.actions.map(\.identifier))")
        try expect(SystemUpdateNotifier.selfUpdateBody(installable: true).contains("after you confirm"), "installable body")
        try expect(!SystemUpdateNotifier.selfUpdateBody(installable: false).contains("Update…"), "notify-only body offers Update")
        let notifier = SystemUpdateNotifier()
        var opened = 0
        notifier.onOpenUpdates = { opened += 1 }
        notifier.onUpdateAll = { _ in opened += 100 }
        notifier.handle(requestIdentifier: id, actionIdentifier: UNNotificationDefaultActionIdentifier)
        try expect(opened == 1, "handled: \(opened)")
        let source = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/BackgroundUpdateChecks.swift", encoding: .utf8)
        try expect(!source.contains("downloadSelfUpdate") && !source.contains("urlOpener"), "scheduler can open the release page")
    }

    check("self update: the live wiring makes no request under the tripwire, and one per check without it") {
        let root = try selfTempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data(#"{"version":1,"apps":[]}"#.utf8).write(to: URL(fileURLWithPath: root + "/catalogue.json"))
        let release = Data(#"{"tag_name":"v0.2.0","html_url":"https://github.com/birdseeed/patched/releases/tag/v0.2.0","draft":false,"prerelease":false}"#.utf8)
        @MainActor func live(_ log: URLLog, version: String?) -> AppUpdatesController {
            AppUpdatesController.live(catalogueURL: URL(fileURLWithPath: root + "/catalogue.json"), applicationsRoot: root + "/Apps",
                                      fetcher: LoggingFetcher(log: log, release: release), caskIndex: NoIndex(),
                                      installerLocations: .under(root + "/state"), runningVersion: version)
        }
        try expect(RealStateTripwire.isActive, "checks must run with PATCHED_FORBID_REAL_STATE=1")
        let tripped = RealStateTripwire.tripCount
        let log = URLLog()
        let guarded = live(log, version: "0.1.0")
        await runCheck(guarded)
        try expect(!log.urls.contains { $0.contains("api.github.com") }, "tripwire active but the release was requested: \(log.urls)")
        try expect(guarded.selfUpdate == nil && guarded.hasChecked, "guarded check state")
        try expect(RealStateTripwire.tripCount == tripped, "the self check tripped the tripwire")
        // With the tripwire lifted (still only fakes and temporary folders), exactly one request per check.
        let previous = ProcessInfo.processInfo.environment[RealStateTripwire.variable]
        setenv(RealStateTripwire.variable, "0", 1)
        defer { if let previous { setenv(RealStateTripwire.variable, previous, 1) } else { unsetenv(RealStateTripwire.variable) } }
        let open = URLLog()
        let unguarded = live(open, version: "0.1.0")
        await runCheck(unguarded)
        try expect(open.urls.filter { $0.contains("api.github.com") } == ["https://api.github.com/repos/birdseeed/patched/releases/latest"], "requests: \(open.urls)")
        try expect(unguarded.selfUpdate?.version == "0.2.0", "live wiring found: \(String(describing: unguarded.selfUpdate))")
        try expect(unguarded.selfInstaller == nil && !unguarded.canInstallSelfUpdate, "a checks binary (not Patched.app) can install itself")
        try expect(guarded.selfInstaller == nil, "self-install wired under the tripwire")
        await runCheck(unguarded)
        try expect(open.urls.filter { $0.contains("api.github.com") }.count == 2, "second check: \(open.urls)")
        // No running version (not an installed app): no request at all.
        let silent = URLLog()
        let unversioned = live(silent, version: nil)
        await runCheck(unversioned)
        try expect(!silent.urls.contains { $0.contains("api.github.com") }, "requested without a version: \(silent.urls)")
    }

    // MARK: Installing Patched itself (fake installer; nothing is downloaded, replaced or reopened)

    func installable(_ c: AppUpdatesController, _ installer: FakeSelfInstaller?, terminated: QuitCounter? = nil) {
        c.selfInstaller = installer
        if let terminated { c.selfTerminate = { terminated.bump() } }
    }

    check("self update: Update appears only for a signed release in an installed Patched, and only asks first") {
        let notifyOnly = controller(FakeLookup(newer("0.2.0", page020)))
        installable(notifyOnly, FakeSelfInstaller())
        await runCheck(notifyOnly)
        try expect(notifyOnly.selfUpdate != nil && !notifyOnly.canInstallSelfUpdate && !notifyOnly.menuUpdates().selfUpdateInstallable,
                   "a release without assets offers Update")
        notifyOnly.requestSelfUpdate()
        try expect(notifyOnly.selfInstall == .idle, "notify-only release asked to install")
        let noInstaller = controller(FakeLookup(signed("0.2.0")))
        await runCheck(noInstaller)
        try expect(noInstaller.selfUpdate?.assets != nil && !noInstaller.canInstallSelfUpdate, "Update offered without an installer (not Patched.app)")
        let fake = FakeSelfInstaller()
        let c = controller(FakeLookup(signed("0.2.0")))
        installable(c, fake)
        await runCheck(c)
        try expect(c.canInstallSelfUpdate && c.menuUpdates().selfUpdateInstallable, "Update not offered")
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), appUpdates: c, urlOpener: RecordingOpener())
        let before = try paintedText(NativeClientMenuView(session: session, openWindow: {}))
        try expect(before.contains("Patched 0.2.0 is available") && before.contains("Download") && !before.contains("quit and reopen"), "menu: \(before)")
        c.requestSelfUpdate()
        try expect(c.selfInstall == .confirming(version: "0.2.0"), "state: \(c.selfInstall)")
        let asking = try paintedText(NativeClientMenuView(session: session, openWindow: {}))
        try expect(c.selfInstall.text == "Update Patched to 0.2.0? Patched will quit and reopen.", "words: \(c.selfInstall.text ?? "")")
        try expect(asking.contains("Update Patched to 0.2.0?") && asking.contains("Update and Reopen")
                   && asking.contains("Cancel"), "menu confirmation: \(asking)")
        let window = try paintedText(AppUpdatesView(controller: c))
        // Painted text is read back by OCR, so only short, distinctive phrases are compared.
        try expect(window.contains("Update Patched to 0.2.0?") && window.contains("Update and Reopen"), "Updates confirmation: \(window)")
        c.cancelSelfUpdate()
        try expect(c.selfInstall == .idle, "cancel: \(c.selfInstall)")
        await c.waitUntilIdle()
        try expect(fake.installs.isEmpty && c.selfInstallStarts == 0, "asking or cancelling installed something")
        // Confirm without a request does nothing either.
        c.confirmSelfUpdate(); await c.waitUntilIdle()
        try expect(fake.installs.isEmpty, "confirm without a request installed")
        if let dir = ProcessInfo.processInfo.environment["PATCHED_SELFCHECK_PNG_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try paintView(NativeClientMenuView(session: session, openWindow: {}), width: 320, height: 460)
                .write(to: URL(fileURLWithPath: dir + "/selfupdate-offer-menu.png"))
            try paintView(AppUpdatesView(controller: c), width: 820, height: 300)
                .write(to: URL(fileURLWithPath: dir + "/selfupdate-offer-updates.png"))
            c.requestSelfUpdate()
            try paintView(NativeClientMenuView(session: session, openWindow: {}), width: 320, height: 460)
                .write(to: URL(fileURLWithPath: dir + "/selfupdate-confirm-menu.png"))
            c.cancelSelfUpdate()
        }
    }

    check("self update: a newer release arriving under an open confirmation closes it, and nothing installs") {
        let fake = FakeSelfInstaller()
        let lookup = FakeLookup(signed("0.2.0"))
        let c = controller(lookup)
        installable(c, fake)
        await runCheck(c)
        c.requestSelfUpdate()
        try expect(c.selfInstall == .confirming(version: "0.2.0"), "state: \(c.selfInstall)")
        lookup.result = signed("0.3.0")
        await runCheck(c)
        try expect(c.selfUpdate?.version == "0.3.0" && c.selfInstall == .idle, "stale confirmation kept: \(c.selfInstall)")
        c.confirmSelfUpdate(); await c.waitUntilIdle()
        try expect(fake.installs.isEmpty, "a confirmation for 0.2.0 installed something")
        // The same version announced again keeps the confirmation open.
        c.requestSelfUpdate()
        await runCheck(c)
        try expect(c.selfInstall == .confirming(version: "0.3.0"), "same-version recheck closed it: \(c.selfInstall)")
        c.cancelSelfUpdate()
    }

    check("self update: confirming installs the signed release once, reopens the new Patched and quits") {
        let fake = FakeSelfInstaller(), terminated = QuitCounter()
        let c = controller(FakeLookup(signed("0.2.0")))
        installable(c, fake, terminated: terminated)
        await runCheck(c)
        c.requestSelfUpdate(); c.confirmSelfUpdate(); c.confirmSelfUpdate()
        await c.waitUntilIdle()
        try expect(fake.installs.count == 1 && fake.installs[0].version == "0.2.0" && fake.installs[0].assets == signedAssets("0.2.0"),
                   "installs: \(fake.installs)")
        try expect(fake.relaunches == ["/Applications/Patched.app"] && terminated.count == 1, "relaunch \(fake.relaunches), quit \(terminated.count)")
        try expect(c.selfInstall == .reopening(version: "0.2.0"), "state: \(c.selfInstall)")
    }

    check("self update: a failure says why, leaves Patched running, and needs admin opens the release page") {
        let cases: [(String, InstallRefusal, String)] = [
            ("signature", .releaseSignatureInvalid("does not match"), "isn't signed with Patched's release key"),
            ("download", .download("HTTP 500"), "the download failed (HTTP 500)"),
            ("version", .versionMismatch("0.3.0"), "isn't the Patched release it should be"),
            ("codesign", .signatureInvalid("x"), "code signature didn't verify"),
            ("swapped back", .verificationFailedAfterSwap("x"), "Patched is unchanged"),
        ]
        for (name, refusal, words) in cases {
            let fake = FakeSelfInstaller(), terminated = QuitCounter(), opener = RecordingOpener()
            fake.failure = refusal
            let c = controller(FakeLookup(signed("0.2.0")))
            installable(c, fake, terminated: terminated)
            c.urlOpener = opener
            await runCheck(c)
            c.requestSelfUpdate(); c.confirmSelfUpdate(); await c.waitUntilIdle()
            try expect(c.selfInstall.text?.contains(words) == true && c.selfInstall.isFailed, "\(name): \(c.selfInstall)")
            try expect(terminated.count == 0 && fake.relaunches.isEmpty && opener.nothingOpened, "\(name): quit, reopened or opened something")
            try expect(!c.isWorking && c.canCheck && c.canInstallSelfUpdate, "\(name): Patched is stuck after a failure")
            let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), appUpdates: c, urlOpener: opener)
            let menu = try paintedText(NativeClientMenuView(session: session, openWindow: {}))
            try expect(menu.contains("Couldn't update Patched") && menu.contains("Dismiss"), "\(name) menu: \(menu)")
            c.cancelSelfUpdate()
            try expect(c.selfInstall == .idle, "\(name): dismiss")
        }
        let fake = FakeSelfInstaller(), opener = RecordingOpener(), terminated = QuitCounter()
        fake.failure = .needsAdmin("/Applications is not writable by this user")
        let c = controller(FakeLookup(signed("0.2.0")))
        installable(c, fake, terminated: terminated)
        c.urlOpener = opener
        await runCheck(c)
        c.requestSelfUpdate(); c.confirmSelfUpdate(); await c.waitUntilIdle()
        try expect(opener.urls == [page020] && opener.apps.isEmpty, "admin: opened \(opener.urls)")
        try expect(c.selfInstall.text?.contains("admin rights") == true && terminated.count == 0, "admin: \(c.selfInstall)")
        // Installed but not reopened: say so, and do not quit.
        let reopenFails = FakeSelfInstaller(), quit = QuitCounter()
        reopenFails.relaunchFails = true
        let r = controller(FakeLookup(signed("0.2.0")))
        installable(r, reopenFails, terminated: quit)
        await runCheck(r)
        r.requestSelfUpdate(); r.confirmSelfUpdate(); await r.waitUntilIdle()
        try expect(r.selfInstall.text?.contains("is installed. Quit Patched and open it again") == true && quit.count == 0, "reopen: \(r.selfInstall)")
    }

    check("self update: progress shows while installing, and nothing else can start meanwhile") {
        let fake = FakeSelfInstaller(), gate = Gate()
        fake.gate = gate
        let c = controller(FakeLookup(signed("0.2.0")), others: [outcome(app("Plain"), .updateAvailable(offer("2.0")))])
        installable(c, fake, terminated: QuitCounter())
        await runCheck(c)
        c.requestSelfUpdate(); c.confirmSelfUpdate()
        var waited = 0
        while c.selfInstall != .working(version: "0.2.0", step: .installing) && waited < 200 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        try expect(c.selfInstall == .working(version: "0.2.0", step: .installing), "progress: \(c.selfInstall)")
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), appUpdates: c, urlOpener: RecordingOpener())
        let menu = try paintedText(NativeClientMenuView(session: session, openWindow: {}))
        try expect(menu.contains("Installing Patched 0.2.0"), "menu progress: \(menu)")
        try expect(!c.canCheck && !c.canUpdateAll && !c.canInstallSelfUpdate, "other actions open while Patched installs itself")
        try expect(!c.updateAll(), "Update All started during a self-update")
        gate.open(); await c.waitUntilIdle()
    }

    check("self update: scheduled checks, Update All and the notification never install Patched") {
        let rig = Rig([patchedOutcome(), outcome(app("Plain"), .updateAvailable(offer("2.0")))])
        let fake = FakeSelfInstaller()
        rig.controller.selfInstaller = fake
        rig.controller.selfUpdateCheck = FakeLookup(signed("0.2.0")).check
        rig.scheduler.start(); await rig.settle()
        for _ in 0..<2 { rig.clock.advance(UpdateCheckScheduler.interval + 1); try rig.timer.fireActive(); await rig.settle() }
        try expect(rig.notifier.postedSelf.map(\.version) == ["0.2.0"] && rig.notifier.postedSelf[0].assets != nil, "posted: \(rig.notifier.postedSelf)")
        try expect(rig.controller.selfInstall == .idle && fake.installs.isEmpty, "a scheduled check started a self-update")
        _ = rig.controller.updateAll(); await rig.settle()
        try expect(fake.installs.isEmpty && rig.controller.selfInstall == .idle, "Update All installed Patched")
        // The notification's Update… button opens Updates and asks; it does not install.
        let notifier = SystemUpdateNotifier()
        let session = NativeClientSession(navigation: ShellNavigation(destination: .applications), appUpdates: rig.controller, urlOpener: RecordingOpener())
        var opened = 0
        session.wireSelfUpdateAction(notifier, openUpdates: { opened += 1 })
        notifier.handle(requestIdentifier: SystemUpdateNotifier.selfUpdateIdentifier, actionIdentifier: SystemUpdateNotifier.selfUpdateActionIdentifier)
        await rig.settle()
        try expect(opened == 1 && rig.controller.selfInstall == .confirming(version: "0.2.0"), "button: opened \(opened), \(rig.controller.selfInstall)")
        try expect(fake.installs.isEmpty, "the notification button installed without confirmation")
        // The scheduler, Update All and the command line have no way to reach the install.
        for (file, words) in [("PatchedClient/BackgroundUpdateChecks.swift", ["requestSelfUpdate", "confirmSelfUpdate", "selfInstaller", "SelfUpdater"]),
                              ("PatchedClient/UpdateAllEntryPoints.swift", ["confirmSelfUpdate", "selfInstaller", "SelfUpdater"]),
                              ("PatchedCLI/main.swift", ["requestSelfUpdate", "confirmSelfUpdate", "selfInstaller", "SelfUpdater", "SelfRelaunch"])] {
            let text = try String(contentsOfFile: sourcesRoot() + "/" + file, encoding: .utf8)
            for word in words { try expect(!text.contains(word), "\(file) mentions \(word)") }
        }
    }
}

private func selfTempRoot() throws -> String {
    let tmp = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
    let root = tmp + "/patched-selfupdate-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root + "/Apps", withIntermediateDirectories: true)
    return root
}
