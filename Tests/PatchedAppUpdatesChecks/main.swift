import Foundation
import Darwin
import SwiftUI
import AppKit
import Combine
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

// Checks for the Updates screen controller and view. Everything is injected: no network, no real
// /Applications, no real installer state. The only filesystem use is temporary folders.
struct CheckFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: Bool, _ message: String) throws { if !condition { throw CheckFailure(description: message) } }

var cases: [(String, @MainActor () async throws -> Void)] = []
@MainActor func check(_ name: String, _ action: @escaping @MainActor () async throws -> Void) { cases.append((name, action)) }

func onMainThread() -> Bool { pthread_main_np() != 0 }

// MARK: Fakes and builders

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    private var _threadFlags: [Bool] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return _threadFlags.contains(true) }
    var sawAnyThread: Bool { lock.lock(); defer { lock.unlock() }; return !_threadFlags.isEmpty }
    func note(_ event: String) {
        lock.lock(); _events.append(event); _threadFlags.append(onMainThread()); lock.unlock()
    }
}

/// What is "on disk": the check and recheck seams both read it, and the fake installer changes it.
final class World: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [String: AppCheckOutcome]
    init(_ list: [AppCheckOutcome]) { outcomes = Dictionary(list.map { ($0.app.path, $0) }, uniquingKeysWith: { a, _ in a }) }
    subscript(path: String) -> AppCheckOutcome? {
        get { lock.lock(); defer { lock.unlock() }; return outcomes[path] }
        set { lock.lock(); outcomes[path] = newValue; lock.unlock() }
    }
    /// The app now at `path` has `version`, and nothing newer is on offer.
    func install(_ path: String, version: String) {
        guard let old = self[path] else { return }
        let app = InstalledApp(name: old.app.name, path: path, bundleID: old.app.bundleID, shortVersion: version, build: version)
        self[path] = AppCheckOutcome(app: app, teamID: old.teamID, source: old.source, lowConfidence: false, installable: false, result: .upToDate)
    }
}

final class FakeInstaller: AppUpdateInstalling, @unchecked Sendable {
    let recorder: Recorder
    var world: World?
    var onRecover: (@Sendable () -> Void)?
    var blockBackups: DispatchSemaphore?
    private let lock = NSLock()
    private var _lastOutcome: AppCheckOutcome?
    private var _unreadable: [String] = []
    private func remember(_ outcome: AppCheckOutcome) { lock.lock(); _lastOutcome = outcome; lock.unlock() }
    var lastOutcome: AppCheckOutcome? { lock.lock(); defer { lock.unlock() }; return _lastOutcome }
    var unreadable: [String] { get { lock.lock(); defer { lock.unlock() }; return _unreadable } set { lock.lock(); _unreadable = newValue; lock.unlock() } }
    private var _backups: [BackupRecord] = []
    private var _unfinished = 0
    private var _recovery = AppRecoveryResult(entries: [])
    var updateHandler: @Sendable (AppCheckOutcome, Bool) async throws -> AppUpdateReport
    var rollbackHandler: @Sendable (String, Bool) async throws -> AppUpdateReport

    init(recorder: Recorder = Recorder()) {
        self.recorder = recorder
        updateHandler = { outcome, _ in
            var to = "?"
            if case .updateAvailable(let offer) = outcome.result { to = offer.displayVersion }
            return AppUpdateReport(status: "installed", fromVersion: outcome.app.shortVersion ?? "?", toVersion: to, backupFolder: "/b")
        }
        rollbackHandler = { _, _ in AppUpdateReport(status: "rolled_back", fromVersion: "2.0", toVersion: "1.0", backupFolder: "/b2") }
    }
    var backups: [BackupRecord] { get { lock.lock(); defer { lock.unlock() }; return _backups } set { lock.lock(); _backups = newValue; lock.unlock() } }
    var unfinished: Int { get { lock.lock(); defer { lock.unlock() }; return _unfinished } set { lock.lock(); _unfinished = newValue; lock.unlock() } }
    var recovery: AppRecoveryResult { get { lock.lock(); defer { lock.unlock() }; return _recovery } set { lock.lock(); _recovery = newValue; lock.unlock() } }

    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool) async throws -> AppUpdateReport {
        recorder.note("update \(outcome.app.name) quit=\(quitIfRunning)")
        remember(outcome)
        let report = try await updateHandler(outcome, quitIfRunning)
        world?.install(outcome.app.path, version: report.toVersion)
        return report
    }
    func rollBack(appAt path: String, quitIfRunning: Bool) async throws -> AppUpdateReport {
        recorder.note("rollback \((path as NSString).lastPathComponent) quit=\(quitIfRunning)")
        let report = try await rollbackHandler(path, quitIfRunning)
        world?.install(path, version: report.toVersion)
        return report
    }
    func recoverUnfinished(quitIfRunning: Bool) async -> AppRecoveryResult {
        recorder.note("recover quit=\(quitIfRunning)")
        let result = recovery
        onRecover?()
        if case .success? = result.entries.first?.result { unfinished = 0 }
        return result
    }
    func allBackups() -> [BackupRecord] {
        if let gate = blockBackups { recorder.note("backups-blocked"); gate.wait() }
        return backups
    }
    func unreadableJournalPaths() -> [String] { unreadable }
    func unfinishedTransactionCount() -> Int { unfinished }

    // Progress: the handler the controller gave the last update, so a test's update handler can report steps.
    private var _progress: UpdateProgressHandler?
    func emit(_ step: UpdateProgress) { lock.withLock { _progress }?(step) }
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?,
                progress: UpdateProgressHandler?) async throws -> AppUpdateReport {
        lock.withLock { _progress = progress }
        return try await update(outcome, quitIfRunning: quitIfRunning, admin: admin)
    }

    // Experimental admin path: records every consent token it is given.
    var adminHandler: (@Sendable (AppCheckOutcome, AdminInteraction) async throws -> AppUpdateReport)?
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport {
        guard let admin else { return try await update(outcome, quitIfRunning: quitIfRunning) }
        recorder.note("admin-update \(outcome.app.name)")
        guard let adminHandler else { return try await update(outcome, quitIfRunning: quitIfRunning) }
        recorder.note("update \(outcome.app.name) quit=\(quitIfRunning)")
        remember(outcome)
        let report = try await adminHandler(outcome, admin)
        world?.install(outcome.app.path, version: report.toVersion)
        return report
    }
    func rollBack(appAt path: String, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport {
        if admin != nil { recorder.note("admin-rollback \((path as NSString).lastPathComponent)") }
        return try await rollBack(appAt: path, quitIfRunning: quitIfRunning)
    }
}

