import Foundation
import SwiftUI
import AppKit
import PatchedShell
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

// The Self Service controller: rows and their states, the no-network listing rule, install, cancel, result text and the
// busy state it shares with Updates. Fakes and temporary folders only.

private let teamA = "AAAAAAAAAA", teamB = "BBBBBBBBBB"

private func entryDictionary(_ name: String, team: String = teamA, bundle: String? = nil, needsAdmin: Bool = false,
                             category: String? = nil) -> [String: Any] {
    var d: [String: Any] = ["Name": name, "TeamID": team, "SparkleFeedURL": "https://example.test/\(name.lowercased()).xml"]
    if let bundle { d["BundleID"] = bundle }
    if needsAdmin { d["NeedsAdmin"] = true }
    if let category { d["Category"] = category }
    return d
}

/// The catalogue and the installed apps, both changeable while a test runs.
private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var _catalogue: SelfServiceCatalogue
    private var _apps: [InstalledApp] = []
    private var _teams: [String: String] = [:]
    private(set) var catalogueReads = 0
    init(_ entries: [Any]) { _catalogue = SelfServiceCatalogue.parse(array: entries)! }
    var catalogue: SelfServiceCatalogue {
        get { lock.withLock { catalogueReads += 1; return _catalogue } }
        set { lock.withLock { _catalogue = newValue } }
    }
    func add(_ app: InstalledApp, team: String?) { lock.withLock { _apps.append(app); _teams[app.path] = team } }
    var apps: [InstalledApp] { lock.withLock { _apps } }
    func team(_ path: String) -> String? { lock.withLock { _teams[path] } }
}

private final class FakeSelfService: SelfServiceInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _installed: [String] = []
    var installed: [String] { lock.withLock { _installed } }
    var handler: @Sendable (SelfServiceEntry, UpdateProgressHandler?) async throws -> FreshInstallReport = { entry, _ in
        FreshInstallReport(appName: entry.name + ".app", bundleID: entry.bundleID ?? "com.example.x",
                           path: "/Users/test/Applications/\(entry.name).app", version: "2.0 (200)", folder: "/Users/test/Applications")
    }
    func install(_ entry: SelfServiceEntry, progress: UpdateProgressHandler?) async throws -> FreshInstallReport {
        lock.withLock { _installed.append(entry.name) }
        return try await handler(entry, progress)
    }
}

/// Opens once; everything waiting on it then continues.
private final class InstallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); continuation.resume() } else { waiters.append(continuation); lock.unlock() }
        }
    }
    func open() { lock.lock(); isOpen = true; let all = waiters; waiters = []; lock.unlock(); all.forEach { $0.resume() } }
}

private final class CountingFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var fetches: Int { lock.withLock { count } }
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        lock.withLock { count += 1 }
        throw FetchError.offline("test: no network")
    }
}

@MainActor private func rig(_ fixture: Fixture, installer: any SelfServiceInstalling = FakeSelfService(),
                            updates: AppUpdatesController? = nil) -> (SelfServiceController, AppUpdatesController) {
    let updates = updates ?? makeController(outcomes: [])
    let controller = SelfServiceController(updates: updates, catalogue: { fixture.catalogue },
                                           scan: { fixture.apps.map { AppUpdateScannedApp(app: $0, icon: nil) } },
                                           teamID: { fixture.team($0) }, installer: installer)
    return (controller, updates)
}

@MainActor private func eventually(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
    try expect(condition(), "timed out waiting for \(what)")
}