func app(_ name: String, id: String? = nil, version: String = "1.0") -> InstalledApp {
    InstalledApp(name: name, path: "/Fake/\(name).app", bundleID: id ?? "com.example.\(name.lowercased())",
                 shortVersion: version, build: version)
}
func offer(_ version: String, format: ArtifactFormat = .zip, source: UpdateSource? = nil, build: String? = nil) -> UpdateOffer {
    UpdateOffer(displayVersion: version, buildVersion: build ?? version, downloadURL: URL(string: "https://example.com/\(version).zip")!,
                format: format, source: source ?? .sparkle(feed: URL(string: "https://example.com/feed.xml")!))
}
func outcome(_ app: InstalledApp, _ result: CheckResult, source: UpdateSource? = nil, noSource: Bool = false, low: Bool = false, installable: Bool? = nil) -> AppCheckOutcome {
    var installableValue = false
    if case .updateAvailable = result { installableValue = !low }
    return AppCheckOutcome(app: app, teamID: "TEAM123456", source: noSource ? nil : (source ?? .sparkle(feed: URL(string: "https://example.com/feed.xml")!)),
                           lowConfidence: low, installable: installable ?? installableValue, result: result)
}
func backup(_ app: InstalledApp, version: String = "0.9") throws -> BackupRecord {
    let json = """
    {"bundleID":"\(app.bundleID ?? "")","teamID":"TEAM123456","appName":"\((app.path as NSString).lastPathComponent)",
     "shortVersion":"\(version)","build":"\(version)","originalPath":"\(app.path)","createdAt":"2026-11-05T10:00:00Z"}
    """
    return try JSONDecoder().decode(BackupRecord.self, from: Data(json.utf8))
}

@MainActor func makeController(outcomes: [AppCheckOutcome], installer: FakeInstaller = FakeInstaller(),
                               recorder: Recorder? = nil, world: World? = nil,
                               catalogue: @escaping AppUpdateCatalogueProbe = { nil }, adminUpdates: Bool = false,
                               packageUpdates: Bool = false, editCatalogue: AppUpdateCatalogueEdit? = nil) -> AppUpdatesController {
    let recorder = recorder ?? installer.recorder
    let world = world ?? World(outcomes)
    installer.world = world
    return AppUpdatesController(
        scan: { recorder.note("scan"); return outcomes.compactMap { world[$0.app.path] }.map { AppUpdateScannedApp(app: $0.app, icon: nil) } },
        check: { apps in recorder.note("check"); return apps.compactMap { world[$0.path] } },
        recheck: { path in recorder.note("recheck \((path as NSString).lastPathComponent)"); return world[path] },
        catalogue: catalogue, editCatalogue: editCatalogue, installer: installer, adminUpdates: adminUpdates, packageUpdates: packageUpdates)
}
@MainActor func runCheck(_ controller: AppUpdatesController) async {
    controller.check(); await controller.waitUntilIdle()
}
@MainActor func runOperation(_ controller: AppUpdatesController, _ start: () -> Void) async {
    start(); await controller.waitUntilIdle()
}

// MARK: Rows

check("rows: every status is built from the fake outcomes") {
    let up = app("Alpha"), upd = app("Bravo"), low = app("Charlie"), pkg = app("Delta"), none = app("Echo"), bad = app("Foxtrot")
    let cask = UpdateSource.homebrewCask(token: "charlie")
    let controller = makeController(outcomes: [
        outcome(up, .upToDate), outcome(upd, .updateAvailable(offer("2.0"))),
        outcome(low, .updateAvailable(offer("3.0", source: cask)), source: cask, low: true),
        outcome(pkg, .updateAvailable(offer("4.0", format: .pkg))),
        outcome(none, .noSource, noSource: true), outcome(bad, .refused(.network("offline")))])
    await runCheck(controller)
    @MainActor func row(_ name: String) throws -> AppUpdateRow {
        guard let r = controller.rows.first(where: { $0.name == name }) else { throw CheckFailure(description: "missing row \(name)") }
        return r
    }
    try expect(controller.rows.map(\.name) == ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"], "rows not sorted by name")
    try expect(try row("Alpha").status == .upToDate && row("Alpha").statusText == "Up to date", "up to date")
    try expect(try row("Bravo").status == .updateAvailable && row("Bravo").latestVersion == "2.0" && row("Bravo").installedVersion == "1.0", "update available versions")
    try expect(try row("Bravo").source == "sparkle", "source kind")
    try expect(try row("Charlie").status == .notInstallable && row("Charlie").source == "homebrew?", "low confidence must show ? and be not installable: \(try row("Charlie").source)")
    try expect(try row("Delta").status == .packageUnsupported && row("Delta").statusText == "Installer package updates are turned off", "pkg status")
    try expect(try row("Echo").status == .noSource && row("Echo").source == "—", "no source")
    try expect(try row("Foxtrot").statusText == "Can't check: network error: offline", "refused reason: \(try row("Foxtrot").statusText)")
    try expect(controller.summary == "6 apps checked, 3 with updates available.", "summary: \(controller.summary)")
}

check("rows: an unsigned offer for an app that pins SUPublicEDKey is not installable and says why") {
    let pinned = InstalledApp(name: "Pinned", path: "/Fake/Pinned.app", bundleID: "com.example.pinned", shortVersion: "1.0", build: "1.0", sparklePublicEDKey: Data(repeating: 1, count: 32).base64EncodedString())
    let cask = UpdateSource.homebrewCask(token: "pinned")
    // installable: false is set by hand here, so this check covers the row wording only; the checker test in
    // UpdateSourcesChecks proves the checker itself marks these offers not installable.
    let o = outcome(pinned, .updateAvailable(offer("2.0", source: cask)), source: cask, installable: false)
    try expect(o.edSignatureBlock == .signatureMissing, "outcome should report the missing signature")
    let controller = makeController(outcomes: [o])
    await runCheck(controller)
    guard let row = controller.rows.first else { throw CheckFailure(description: "no row") }
    try expect(row.status == .notInstallable, "status \(row.status)")
    try expect(row.kindNote == "Unsigned", "kindNote \(String(describing: row.kindNote))")
    try expect(row.statusText == "Update found, but it isn't signed the way this app requires. Add a catalogue entry for the app's Sparkle feed to enable updates.", "statusText \(row.statusText)")
    try expect(!controller.canUpdate(row), "no Update button for an unsigned offer")
}

check("update is disabled unless the update is installable, and the installer is never called") {
    let low = app("Charlie"), pkg = app("Delta"), ok = app("Bravo"), forced = app("Golf")
    let installer = FakeInstaller()
    let controller = makeController(outcomes: [
        outcome(ok, .updateAvailable(offer("2.0"))),
        outcome(low, .updateAvailable(offer("3.0")), low: true),
        outcome(pkg, .updateAvailable(offer("4.0", format: .pkg))),
        outcome(forced, .upToDate)], installer: installer)
    await runCheck(controller)
    for name in ["Charlie", "Delta", "Golf"] {
        let row = controller.rows.first { $0.name == name }!
        try expect(!controller.canUpdate(row), "\(name) must not be updatable")
        await runOperation(controller) { controller.update(id: row.id) }
    }
    try expect(installer.recorder.events.filter { $0.hasPrefix("update") }.isEmpty, "installer called for a non-installable row")
    try expect(controller.canUpdate(controller.rows.first { $0.name == "Bravo" }!), "installable row must be updatable")
    try expect(controller.updatableRows.map(\.name) == ["Bravo"], "updatable rows")
}

check("update: success text is OutcomeText wording and the row becomes up to date") {
    let a = app("Bravo")
    let installer = FakeInstaller()
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer)
    await runCheck(controller)
    await runOperation(controller) { controller.update(id: a.path) }
    let row = controller.rows[0]
    let expected = OutcomeText.line(name: "Bravo", status: "installed", from: "1.0", to: "2.0", backupFolder: "/b", reason: nil, detail: nil)
    try expect(row.result?.text == expected && row.result?.kind == .success, "result: \(String(describing: row.result))")
    try expect(row.status == .upToDate && row.installedVersion == "2.0" && row.activity == .idle, "row after update: \(row)")
    try expect(installer.recorder.events.contains("update Bravo quit=false"), "first attempt must not quit")
    try expect(!controller.isWorking, "still working")
}

check("update all continues past a failure and skips open apps without quitting them") {
    let a = app("Alpha"), b = app("Bravo"), c = app("Charlie"), d = app("Delta")
    let installer = FakeInstaller()
    installer.updateHandler = { outcome, quit in
        switch outcome.app.name {
        case "Bravo": throw InstallRefusal.hashMismatch("bad")
        case "Charlie": throw InstallRefusal.appRunning("Charlie is running")
        default: return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
    }
    let controller = makeController(outcomes: [a, b, c, d].map { outcome($0, .updateAvailable(offer("2.0"))) }, installer: installer)
    await runCheck(controller)
    await runOperation(controller) { controller.updateAll() }
    try expect(installer.recorder.events.filter { $0.hasPrefix("update") } ==
        ["update Alpha quit=false", "update Bravo quit=false", "update Charlie quit=false", "update Delta quit=false"],
        "update all must try every app in order, never quitting: \(installer.recorder.events)")
    @MainActor func row(_ n: String) -> AppUpdateRow { controller.rows.first { $0.name == n }! }
    try expect(row("Alpha").status == .upToDate && row("Delta").status == .upToDate, "later apps still updated")
    try expect(row("Bravo").result?.kind == .failure && (row("Bravo").result?.text.contains("hash_mismatch") ?? false), "failure text: \(String(describing: row("Bravo").result))")
    try expect(row("Charlie").status == .updateAvailable && row("Charlie").result?.kind == .info, "open app left updatable")
    try expect(controller.pendingQuit == nil, "update all must not raise a quit confirmation")
    try expect(controller.summary == "2 updated, 1 failed, 1 skipped.", "summary: \(controller.summary)")
}

check("app_running asks first, then retries with quit only on confirm") {
    let a = app("Bravo")
    let installer = FakeInstaller()
    installer.updateHandler = { outcome, quit in
        if !quit { throw InstallRefusal.appRunning("Bravo is running") }
        return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
    }
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer)
    await runCheck(controller)
    await runOperation(controller) { controller.update(id: a.path) }
    try expect(controller.pendingQuit?.message == "Bravo is open. Quit it, update, and reopen it?", "confirmation: \(String(describing: controller.pendingQuit))")
    try expect(installer.recorder.events.filter { $0.hasPrefix("update") } == ["update Bravo quit=false"], "must not quit before confirmation")
    // Declining leaves everything as it was.
    controller.cancelQuit()
    try expect(controller.pendingQuit == nil && installer.recorder.events.filter { $0.hasPrefix("update") }.count == 1, "cancel retried")
    await runOperation(controller) { controller.update(id: a.path) }
    await runOperation(controller) { controller.confirmQuit() }
    try expect(installer.recorder.events.filter { $0.hasPrefix("update") }.last == "update Bravo quit=true", "confirm must retry with quit: \(installer.recorder.events)")
    try expect(controller.rows[0].status == .upToDate && controller.pendingQuit == nil, "row after confirmed retry")
}