@MainActor func registerSelfServiceChecks() {
    check("self service: rows are available, installed, needs admin or invalid, and listing them uses no network") {
        let fixture = Fixture([
            entryDictionary("Alpha"),
            entryDictionary("Bravo", bundle: "com.example.bravo"),
            entryDictionary("Charlie"),
            entryDictionary("Delta"),
            entryDictionary("Echo", needsAdmin: true, category: "Tools"),
            entryDictionary("Foxtrot", team: "bad"),
            entryDictionary("Golf", bundle: "com.example.golf"),
        ])
        // Bravo by bundle ID (any name); Charlie by name and the pinned team; Delta has the name but another team.
        fixture.add(InstalledApp(name: "Something Else", path: "/Applications/Something Else.app", bundleID: "com.example.bravo", shortVersion: "1", build: "1"), team: teamA)
        // Golf's bundle ID, but signed by another team: not the catalogue's app, so Golf is still available.
        fixture.add(InstalledApp(name: "Impostor", path: "/Applications/Impostor.app", bundleID: "com.example.golf", shortVersion: "1", build: "1"), team: teamB)
        fixture.add(InstalledApp(name: "Charlie", path: "/Users/test/Applications/Charlie.app", bundleID: "com.example.c", shortVersion: "1", build: "1"), team: teamA)
        fixture.add(InstalledApp(name: "Delta", path: "/Applications/Delta.app", bundleID: "com.other.delta", shortVersion: "1", build: "1"), team: teamB)
        let fetcher = CountingFetcher()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("selfservice-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/home", withIntermediateDirectories: true)
        let real = UpdateInstallerSelfService(installer: UpdateInstaller(locations: .under(base + "/state")),
                                              destinationRoot: base + "/home/Applications", fetcher: fetcher)
        let (controller, _) = rig(fixture, installer: real)
        await controller.reload()
        try expect(controller.isManaged && controller.catalogueProblem == nil, "catalogue state")
        let states = controller.rows.map(\.state)
        try expect(states.count == 7, "\(states)")
        try expect(states[6] == .available, "an app with the bundle ID from another team counted as installed: \(states[6])")
        try expect(states[0] == .available && states[1] == .installed && states[2] == .installed && states[3] == .available
                   && states[4] == .needsAdmin, "\(states)")
        guard case .invalid(let reason) = states[5] else { throw CheckFailure(description: "Foxtrot: \(states[5])") }
        try expect(reason.contains("TeamID"), reason)
        try expect(controller.rows[1].installedPath == "/Applications/Something Else.app", "installed path")
        try expect(controller.rows[4].statusText == "Not available: needs admin rights", controller.rows[4].statusText)
        try expect(controller.rows[5].statusText.hasPrefix("This catalogue entry is invalid."), controller.rows[5].statusText)
        try expect(controller.categories == ["Tools"], "\(controller.categories)")
        try expect(controller.canInstall(controller.rows[0]) && !controller.canInstall(controller.rows[1])
                   && !controller.canInstall(controller.rows[4]) && !controller.canInstall(controller.rows[5]), "install offered wrongly")
        await controller.reload()
        try expect(fetcher.fetches == 0, "listing used the network \(fetcher.fetches) times")
        // Only Install reaches the network, and a feed that cannot be reached is a plain failure.
        controller.install(id: controller.rows[0].id)
        await controller.waitUntilIdle()
        try expect(fetcher.fetches == 1, "install fetched \(fetcher.fetches) times")
        guard case .failed(let text) = controller.rows[0].state else { throw CheckFailure(description: "\(controller.rows[0].state)") }
        try expect(text.hasPrefix("Alpha: refused [not_installable] not installable: could not find the latest version of Alpha"), text)
        try expect(!FileManager.default.fileExists(atPath: base + "/home/Applications"), "created ~/Applications without installing")
    }

    check("self service: no catalogue, and a catalogue that is not a list, are reported without rows") {
        let fixture = Fixture([])
        fixture.catalogue = .notManaged
        let (controller, _) = rig(fixture)
        await controller.reload()
        try expect(!controller.isManaged && controller.rows.isEmpty && controller.hasLoaded, "not managed")
        fixture.catalogue = .invalid(reason: SelfServiceCatalogue.invalidCatalogueReason)
        await controller.reload()
        try expect(controller.isManaged && controller.rows.isEmpty && controller.catalogueProblem == SelfServiceCatalogue.invalidCatalogueReason, "invalid")
        try expect(!SelfServiceCatalogue.invalidCatalogueReason.contains("\u{2014}") && !SelfServiceController.notManagedText.contains("\u{2014}"), "em dash")
    }

    check("self service: install succeeds with the Updates result style, then Updates checks again and the list refreshes") {
        let fixture = Fixture([entryDictionary("Alpha", bundle: "com.example.alpha")])
        let installer = FakeSelfService()
        let updates = makeController(outcomes: [])
        let (controller, _) = rig(fixture, installer: installer, updates: updates)
        await controller.reload()
        let id = controller.rows[0].id
        installer.handler = { entry, _ in
            fixture.add(InstalledApp(name: "Alpha", path: "/Users/test/Applications/Alpha.app", bundleID: "com.example.alpha", shortVersion: "2.0", build: "200"), team: teamA)
            return FreshInstallReport(appName: "Alpha.app", bundleID: "com.example.alpha", path: "/Users/test/Applications/Alpha.app",
                                      version: "2.0 (200)", folder: "/Users/test/Applications")
        }
        controller.install(id: id)
        await controller.waitUntilIdle()
        try expect(installer.installed == ["Alpha"], "\(installer.installed)")
        guard let row = controller.row(id: id) else { throw CheckFailure(description: "row gone") }
        try expect(row.state == .done && row.installedPath == "/Users/test/Applications/Alpha.app", "\(row.state)")
        try expect(row.result?.kind == .success && row.result?.text == "Alpha: installed 2.0 (200) in /Users/test/Applications", "\(String(describing: row.result))")
        try expect(updates.hasChecked, "Updates was not checked again after the install")
        try expect(!controller.canInstall(row), "install offered again")
    }

    check("self service: refused while anything else runs, and while it installs nothing else can start") {
        let fixture = Fixture([entryDictionary("Alpha"), entryDictionary("Bravo")])
        let gate = InstallGate()
        let installer = FakeSelfService()
        installer.handler = { entry, _ in
            await gate.wait()
            return FreshInstallReport(appName: "x.app", bundleID: "x.y", path: "/x.app", version: "1", folder: "/")
        }
        let upd = app("Upd")
        let updateInstaller = FakeInstaller()
        let updates = makeController(outcomes: [outcome(upd, .updateAvailable(offer("2.0")))], installer: updateInstaller)
        await runCheck(updates)
        let (controller, _) = rig(fixture, installer: installer, updates: updates)
        await controller.reload()
        let alpha = controller.rows[0].id, bravo = controller.rows[1].id

        // Self Service waits for an update that is running.
        let updateGate = InstallGate()
        updateInstaller.updateHandler = { _, _ in await updateGate.wait(); return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0") }
        updates.update(id: upd.path)
        try await eventually("the update to start") { updates.isWorking }
        try expect(!controller.canInstall(controller.rows[0]), "install offered during an update")
        controller.install(id: alpha)
        try expect(installer.installed.isEmpty && controller.rows[0].state == .available, "installed during an update")
        updateGate.open()
        await updates.waitUntilIdle()

        // And the other way round.
        controller.install(id: alpha)
        try await eventually("the install to start") { installer.installed == ["Alpha"] }
        try expect(updates.isWorking, "the shared busy state is not set")
        try expect(!updates.updateAll(), "Update All started during a Self Service install")
        updates.recover()
        try expect(!updateInstaller.recorder.events.contains { $0.hasPrefix("recover") }, "recovery started during an install")
        updates.check()
        try expect(updates.phase == .idle, "a check started during an install")
        controller.install(id: bravo)
        try expect(!controller.canInstall(controller.rows[1]), "a second install offered")
        gate.open()
        await controller.waitUntilIdle()
        try expect(installer.installed == ["Alpha"], "\(installer.installed)")
    }

    check("self service: cancel stops a download, leaves the row installable, and is not offered once installing") {
        let fixture = Fixture([entryDictionary("Alpha")])
        let installer = FakeSelfService()
        installer.handler = { _, progress in
            progress?(.downloading(received: 10, expected: 100))
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let (controller, updates) = rig(fixture, installer: installer)
        await controller.reload()
        let id = controller.rows[0].id
        controller.install(id: id)
        try await eventually("download progress") { controller.row(id: id)?.downloadFraction == 0.1 }
        try expect(controller.canCancel(controller.rows[0]), "cancel not offered while downloading")
        try expect(controller.rows[0].statusText.hasPrefix("Downloading"), controller.rows[0].statusText)
        controller.cancel()
        await controller.waitUntilIdle()
        let row = controller.rows[0]
        try expect(row.state == .available && row.result?.kind == .info && row.result?.text == "Cancelled. Alpha was not installed.", "\(row.state) \(String(describing: row.result))")
        try expect(controller.canInstall(row) && !updates.isWorking, "not installable again")

        let gate = InstallGate()
        installer.handler = { _, progress in
            progress?(.installing)
            await gate.wait()
            return FreshInstallReport(appName: "Alpha.app", bundleID: "a.b", path: "/a", version: "1", folder: "/")
        }
        controller.install(id: id)
        try await eventually("the commit point") { controller.row(id: id)?.state == .installing(.installing) }
        try expect(!controller.canCancel(controller.rows[0]), "cancel offered after the commit point")
        controller.cancel()
        gate.open()
        await controller.waitUntilIdle()
        try expect(controller.rows[0].state == .done, "\(controller.rows[0].state)")
    }

    check("self service: refusals read plainly, a needs-admin row never installs, and a changed catalogue installs nothing") {
        let fixture = Fixture([entryDictionary("Alpha"), entryDictionary("Echo", needsAdmin: true)])
        let installer = FakeSelfService()
        installer.handler = { _, _ in throw InstallRefusal.signatureInvalid("not signed by Team ID AAAAAAAAAA") }
        let (controller, _) = rig(fixture, installer: installer)
        await controller.reload()
        let alpha = controller.rows[0].id
        controller.install(id: alpha)
        await controller.waitUntilIdle()
        guard case .failed(let text) = controller.rows[0].state else { throw CheckFailure(description: "\(controller.rows[0].state)") }
        try expect(text == "Alpha: refused [signature_invalid] code signature check failed: not signed by Team ID AAAAAAAAAA", text)
        try expect(controller.canInstall(controller.rows[0]), "a failed install cannot be retried")
        try expect(SelfServiceController.refusalText(name: "Alpha", .destinationExists("x"))
                   == "Alpha is already in your Applications folder, so nothing was changed. Use Updates to keep it up to date.", "exists text")
        try expect(SelfServiceController.refusalText(name: "Alpha", .needsAdmin("x")) == "Alpha needs admin rights, so Self Service can't install it.", "admin text")
        for text in [SelfServiceController.refusalText(name: "A", .destinationExists("x")), SelfServiceController.refusalText(name: "A", .unsupportedFormat("pkg")),
                     controller.rows[1].statusText] {
            try expect(!text.contains("\u{2014}"), "em dash in \(text)")
        }

        controller.install(id: controller.rows[1].id)
        await controller.waitUntilIdle()
        try expect(installer.installed == ["Alpha"], "a needs-admin entry was installed: \(installer.installed)")

        // The organisation changes the entry between the listing and the click.
        fixture.catalogue = SelfServiceCatalogue.parse(array: [entryDictionary("Alpha", team: teamB)])!
        installer.handler = { _, _ in throw CheckFailure(description: "installed a changed entry") }
        controller.install(id: alpha)
        await controller.waitUntilIdle()
        try expect(installer.installed == ["Alpha"], "\(installer.installed)")
        try expect(controller.row(id: alpha) == nil || controller.row(id: alpha)?.result?.text.contains("catalogue changed") == true,
                   "\(String(describing: controller.row(id: alpha)))")
    }
}

// MARK: Available screen

private func ink(_ png: Data) throws -> (width: Int, height: Int, pixel: (Int, Int) -> (Int, Int, Int)) {
    guard let rep = NSBitmapImageRep(data: png) else { throw CheckFailure(description: "png unreadable") }
    return (rep.pixelsWide, rep.pixelsHigh, { x, y in
        let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        return (Int((c?.redComponent ?? 1) * 255), Int((c?.greenComponent ?? 1) * 255), Int((c?.blueComponent ?? 1) * 255))
    })
}

@MainActor func registerAvailableChecks() {
    check("available: search and the category filter narrow the rows; installed apps are not listed") {
        var alpha = entryDictionary("Alpha", category: "Tools"); alpha["Description"] = "Edits text files"
        var bravo = entryDictionary("Bravo", category: "Design"); bravo["Description"] = "Draws pictures"
        let fixture = Fixture([alpha, bravo, entryDictionary("Charlie", category: "Tools"), entryDictionary("Delta"),
                               entryDictionary("Echo", bundle: "com.example.echo", category: "Tools")])
        fixture.add(InstalledApp(name: "Echo", path: "/Applications/Echo.app", bundleID: "com.example.echo", shortVersion: "1", build: "1"), team: teamA)
        let (controller, _) = rig(fixture)
        await controller.reload()
        @MainActor func names(_ search: String = "", _ category: String? = nil) -> [String] { controller.visibleRows(search: search, category: category).map(\.name) }
        try expect(names() == ["Alpha", "Bravo", "Charlie", "Delta"], "installed app listed or rows missing: \(names())")
        try expect(controller.categories == ["Design", "Tools"], "\(controller.categories)")
        try expect(names("alp") == ["Alpha"] && names("ALPHA") == ["Alpha"], "name search \(names("alp"))")
        try expect(names("pictures") == ["Bravo"], "description search")
        try expect(names("design") == ["Bravo"], "category text search")
        try expect(names("text files tools") == ["Alpha"], "every word must match: \(names("text files tools"))")
        try expect(names("zzz").isEmpty, "no match")
        try expect(names("", "Tools") == ["Alpha", "Charlie"], "category: \(names("", "Tools"))")
        try expect(names("char", "Tools") == ["Charlie"] && names("bravo", "Tools").isEmpty, "search and category together")
        try expect(!names("", "Tools").contains("Delta"), "an entry with no category matched a category")
        try expect(controller.summaryText == "4 apps available to install.", controller.summaryText)
    }

    check("available: Install is disabled while the controller is busy; needs-admin and invalid rows offer no Install") {
        let fixture = Fixture([entryDictionary("Alpha"), entryDictionary("Bravo"), entryDictionary("Echo", needsAdmin: true), entryDictionary("Foxtrot", team: "bad")])
        let gate = InstallGate()
        let installer = FakeSelfService()
        installer.handler = { _, _ in
            await gate.wait()
            return FreshInstallReport(appName: "x.app", bundleID: "x.y", path: "/x.app", version: "1", folder: "/")
        }
        let (controller, _) = rig(fixture, installer: installer)
        await controller.reload()
        let rows = controller.visibleRows()
        try expect(rows.map(\.name) == ["Alpha", "Bravo", "Echo", "Foxtrot"], "\(rows.map(\.name))")
        try expect(controller.canInstall(rows[0]) && controller.canInstall(rows[1]), "Install not offered when idle")
        try expect(!controller.canInstall(rows[2]) && !controller.canInstall(rows[3]), "Install offered for a needs-admin or invalid row")
        try expect(controller.action(for: rows[0]) == .install && controller.action(for: rows[1]) == .install, "idle rows should show Install")
        try expect(controller.action(for: rows[2]) == .none && controller.action(for: rows[3]) == .none, "needs-admin or invalid row shows an action")
        try expect(rows[2].statusText == "Not available: needs admin rights" && rows[3].statusText.hasPrefix("This catalogue entry is invalid."), "reasons")
        controller.install(id: rows[0].id)
        try await eventually("the install to start") { if case .installing = controller.rows[0].state { return true } else { return false } }
        try expect(!controller.canInstall(controller.rows[1]) && controller.action(for: controller.rows[1]) == .install,
                   "another row still shows Install, disabled, while one installs")
        try expect(controller.action(for: controller.rows[0]) == .cancel, "an installing row must show only Cancel")
        try expect(controller.canCancel(controller.rows[0]) && !controller.canCancel(controller.rows[1]), "Cancel offered on the wrong row")
        gate.open()
        await controller.waitUntilIdle()
        try expect(controller.canInstall(controller.rows[1]), "Install not enabled again afterwards")
        try expect(controller.rows[0].state == .done && controller.action(for: controller.rows[0]) == .none, "a done row shows an action")
    }

    check("available: empty-state text follows isManaged, and installing rows are not counted as installable") {
        let fixture = Fixture([])
        fixture.catalogue = .notManaged
        let (controller, _) = rig(fixture)
        try expect(controller.emptyStateText() == nil, "text before the first load")
        await controller.reload()
        try expect(controller.emptyStateText() == SelfServiceController.notManagedText, "not managed: \(String(describing: controller.emptyStateText()))")
        fixture.catalogue = SelfServiceCatalogue.parse(array: [])!
        await controller.reload()
        try expect(controller.isManaged && controller.rows.isEmpty, "an empty managed catalogue must count as managed")
        try expect(controller.emptyStateText() == "Your organisation hasn't added any apps yet." && controller.summaryText == "No apps available.",
                   "empty catalogue: \(String(describing: controller.emptyStateText())) / \(controller.summaryText)")
        fixture.catalogue = .invalid(reason: SelfServiceCatalogue.invalidCatalogueReason)
        await controller.reload()
        try expect(controller.emptyStateText() == nil, "invalid catalogue repeats the banner")
        let gate = InstallGate()
        let installer = FakeSelfService()
        installer.handler = { _, _ in await gate.wait(); return FreshInstallReport(appName: "x.app", bundleID: "x.y", path: "/x.app", version: "1", folder: "/") }
        let (two, _) = rig(Fixture([entryDictionary("Alpha"), entryDictionary("Bravo")]), installer: installer)
        await two.reload()
        try expect(two.installableCount == 2 && two.emptyStateText(search: "zzz") == SelfServiceController.noMatchText, "counts")
        two.install(id: two.rows[0].id)
        try await eventually("install to start") { if case .installing = two.rows[0].state { return true } else { return false } }
        try expect(two.installableCount == 1 && two.summaryText == "1 app available to install.", "installing counted: \(two.summaryText)")
        gate.open()
        await two.waitUntilIdle()
        try expect(two.emptyStateText() == nil && two.installableCount == 1, "after install")
    }

    check("available: the sidebar lists Available only while a catalogue is managed, and the screen text has no em dash") {
        let fixture = Fixture([entryDictionary("Alpha")])
        fixture.catalogue = .notManaged
        let (controller, updates) = rig(fixture)
        let navigation = ShellNavigation(destination: .updates)
        let session = NativeClientSession(navigation: navigation, appUpdates: updates, selfService: controller)
        try expect(!navigation.availableShown && navigation.mainDestinations == [.updates, .applications], "listed with no catalogue at launch")
        await controller.reload()
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(!navigation.availableShown, "listed after reading no catalogue")
        fixture.catalogue = SelfServiceCatalogue.parse(array: [entryDictionary("Alpha")])!
        await session.reloadSelfService()
        try await eventually("Available to be listed") { navigation.availableShown }
        try expect(navigation.mainDestinations == [.updates, .available, .applications], "\(navigation.mainDestinations)")
        navigation.select(.available)
        fixture.catalogue = .invalid(reason: SelfServiceCatalogue.invalidCatalogueReason)
        await session.reloadSelfService()
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(navigation.availableShown && navigation.destination == .available, "an invalid catalogue must still show Available")
        fixture.catalogue = .notManaged
        await session.reloadSelfService()
        try await eventually("Available to be hidden again") { !navigation.availableShown }
        try expect(navigation.destination == .updates && navigation.mainDestinations == [.updates, .applications], "not back to Updates")
        let view = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/AvailableView.swift", encoding: .utf8)
        try expect(!view.contains("\u{2014}"), "em dash in AvailableView")
        try expect(!AvailableViewTexts.all.contains { $0.contains("\u{2014}") }, "em dash in screen text")
    }

    check("available: renders every row state within the window sizes without clipping; written when PATCHED_AVAILABLE_PNG is set") {
        var alpha = entryDictionary("Alpha Writer", bundle: "com.example.alpha", category: "Productivity")
        alpha["Description"] = "Write and edit documents."
        var bravo = entryDictionary("Bravo Browser With A Rather Long Name Indeed", category: "Internet")
        bravo["Description"] = "A web browser with a long description that has to wrap onto a second line without being cut off."
        func feed(_ d: [String: Any]) -> [String: Any] {
            var d = d; d["SparkleFeedURL"] = "https://example.test/" + UUID().uuidString + ".xml"; return d
        }
        let fixture = Fixture([feed(alpha), feed(bravo), feed(entryDictionary("Charlie Admin Tool", needsAdmin: true, category: "Utilities")),
                               entryDictionary("Delta", team: "bad"), feed(entryDictionary("Echo Notes", category: "Productivity")),
                               entryDictionary("Foxtrot", bundle: "com.example.foxtrot")])
        fixture.add(InstalledApp(name: "Foxtrot", path: "/Applications/Foxtrot.app", bundleID: "com.example.foxtrot", shortVersion: "1", build: "1"), team: teamA)
        let gate = InstallGate()
        let installer = FakeSelfService()
        installer.handler = { entry, progress in
            if entry.name.hasPrefix("Bravo") { progress?(.downloading(received: 40, expected: 100)); await gate.wait() }
            return FreshInstallReport(appName: entry.name + ".app", bundleID: "x.y", path: "/Users/test/Applications/\(entry.name).app",
                                      version: "2.0 (200)", folder: "/Users/test/Applications")
        }
        let (controller, _) = rig(fixture, installer: installer)
        await controller.reload()
        controller.install(id: controller.rows[4].id)   // Echo Notes: installed just now
        await controller.waitUntilIdle()
        controller.install(id: controller.rows[1].id)   // Bravo: stays at 40%
        for _ in 0..<400 where controller.rows[1].downloadFraction != 0.4 { try await Task.sleep(nanoseconds: 5_000_000) }
        try expect(controller.rows[1].downloadFraction == 0.4, "no 40% progress: \(controller.rows.map(\.state))")

        defer { gate.open() }
        let empty = rig(Fixture([])).0
        let idle = rig(Fixture([feed(entryDictionary("Alpha Writer", category: "Productivity")), feed(entryDictionary("Echo Notes"))])).0
        await idle.reload()
        for (width, height) in [(500, 520), (820, 560)] {
            let light = try paintView(AvailableView(controller: controller), width: CGFloat(width), height: CGFloat(height))
            let dark = try paintView(AvailableView(controller: controller), width: CGFloat(width), height: CGFloat(height), dark: true)
            let blank = try paintView(AvailableView(controller: empty), width: CGFloat(width), height: CGFloat(height))
            try expect(light.count > 5_000 && light != dark && light != blank, "renders look wrong at \(width)")
            // Nothing is drawn in the outer margin (the view pads 20 points), so no row runs off either edge.
            let image = try ink(light)
            let scale = max(1, image.width / width)
            for y in stride(from: 0, to: image.height, by: 3) {
                for x in list(from: image.width - 6 * scale, to: image.width) + list(from: 0, to: 6 * scale) {
                    let (r, g, b) = image.pixel(x, y)
                    try expect(r > 235 && g > 235 && b > 235, "content reaches the window edge at \(width) (x \(x), y \(y))")
                }
            }
            // With nothing running, the Install buttons sit in the right-hand column, inside the margin.
            let idleImage = try ink(try paintView(AvailableView(controller: idle), width: CGFloat(width), height: CGFloat(height)))
            var buttonInk = 0
            for y in stride(from: 0, to: idleImage.height, by: 2) {
                for x in stride(from: idleImage.width - 90 * scale, to: idleImage.width - 6 * scale, by: 2) {
                    let (r, g, b) = idleImage.pixel(x, y)
                    if r < 200 || g < 200 || b < 200 { buttonInk += 1 }
                }
            }
            try expect(buttonInk > 40, "no Install button in the right-hand column at \(width) (\(buttonInk))")
            if width == 820, let path = ProcessInfo.processInfo.environment["PATCHED_AVAILABLE_PNG"] {
                try light.write(to: URL(fileURLWithPath: path))
            }
        }
        try expect(installer.installed == ["Echo Notes", "Bravo Browser With A Rather Long Name Indeed"], "painting acted: \(installer.installed)")
    }
}

private func list(from: Int, to: Int) -> [Int] { Array(from..<to) }

@MainActor enum AvailableViewTexts {
    static var all: [String] {
        [SelfServiceController.notManagedText, SelfServiceController.nothingLeftText, SelfServiceController.noMatchText,
         SelfServiceController.installedHereText, SelfServiceRow.needsAdminReason]
    }
}