check("needs_admin and pkg refusals use the friendly wording, not an error style") {
    let a = app("Admin"), p = app("Pkgy")
    let installer = FakeInstaller()
    installer.updateHandler = { outcome, _ in
        if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
        throw InstallRefusal.unsupportedFormat("pkg")
    }
    // A pkg offer never reaches the installer (its row is already marked unsupported), so the installer's
    // unsupported_format refusal is exercised with a tarball offer and gets the same non-error treatment.
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0"))), outcome(p, .updateAvailable(offer("2.0", format: .tarball)))], installer: installer)
    await runCheck(controller)
    await runOperation(controller) { controller.update(id: a.path) }
    await runOperation(controller) { controller.update(id: p.path) }
    let admin = controller.rows.first { $0.name == "Admin" }!, pkg = controller.rows.first { $0.name == "Pkgy" }!
    try expect(admin.result?.text == "Admin: Needs admin rights. Open the app and use its own updater." && admin.result?.kind == .info, "admin: \(String(describing: admin.result))")
    try expect(pkg.result?.text == "Pkgy: This download format is not supported yet" && pkg.result?.kind == .info, "pkg: \(String(describing: pkg.result))")
    try expect(admin.status == .updateAvailable, "row must stay as it was")
}

check("a backup replaced by an installer package shows no Roll back, only the unsupported caption") {
    let a = app("Alpha"), b = app("Bravo")
    let installer = FakeInstaller()
    var pkgBackup = try backup(a, version: "0.9")
    pkgBackup.installedByPackage = true
    installer.backups = [pkgBackup, try backup(b, version: "0.9")]
    let controller = makeController(outcomes: [outcome(a, .upToDate), outcome(b, .upToDate)], installer: installer)
    await runCheck(controller)
    let alpha = controller.rows.first { $0.name == "Alpha" }!, bravo = controller.rows.first { $0.name == "Bravo" }!
    try expect(alpha.rollbackUnsupported && !alpha.canRollBack && alpha.rollbackVersion == nil && !controller.canRollBack(alpha), "Alpha: \(alpha)")
    try expect(!bravo.rollbackUnsupported && bravo.canRollBack, "Bravo keeps its ordinary rollback")
    try expect(AppUpdateRow.rollbackUnsupportedCaption == "Roll back isn't supported for installer packages.", "caption")
    await runOperation(controller) { controller.rollBack(id: alpha.id) }
    try expect(!installer.recorder.events.contains { $0.hasPrefix("rollback") }, "package rollback was attempted")
}

check("rollback is offered only where a matching backup exists, and shows the CLI wording") {
    let a = app("Alpha"), b = app("Bravo")
    let installer = FakeInstaller()
    installer.backups = [try backup(a, version: "0.9")]
    let controller = makeController(outcomes: [outcome(a, .upToDate), outcome(b, .upToDate)], installer: installer)
    await runCheck(controller)
    let alpha = controller.rows.first { $0.name == "Alpha" }!, bravo = controller.rows.first { $0.name == "Bravo" }!
    try expect(alpha.canRollBack && alpha.rollbackVersion == "0.9" && controller.canRollBack(alpha), "Alpha rollback")
    try expect(!bravo.canRollBack && !controller.canRollBack(bravo), "Bravo has no backup")
    await runOperation(controller) { controller.rollBack(id: bravo.id) }
    try expect(!installer.recorder.events.contains { $0.hasPrefix("rollback") }, "rollback without backup was attempted")
    await runOperation(controller) { controller.rollBack(id: alpha.id) }
    let row = controller.rows.first { $0.name == "Alpha" }!
    let expected = OutcomeText.line(name: "Alpha", status: "rolled_back", from: "2.0", to: "1.0", backupFolder: "/b2", reason: nil, detail: nil)
    try expect(row.result?.text == expected && row.status == .upToDate && row.installedVersion == "1.0", "rollback result: \(String(describing: row.result)) \(row.status)")
}

check("a backup for a different copy of the same app does not enable rollback") {
    let a = app("Alpha")
    let other = InstalledApp(name: "Alpha", path: "/Elsewhere/Alpha.app", bundleID: a.bundleID, shortVersion: "1.0", build: "1.0")
    let installer = FakeInstaller()
    installer.backups = [try backup(other)]
    let controller = makeController(outcomes: [outcome(a, .upToDate)], installer: installer)
    await runCheck(controller)
    try expect(!controller.rows[0].canRollBack, "backup of /Elsewhere offered for /Fake")
}

check("recover banner count and recover action") {
    let installer = FakeInstaller()
    installer.unfinished = 2
    installer.recovery = AppRecoveryResult(entries: [.init(targetPath: "/Fake/Alpha.app", result: .success(.reverted))])
    let controller = makeController(outcomes: [], installer: installer)
    await controller.refreshInstallerState()
    try expect(controller.unfinishedCount == 2, "banner count")
    await runOperation(controller) { controller.recover() }
    try expect(installer.recorder.events.contains("recover quit=false"), "recover not called")
    try expect(controller.recoveryMessage?.contains("undone; old version is back in place") == true, "message: \(String(describing: controller.recoveryMessage))")
    try expect(controller.unfinishedCount == 0, "count not refreshed")
}

check("recover with an open app asks before quitting") {
    let installer = FakeInstaller()
    installer.unfinished = 1
    installer.recovery = AppRecoveryResult(entries: [.init(targetPath: "/Fake/Alpha.app", result: .failure(.appRunning("running")))])
    let controller = makeController(outcomes: [], installer: installer)
    await runOperation(controller) { controller.recover() }
    try expect(controller.pendingQuit?.action == .recover, "recover confirmation missing")
    await runOperation(controller) { controller.confirmQuit() }
    try expect(installer.recorder.events.filter { $0.hasPrefix("recover") } == ["recover quit=false", "recover quit=true"], "recover quit retry: \(installer.recorder.events)")
}

// MARK: Concurrency

check("a check cannot start twice, blocks actions while running, and cancel restores the rows") {
    let a = app("Alpha")
    let recorder = Recorder()
    let (stream, release) = AsyncStream<Void>.makeStream()
    let controller = AppUpdatesController(
        scan: { recorder.note("scan"); return [AppUpdateScannedApp(app: a, icon: nil)] },
        check: { apps in
            recorder.note("check")
            for await _ in stream { break }
            return apps.map { outcome($0, .updateAvailable(offer("2.0"))) }
        }, recheck: { _ in nil }, installer: FakeInstaller(recorder: recorder))
    controller.check()
    controller.check()
    controller.check()
    try expect(controller.phase == .checking && !controller.canCheck, "phase while checking")
    // Let the first (only) check reach the blocked checker.
    for _ in 0..<200 where !recorder.events.contains("check") { try await Task.sleep(nanoseconds: 10_000_000) }
    controller.check()
    try expect(recorder.events.filter { $0 == "scan" }.count == 1 && recorder.events.filter { $0 == "check" }.count == 1,
               "check started more than once: \(recorder.events)")
    try expect(controller.rows.first?.status == .pending && controller.rows.first?.activity == .checking, "row should show checking")
    controller.update(id: a.path); controller.updateAll(); controller.recover()
    try expect(!controller.isWorking, "actions must be refused during a check")
    release.yield()
    await controller.waitUntilIdle()
    try expect(controller.phase == .idle && controller.rows.first?.status == .updateAvailable, "check did not finish")
    try expect(recorder.events.filter { $0 == "check" }.count == 1, "extra check ran")
}

check("cancel returns to idle, keeps the previous rows and ignores the stale result") {
    let a = app("Alpha")
    let recorder = Recorder()
    let (stream, release) = AsyncStream<Void>.makeStream()
    let counter = Counter()
    let controller = AppUpdatesController(
        scan: { [AppUpdateScannedApp(app: a, icon: nil)] },
        check: { apps in
            switch counter.next() {
            case 2:
                recorder.note("second-checker-entered")
                for await _ in stream { break }
                return apps.map { outcome($0, .updateAvailable(offer("9.9"))) }
            default: return apps.map { outcome($0, .upToDate) }
            }
        }, recheck: { _ in nil }, installer: FakeInstaller(recorder: recorder))
    await runCheck(controller)
    try expect(controller.rows[0].status == .upToDate, "first check")
    controller.check()
    for _ in 0..<300 where !recorder.events.contains("second-checker-entered") { try await Task.sleep(nanoseconds: 10_000_000) }
    try expect(recorder.events.contains("second-checker-entered"), "second checker never started")
    controller.cancelCheck()
    try expect(controller.phase == .idle && controller.rows[0].status == .upToDate, "cancel should restore the earlier rows")
    // A newer check completes while the cancelled one is still running.
    await runCheck(controller)
    try expect(controller.rows[0].status == .upToDate && controller.rows[0].latestVersion == "1.0", "newer check")
    release.yield()
    try await Task.sleep(nanoseconds: 150_000_000)
    try expect(controller.rows[0].status == .upToDate && controller.rows[0].latestVersion == "1.0", "stale result overwrote the newer one: \(controller.rows[0])")
    try expect(controller.canCheck, "a new check must be allowed after cancel")
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func reset() { lock.lock(); n = 0; lock.unlock() }
}

check("work runs off the main thread and every published change arrives on the main thread") {
    let a = app("Alpha")
    let recorder = Recorder()
    let installer = FakeInstaller(recorder: recorder)
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer, recorder: recorder)
    var cancellables = Set<AnyCancellable>()
    var publishedOffMain = false
    controller.objectWillChange.sink { if !onMainThread() { publishedOffMain = true } }.store(in: &cancellables)
    controller.$rows.sink { _ in if !onMainThread() { publishedOffMain = true } }.store(in: &cancellables)
    await runCheck(controller)
    await runOperation(controller) { controller.update(id: a.path) }
    try expect(recorder.sawAnyThread && !recorder.ranOnMain, "scan/check/install must not run on the main thread: \(recorder.events)")
    try expect(!publishedOffMain, "a published change happened off the main thread")
    try expect(onMainThread(), "test lost the main thread")
}

// MARK: Review fixes

@MainActor func eventsStarting(_ installer: FakeInstaller, _ prefix: String) -> [String] { installer.recorder.events.filter { $0.hasPrefix(prefix) } }

check("catalogue: an unreadable catalogue pauses Check, Update and Update All until it loads again") {
    let a = app("Alpha")
    let installer = FakeInstaller()
    let broken = Counter()
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer,
                                    catalogue: { broken.value > 0 ? "/x/catalogue.json: not a JSON object" : nil })
    await runCheck(controller)
    try expect(controller.updatableRows.count == 1 && controller.canCheck, "baseline")
    _ = broken.next()
    await controller.refreshInstallerState()
    try expect(controller.catalogueError == "catalogue.json can't be read: /x/catalogue.json: not a JSON object — fix or remove it",
               "banner: \(String(describing: controller.catalogueError))")
    try expect(!controller.canCheck && !controller.canUpdate(controller.rows[0]) && !controller.canUpdateAll, "actions must be paused")
    let scans = installer.recorder.events.filter { $0 == "scan" }.count
    controller.check(); controller.update(id: a.path); controller.updateAll()
    await controller.waitUntilIdle()
    try expect(controller.phase == .idle && !controller.isWorking && installer.recorder.events.filter { $0 == "scan" }.count == scans
               && eventsStarting(installer, "update").isEmpty, "paused controller acted")
    broken.reset()
    await controller.refreshInstallerState()
    try expect(controller.catalogueError == nil && controller.canCheck && controller.canUpdateAll, "must resume after a good load")
}

check("catalogue: a check that cannot read the catalogue stops, keeps the old rows and reports it") {
    struct BadCatalogue: Error, CustomStringConvertible { let description = "bad catalogue" }
    let a = app("Alpha")
    let installer = FakeInstaller()
    let fail = Counter()
    let world = World([outcome(a, .upToDate)])
    let controller = AppUpdatesController(scan: { [AppUpdateScannedApp(app: a, icon: nil)] },
        check: { apps in
            if fail.value > 0 { throw BadCatalogue() }
            return apps.compactMap { world[$0.path] }
        }, recheck: { world[$0] }, installer: installer)
    await runCheck(controller)
    _ = fail.next()
    await runCheck(controller)
    try expect(controller.catalogueError?.contains("bad catalogue") == true && controller.catalogueError?.hasPrefix("catalogue.json can't be read:") == true,
               "error: \(String(describing: controller.catalogueError))")
    try expect(controller.rows.count == 1 && controller.rows[0].status == .upToDate && controller.phase == .idle, "rows after failed check")
}

check("catalogue: the real wiring never falls back to an empty catalogue") {
    let tmp = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
    let root = tmp + "/patched-cat-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/Apps/Foo.app/Contents", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let plist: [String: Any] = ["CFBundleIdentifier": "com.example.foo", "CFBundleName": "Foo", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: root + "/Apps/Foo.app/Contents/Info.plist"))
    let catalogue = URL(fileURLWithPath: root + "/catalogue.json")
    try Data("{ not json".utf8).write(to: catalogue)
    struct NoNetwork: HTTPFetching { func fetch(_ url: URL, maxBytes: Int) async throws -> Data { throw FetchError.transport("test") } }
    struct NoIndex: CaskIndexProviding { func index() async -> Result<CaskIndex, RefusalReason> { .failure(.network("test")) } }
    let controller = AppUpdatesController.live(catalogueURL: catalogue, applicationsRoot: root + "/Apps", fetcher: NoNetwork(),
                                               caskIndex: NoIndex(), installerLocations: .under(root + "/state"))
    await controller.refreshInstallerState()
    try expect(controller.catalogueError?.hasPrefix("catalogue.json can't be read:") == true && !controller.canCheck,
               "broken catalogue must pause checking: \(String(describing: controller.catalogueError))")
    controller.check(); await controller.waitUntilIdle()
    try expect(controller.rows.isEmpty && !controller.hasChecked, "a check ran against a broken catalogue")
    try Data(#"{"version":1,"apps":[]}"#.utf8).write(to: catalogue)
    await controller.refreshInstallerState()
    try expect(controller.catalogueError == nil && controller.canCheck, "valid catalogue should resume")
    controller.check(); await controller.waitUntilIdle()
    try expect(controller.rows.count == 1 && controller.rows[0].name == "Foo", "rows: \(controller.rows)")
}

check("fresh rescan: an app changed on disk after the check is not installed with the old outcome") {
    let a = app("Alpha"), b = app("Bravo")
    let installer = FakeInstaller()
    let world = World([outcome(a, .updateAvailable(offer("2.0"))), outcome(b, .updateAvailable(offer("2.0")))])
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0"))), outcome(b, .updateAvailable(offer("2.0")))],
                                    installer: installer, world: world)
    await runCheck(controller)
    // Another updater installs 2.0 over Alpha after our check.
    world.install(a.path, version: "2.0")
    await runOperation(controller) { controller.update(id: a.path) }
    try expect(eventsStarting(installer, "update").isEmpty, "installed with a stale outcome: \(installer.recorder.events)")
    let row = controller.rows.first { $0.name == "Alpha" }!
    try expect(row.status == .upToDate && row.installedVersion == "2.0" && row.result?.kind == .info, "row must show fresh state: \(row)")
    // Update All rechecks every item: Bravo changes to a non-installable source after the check.
    let cask = UpdateSource.homebrewCask(token: "bravo")
    world[b.path] = outcome(b, .updateAvailable(offer("2.0", source: cask)), source: cask, low: true)
    await runOperation(controller) { controller.updateAll() }
    try expect(eventsStarting(installer, "update").isEmpty, "update all installed a no-longer-installable app")
    try expect(controller.rows.first { $0.name == "Bravo" }!.status == .notInstallable, "Bravo row not refreshed")
}

check("fresh rescan: the installer receives the fresh outcome, not the cached one") {
    let a = app("Alpha")
    let installer = FakeInstaller()
    let world = World([outcome(a, .updateAvailable(offer("2.0")))])
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer, world: world)
    await runCheck(controller)
    world[a.path] = outcome(a, .updateAvailable(offer("2.5")))
    await runOperation(controller) { controller.update(id: a.path) }
    guard case .updateAvailable(let sent)? = installer.lastOutcome?.result else { throw CheckFailure(description: "installer not called") }
    try expect(sent.displayVersion == "2.5", "installer got \(sent.displayVersion)")
}

check("quit confirmation: update, then rollback, then confirming the old update is refused") {
    let a = app("Alpha")
    let installer = FakeInstaller()
    installer.backups = [try backup(a)]
    installer.updateHandler = { _, quit in
        if !quit { throw InstallRefusal.appRunning("Alpha is running") }
        return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
    }
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer)
    await runCheck(controller)
    await runOperation(controller) { controller.update(id: a.path) }
    try expect(controller.pendingQuit != nil, "confirmation expected")
    await runOperation(controller) { controller.rollBack(id: a.path) }
    try expect(controller.pendingQuit == nil, "a later action must void the confirmation")
    controller.confirmQuit(); await controller.waitUntilIdle()
    try expect(eventsStarting(installer, "update").allSatisfy { $0.hasSuffix("quit=false") }, "old update was confirmed after rollback: \(installer.recorder.events)")
}

check("quit confirmation: confirming re-checks eligibility, so a paused updater never acts on it") {
    let a = app("Alpha")
    let installer = FakeInstaller()
    installer.updateHandler = { _, quit in
        if !quit { throw InstallRefusal.appRunning("running") }
        return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
    }
    let broken = Counter()
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer,
                                    catalogue: { broken.value > 0 ? "unreadable" : nil })
    await runCheck(controller)
    await runOperation(controller) { controller.update(id: a.path) }
    try expect(controller.pendingQuit != nil, "confirmation expected")
    _ = broken.next()
    await controller.refreshInstallerState()
    controller.confirmQuit(); await controller.waitUntilIdle()
    try expect(!installer.recorder.events.contains { $0.hasSuffix("quit=true") }, "confirmed while the catalogue was unreadable")
}

check("quit confirmation: a new check voids it") {
    let a = app("Alpha")
    let installer = FakeInstaller()
    installer.updateHandler = { _, _ in throw InstallRefusal.appRunning("running") }
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer)
    await runCheck(controller)
    await runOperation(controller) { controller.update(id: a.path) }
    try expect(controller.pendingQuit != nil, "confirmation expected")
    controller.check()
    try expect(controller.pendingQuit == nil, "check left the confirmation alive")
    await controller.waitUntilIdle()
    controller.confirmQuit(); await controller.waitUntilIdle()
    try expect(!installer.recorder.events.contains { $0.hasSuffix("quit=true") }, "confirmed after a check")
}

check("quit confirmation: shown only once confirming can act, even when the state refresh is slow") {
    let a = app("Alpha")
    let installer = FakeInstaller()
    installer.updateHandler = { _, quit in
        if !quit { throw InstallRefusal.appRunning("running") }
        return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
    }
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer)
    await runCheck(controller)
    let gate = DispatchSemaphore(value: 0)
    installer.blockBackups = gate
    controller.update(id: a.path)
    for _ in 0..<300 where !installer.recorder.events.contains("backups-blocked") { try await Task.sleep(nanoseconds: 10_000_000) }
    try expect(installer.recorder.events.contains("backups-blocked"), "refresh never started")
    try expect(controller.isWorking && controller.pendingQuit == nil, "confirmation shown while the operation is still finishing")
    installer.blockBackups = nil
    gate.signal()
    await controller.waitUntilIdle()
    try expect(!controller.isWorking && controller.pendingQuit != nil, "confirmation missing after finalisation")
    controller.confirmQuit(); await controller.waitUntilIdle()
    try expect(installer.recorder.events.last(where: { $0.hasPrefix("update") }) == "update Alpha quit=true", "confirm did nothing: \(installer.recorder.events)")
}

check("recovery that restores an older version refreshes the row, or marks it for re-check") {
    let a = app("Alpha", version: "2.0"), b = app("Bravo", version: "2.0")
    let installer = FakeInstaller()
    let world = World([outcome(a, .upToDate), outcome(b, .upToDate)])
    let controller = makeController(outcomes: [outcome(a, .upToDate), outcome(b, .upToDate)], installer: installer, world: world)
    installer.unfinished = 2
    installer.recovery = AppRecoveryResult(entries: [.init(targetPath: a.path, result: .success(.reverted)),
                                                     .init(targetPath: b.path, result: .success(.reverted))])
    installer.onRecover = {
        // Recovery put 1.0 back on Alpha, where 2.0 is on offer; Bravo vanished.
        let old = InstalledApp(name: "Alpha", path: a.path, bundleID: a.bundleID, shortVersion: "1.0", build: "1.0")
        world[a.path] = AppCheckOutcome(app: old, teamID: "T", source: nil, lowConfidence: false, installable: true, result: .updateAvailable(offer("2.0")))
        world[b.path] = nil
    }
    await runCheck(controller)
    try expect(controller.rows.first { $0.name == "Alpha" }!.installedVersion == "2.0", "baseline")
    await runOperation(controller) { controller.recover() }
    let alpha = controller.rows.first { $0.name == "Alpha" }!, bravo = controller.rows.first { $0.name == "Bravo" }!
    try expect(alpha.installedVersion == "1.0" && alpha.status == .updateAvailable, "Alpha row is stale: \(alpha)")
    try expect(bravo.status == .needsRecheck && !controller.canUpdate(bravo) && !controller.canRollBack(bravo), "Bravo must need a re-check: \(bravo)")
}

check("unreadable journals pause updates and show the way out, even with no unfinished transaction") {
    let a = app("Alpha")
    let installer = FakeInstaller()
    let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer)
    await runCheck(controller)
    try expect(controller.canUpdate(controller.rows[0]), "baseline")
    installer.unreadable = ["/state/transactions/broken.json"]
    await controller.refreshInstallerState()
    try expect(controller.unfinishedCount == 0 && controller.unreadableJournals == ["/state/transactions/broken.json"], "journals: \(controller.unreadableJournals)")
    try expect(controller.installBlocked && !controller.canUpdate(controller.rows[0]) && !controller.canUpdateAll, "updates must be paused")
    controller.update(id: a.path); controller.updateAll(); await controller.waitUntilIdle()
    try expect(eventsStarting(installer, "update").isEmpty, "installer called while a journal is unreadable")
    let withBanner = try paint(controller, dark: false)
    installer.unreadable = []
    await controller.refreshInstallerState()
    try expect(controller.canUpdate(controller.rows[0]), "must resume")
    try expect(try paint(controller, dark: false) != withBanner, "the blocking banner is not painted")
}

check("the real installer reports unreadable journal files by full path") {
    let tmp = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
    let root = tmp + "/patched-journal-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let locations = InstallerLocations.under(root)
    try FileManager.default.createDirectory(atPath: locations.transactions, withIntermediateDirectories: true)
    let installer = UpdateInstaller(locations: locations)
    try expect(installer.unreadableJournalPaths().isEmpty && installer.unfinishedTransactionCount() == 0, "fresh state")
    try Data("garbage".utf8).write(to: URL(fileURLWithPath: locations.transactions + "/broken.json"))
    try expect(installer.unreadableJournalPaths() == [locations.transactions + "/broken.json"], "paths: \(installer.unreadableJournalPaths())")
    try expect(installer.unfinishedTransactionCount() == 0, "unreadable journal counted as unfinished")
}

// MARK: Wiring to the real scanner and installer, with temporary folders only

check("scan honours applicationsRoot and the real installer enforces installable") {
    let tmp = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
    let root = tmp + "/patched-app-updates-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/Foo.app/Contents", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let plist: [String: Any] = ["CFBundleIdentifier": "com.example.foo", "CFBundleName": "Foo", "CFBundleShortVersionString": "1.2", "CFBundleVersion": "12"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: root + "/Foo.app/Contents/Info.plist"))
    struct NoNetwork: HTTPFetching { func fetch(_ url: URL, maxBytes: Int) async throws -> Data { throw FetchError.transport("test") } }
    struct NoIndex: CaskIndexProviding { func index() async -> Result<CaskIndex, RefusalReason> { .failure(.network("test")) } }
    let installer = UpdateInstaller(locations: .under(root + "/.state"))
    let controller = AppUpdatesController(applicationsRoot: root, fetcher: NoNetwork(), caskIndex: NoIndex(), installer: installer)
    await runCheck(controller)
    try expect(controller.rows.count == 1 && controller.rows[0].name == "Foo" && controller.rows[0].path.hasSuffix("/Foo.app"), "rows: \(controller.rows.map(\.path))")
    try expect(controller.rows[0].installedVersion == "1.2 (12)" && controller.rows[0].status == .noSource, "row: \(controller.rows[0])")
    // The production installer refuses a non-installable outcome before touching anything.
    let blocked = outcome(app("Foo"), .updateAvailable(offer("2.0")), low: true)
    do { _ = try await installer.update(blocked, quitIfRunning: false); throw CheckFailure(description: "installer accepted a non-installable outcome") }
    catch let refusal as InstallRefusal { try expect(refusal.code == "not_installable", "refusal: \(refusal)") }
    try expect(installer.allBackups().isEmpty && installer.unfinishedTransactionCount() == 0, "fresh state should be empty")
}

// MARK: Offscreen render

@MainActor func paint(_ controller: AppUpdatesController, dark: Bool) throws -> Data {
    let app = NSApplication.shared
    if app.activationPolicy() != .prohibited { _ = app.setActivationPolicy(.prohibited) }
    let host = NSHostingView(rootView: AppUpdatesView(controller: controller)
        .frame(width: 720, height: 520).background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let deadline = Date().addingTimeInterval(0.2)
    while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure(description: "bitmap unavailable") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try expect(!window.isVisible && !app.isActive, "capture window became visible/active")
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(description: "png unavailable") }
    return png
}

check("offscreen: the Updates view paints rows, in light and dark, and is inert") {
    let installer = FakeInstaller()
    installer.unfinished = 1
    installer.backups = [try backup(app("Bravo"))]
    let outcomes = [outcome(app("Alpha"), .upToDate), outcome(app("Bravo"), .updateAvailable(offer("2.0"))),
                    outcome(app("Delta"), .updateAvailable(offer("4.0", format: .pkg))), outcome(app("Echo"), .noSource, noSource: true)]
    let controller = makeController(outcomes: outcomes, installer: installer)
    await runCheck(controller)
    let empty = makeController(outcomes: [], installer: FakeInstaller())
    let light = try paint(controller, dark: false), dark = try paint(controller, dark: true)
    let emptyLight = try paint(empty, dark: false)
    try expect(light.count > 5_000 && dark.count > 5_000, "renders look blank: \(light.count) \(dark.count)")
    try expect(light != dark, "light and dark renders are identical")
    try expect(light != emptyLight, "rows did not change the pixels")
    if let dir = ProcessInfo.processInfo.environment["PATCHED_APP_UPDATES_PNG_DIR"] {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try light.write(to: URL(fileURLWithPath: dir + "/updates-light.png")); try dark.write(to: URL(fileURLWithPath: dir + "/updates-dark.png"))
    }
    try expect(!installer.recorder.events.contains { $0.hasPrefix("update") || $0.hasPrefix("rollback") || $0.hasPrefix("recover") }, "painting must not act")
}

registerBackgroundCheckChecks()
registerAdminUpdateChecks()
registerUpdateAllEntryChecks()
registerAppStoreChecks()
registerMenuAndManualAdminChecks()
registerAppsListChecks()
registerNoSourceActionChecks()
registerSelfUpdateChecks()
registerProgressAndCancelChecks()

var failures = 0
for (name, action) in cases {
    do { try await action(); print("PASS app-updates: \(name)") }
    catch { failures += 1; print("FAIL app-updates: \(name): \(error)") }
}
print("App updates acceptance: \(cases.count) cases, \(failures) failures. Fakes and temporary folders only; no network, no real /Applications.")
exit(failures == 0 ? 0 : 1)
