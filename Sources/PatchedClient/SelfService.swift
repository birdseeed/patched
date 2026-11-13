import Foundation
import Combine
import UpdateSources
import UpdateInstaller

// Self Service: apps an organisation approved, delivered by MDM, that a standard user installs into ~/Applications.
// This is the state a view binds to. It shares the Updates controller's busy state, so a Self Service install, an
// update, Update All, an automatic run, a rollback and recovery never run at the same time.

// MARK: Seam

/// Installs one catalogue entry. The real one resolves the newest version (the first network use for the entry) and
/// runs `UpdateInstaller.installFromCatalogue`; checks inject a fake.
public protocol SelfServiceInstalling: Sendable {
    func install(_ entry: SelfServiceEntry, progress: UpdateProgressHandler?) async throws -> FreshInstallReport
}

/// An `UpdateInstaller` with a fixed destination folder and fetcher.
public struct UpdateInstallerSelfService: SelfServiceInstalling {
    public let installer: UpdateInstaller
    public let destinationRoot: String
    public let fetcher: any HTTPFetching
    public let environment: HostEnvironment
    public init(installer: UpdateInstaller, destinationRoot: String, fetcher: any HTTPFetching, environment: HostEnvironment = .current) {
        self.installer = installer; self.destinationRoot = destinationRoot; self.fetcher = fetcher; self.environment = environment
    }
    public func install(_ entry: SelfServiceEntry, progress: UpdateProgressHandler?) async throws -> FreshInstallReport {
        try await installer.installFromCatalogue(entry, into: destinationRoot, fetcher: fetcher, environment: environment, progress: progress)
    }
}

/// The live app's: state folders and ~/Applications are resolved on first use, never when the screen is built.
struct LiveSelfServiceInstaller: SelfServiceInstalling {
    let state: LazyState
    let fetcher: any HTTPFetching
    let destination: @Sendable () throws -> String
    func install(_ entry: SelfServiceEntry, progress: UpdateProgressHandler?) async throws -> FreshInstallReport {
        let root = try destination()
        let installer = UpdateInstaller(locations: try state.result.get(), selfServiceRoot: root)
        return try await installer.installFromCatalogue(entry, into: root, fetcher: fetcher, progress: progress)
    }
}

// MARK: Rows

public struct SelfServiceRow: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Valid, not installed, can be installed.
        case available
        /// Already in /Applications or ~/Applications; it is in Updates, not offered here.
        case installed
        /// Shown greyed, never installed.
        case needsAdmin
        /// The organisation's entry cannot be used; `reason` says why.
        case invalid(reason: String)
        /// Installing; nil until the download starts (the newest version is being looked up).
        case installing(UpdateProgress?)
        /// The last install failed; `reason` is the result text. Install can be tried again.
        case failed(reason: String)
        /// Installed just now.
        case done
    }

    public var id: String
    public let name: String
    public let description: String?
    public let category: String?
    /// Nil for an invalid entry.
    public let entry: SelfServiceEntry?
    public internal(set) var state: State
    /// Where the app is installed, when it is.
    public internal(set) var installedPath: String?
    /// The last install's result, in the same style as Updates.
    public internal(set) var result: AppUpdateRow.Result?
    public internal(set) var cancelRequested = false

    public static let needsAdminReason = String(localized: "needs admin rights")

    public var statusText: String {
        switch state {
        case .available: return String(localized: "Available")
        case .installed, .done: return String(localized: "Installed")
        case .needsAdmin: return String(localized: "Not available: \(Self.needsAdminReason)")
        case .invalid(let reason): return String(localized: "This catalogue entry is invalid. \(reason)")
        case .installing(let progress):
            if cancelRequested { return String(localized: "Cancelling…") }
            switch progress {
            case nil: return String(localized: "Looking up the latest version…")
            case .downloading(let received, let expected)?: return AppUpdateRow.downloadText(received: received, expected: expected)
            case .verifying?: return String(localized: "Verifying…")
            case .installing?: return String(localized: "Installing…")
            }
        case .failed(let reason): return reason
        }
    }

    /// Download progress from 0 to 1 when the size is known.
    public var downloadFraction: Double? {
        guard case .installing(.downloading(let received, let expected?)?) = state, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }
}

// MARK: Controller

@MainActor public final class SelfServiceController: ObservableObject {
    @Published public private(set) var rows: [SelfServiceRow] = []
    /// A catalogue is set on this Mac (valid or not).
    @Published public private(set) var isManaged = false
    /// Why the catalogue as a whole cannot be used, when it cannot.
    @Published public private(set) var catalogueProblem: String?
    @Published public private(set) var hasLoaded = false

    public static let notManagedText = String(localized: "Your organisation hasn't set up Self Service on this Mac.")

    private let updates: AppUpdatesController
    private let readCatalogue: @Sendable () -> SelfServiceCatalogue
    private let scanApps: AppUpdateScan
    private let teamID: TeamIDReader
    private let installer: any SelfServiceInstalling
    private var installTask: Task<FreshInstallReport, Error>?
    private var reloadTask: Task<Void, Never>?
    private var installingID: String?
    private var lastInstallSucceeded = false
    private var forward: AnyCancellable?

    /// `catalogue` reads the managed catalogue; `scan` lists installed apps (as for Updates); `teamID` reads an
    /// installed app's signing team. None of them may use the network.
    public init(updates: AppUpdatesController, catalogue: @escaping @Sendable () -> SelfServiceCatalogue,
                scan: @escaping AppUpdateScan, teamID: @escaping TeamIDReader, installer: any SelfServiceInstalling) {
        self.updates = updates; readCatalogue = catalogue; scanApps = scan; self.teamID = teamID; self.installer = installer
        // The busy state lives in the Updates controller; a view bound to this one should hear about it too.
        forward = updates.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The real app: the managed catalogue, /Applications and ~/Applications, and the Updates controller's state folders.
    /// The parameters exist so checks can point everything at temporary folders.
    public static func live(updates: AppUpdatesController, fetcher: any HTTPFetching = URLSessionFetcher(),
                            catalogue: @escaping @Sendable () -> SelfServiceCatalogue = { SelfServiceCatalogue.load() },
                            scanRoots: [String]? = nil, destinationRoot: String? = nil,
                            installerLocations: InstallerLocations? = nil) -> SelfServiceController {
        let state = installerLocations.map { LazyState(explicit: $0) } ?? updates.installerState ?? LazyState(explicit: nil)
        let installer = LiveSelfServiceInstaller(state: state, fetcher: fetcher,
                                                 destination: { try destinationRoot ?? SelfServiceDestination.standard() })
        let scan: AppUpdateScan = { @Sendable in
            let inventory = scanRoots.map { LocalApplicationInventory(scanningDirectories: $0) } ?? LocalApplicationInventory()
            return await inventory.scan().applications.map { AppUpdateScannedApp(app: InstalledApp(observation: $0), icon: $0.installedIcon) }
        }
        return SelfServiceController(updates: updates, catalogue: catalogue, scan: scan,
                                     teamID: { CodeSigningIdentity.teamID(ofBundleAt: URL(fileURLWithPath: $0)) }, installer: installer)
    }

    public func row(id: String) -> SelfServiceRow? { rows.first { $0.id == id } }

    /// Categories in the catalogue, sorted, for a filter.
    public var categories: [String] {
        Array(Set(rows.compactMap(\.category))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Something else is running or installing is paused: the same conditions that stop Update All.
    public var isBusy: Bool {
        updates.phase != .idle || updates.isWorking || updates.installBlocked || updates.selfInstall.isBusy
    }

    public func canInstall(_ row: SelfServiceRow) -> Bool {
        guard !isBusy, row.entry != nil else { return false }
        switch row.state {
        case .available, .failed: return true
        default: return false
        }
    }

    /// Cancel is offered while the newest version is looked up, downloaded or verified, never once installing has begun.
    public func canCancel(_ row: SelfServiceRow) -> Bool {
        guard row.id == installingID, !row.cancelRequested, case .installing(let progress) = row.state else { return false }
        switch progress {
        case nil, .downloading?, .verifying?: return true
        case .installing?: return false
        }
    }

    // MARK: Listing (no network)

    /// Reads the catalogue and the installed apps again. Touches no network.
    public func reload() async {
        let read = readCatalogue, scan = scanApps, team = teamID
        let found = await Task.detached { () -> (SelfServiceCatalogue, [String: String]) in
            let catalogue = read()
            guard !catalogue.items.isEmpty else { return (catalogue, [:]) }
            let apps = await scan().map(\.app)
            var installed: [String: String] = [:]
            for item in catalogue.items {
                if let entry = item.entry, let path = Self.installedPath(for: entry, in: apps, teamID: team) { installed[item.id] = path }
            }
            return (catalogue, installed)
        }.value
        apply(found.0, installed: found.1)
    }

    private func apply(_ catalogue: SelfServiceCatalogue, installed: [String: String]) {
        hasLoaded = true
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        switch catalogue {
        case .notManaged:
            isManaged = false; catalogueProblem = nil
        case .invalid(let reason):
            isManaged = true; catalogueProblem = reason
        case .items:
            isManaged = true; catalogueProblem = nil
        }
        rows = catalogue.items.map { item in
            let entry = item.entry
            var row = SelfServiceRow(id: item.id, name: item.name, description: entry?.description, category: entry?.category,
                                     entry: entry, state: .available)
            let old = previous[item.id]
            row.result = old?.result
            if item.id == installingID, let old {
                row.state = old.state; row.cancelRequested = old.cancelRequested
                return row
            }
            switch item.validity {
            case .invalid(let reason): row.state = .invalid(reason: reason)
            case .valid(let entry):
                if let path = installed[item.id] {
                    row.installedPath = path
                    row.state = old?.state == .done ? .done : .installed
                } else if entry.needsAdmin {
                    row.state = .needsAdmin
                } else if old?.state == .done {
                    // Installed just now, even if the scan cannot match it to the entry (a different name and no bundle ID).
                    row.state = .done; row.installedPath = old?.installedPath
                } else if case .failed(let reason)? = old?.state {
                    row.state = .failed(reason: reason)
                }
            }
            return row
        }
    }

    /// Installed means: an app signed by the entry's Team ID that has the entry's bundle ID or the entry's name. An app
    /// with the same bundle ID or name from another team does not count.
    nonisolated static func installedPath(for entry: SelfServiceEntry, in apps: [InstalledApp], teamID: TeamIDReader) -> String? {
        if let wanted = entry.bundleID,
           let match = apps.first(where: { $0.bundleID == wanted && teamID($0.path) == entry.teamID }) { return match.path }
        func named(_ app: InstalledApp) -> Bool {
            let file = (app.bundleFileName as NSString).deletingPathExtension
            return app.name.caseInsensitiveCompare(entry.name) == .orderedSame || file.caseInsensitiveCompare(entry.name) == .orderedSame
        }
        return apps.first { named($0) && teamID($0.path) == entry.teamID }?.path
    }

    // MARK: Install and cancel

    /// A click on Install. Refused (does nothing) while anything else installs, updates, rolls back or recovers.
    public func install(id: String) {
        guard let row = row(id: id), canInstall(row), let entry = row.entry else { return }
        installingID = id
        lastInstallSucceeded = false
        mutate(id) { $0.state = .installing(nil); $0.result = nil; $0.cancelRequested = false }
        updates.launch({ [weak self] in
            guard let self else { return }
            self.lastInstallSucceeded = await self.performInstall(id: id, entry: entry)
        }, then: { [weak self] in
            guard let self else { return }
            self.installingID = nil
            // The new app belongs in Updates now: check again so it appears there, then refresh this list.
            if self.lastInstallSucceeded { self.updates.check() }
            self.reloadTask = Task { [weak self] in await self?.reload() }
        })
    }

    /// Stops the install in progress before anything is moved into place. Nothing is left behind.
    public func cancel() {
        guard let id = installingID, let row = row(id: id), canCancel(row) else { return }
        mutate(id) { $0.cancelRequested = true }
        installTask?.cancel()
    }

    private func performInstall(id: String, entry: SelfServiceEntry) async -> Bool {
        // The catalogue and the disk again, just before installing: only an entry that is still listed and still not
        // installed is installed.
        let read = readCatalogue, scan = scanApps, team = teamID
        let (current, installedNow) = await Task.detached { () -> (SelfServiceCatalogue, String?) in
            let catalogue = read()
            guard catalogue.items.contains(where: { $0.id == id && $0.entry == entry }) else { return (catalogue, nil) }
            return (catalogue, Self.installedPath(for: entry, in: await scan().map(\.app), teamID: team))
        }.value
        guard current.items.contains(where: { $0.id == id && $0.entry == entry }) else {
            fail(id, String(localized: "\(entry.name): your organisation's catalogue changed, so nothing was installed."))
            return false
        }
        if let installedNow {
            mutate(id) {
                $0.state = .installed; $0.installedPath = installedNow
                $0.result = .init(kind: .info, text: String(localized: "\(entry.name) is already installed. It is in Updates."))
            }
            return false
        }
        if row(id: id)?.cancelRequested == true { cancelled(id, entry); return false }
        let installer = installer
        let progress: UpdateProgressHandler = { [weak self] step in
            Task { @MainActor in self?.applyProgress(step, to: id) }
        }
        let task = Task.detached { try await installer.install(entry, progress: progress) }
        installTask = task
        defer { installTask = nil }
        do {
            let report = try await task.value
            mutate(id) {
                $0.state = .done; $0.installedPath = report.path; $0.cancelRequested = false
                $0.result = .init(kind: .success, text: Self.reportText(name: entry.name, report))
            }
            return true
        } catch is CancellationError {
            cancelled(id, entry)
        } catch let refusal as InstallRefusal {
            fail(id, Self.refusalText(name: entry.name, refusal))
        } catch {
            fail(id, OutcomeText.line(name: entry.name, status: "refused", from: nil, to: nil, backupFolder: nil,
                                      reason: "internal_error", detail: "\(error)"))
        }
        return false
    }

    private func cancelled(_ id: String, _ entry: SelfServiceEntry) {
        mutate(id) {
            $0.state = .available; $0.cancelRequested = false
            $0.result = .init(kind: .info, text: String(localized: "Cancelled. \(entry.name) was not installed."))
        }
    }

    private func fail(_ id: String, _ text: String) {
        mutate(id) { $0.state = .failed(reason: text); $0.cancelRequested = false; $0.result = .init(kind: .failure, text: text) }
    }

    private func applyProgress(_ progress: UpdateProgress, to id: String) {
        func rank(_ p: UpdateProgress?) -> Int {
            switch p { case nil: return -1; case .downloading?: return 0; case .verifying?: return 1; case .installing?: return 2 }
        }
        mutate(id) { row in
            guard case .installing(let current) = row.state, rank(current) <= rank(progress) else { return }
            row.state = .installing(progress)
        }
    }

    private func mutate(_ id: String, _ change: (inout SelfServiceRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    // MARK: Text

    /// "Example: installed 2.0 (200) in /Users/me/Applications", in the Updates result style.
    @_spi(Testing) nonisolated public static func reportText(name: String, _ report: FreshInstallReport) -> String {
        OutcomeText.line(name: name, status: "installed_new", from: nil, to: report.version, backupFolder: report.folder,
                         reason: report.leftovers.isEmpty ? nil : "cleanup_incomplete",
                         detail: report.leftovers.isEmpty ? nil : "could not remove (use Recover): " + report.leftovers.joined(separator: ", "))
    }

    @_spi(Testing) nonisolated public static func refusalText(name: String, _ refusal: InstallRefusal) -> String {
        switch refusal {
        case .needsAdmin: return String(localized: "\(name) needs admin rights, so Self Service can't install it.")
        case .destinationExists: return String(localized: "\(name) is already in your Applications folder, so nothing was changed. Use Updates to keep it up to date.")
        case .unsupportedFormat: return String(localized: "\(name): this download format is not supported by Self Service.")
        default:
            return PlainRefusalText.text(name: name, refusal, installing: true)
        }
    }

    @_spi(Testing) public func waitUntilIdle() async {
        await updates.waitUntilIdle()
        await reloadTask?.value
        await updates.waitUntilIdle()
    }
}

// MARK: What the Available screen lists and offers

/// The one action a row shows: Install, Cancel (while it installs) or nothing.
public enum SelfServiceRowAction: Equatable, Sendable { case install, cancel, none }

extension SelfServiceController {
    /// The rows the Available screen lists: everything in the catalogue that is not already installed, narrowed by the
    /// search text (name, description or category) and, when one is chosen, the category. An app installed just now
    /// stays listed, so its result is not lost, until the next reload.
    public func visibleRows(search: String = "", category: String? = nil) -> [SelfServiceRow] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { row in
            if row.state == .installed { return false }
            if let category, row.category != category { return false }
            let text = [row.name, row.description, row.category].compactMap { $0 }.joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    /// Which button a row shows. An installing row shows only Cancel (and only while cancelling is possible); a row
    /// that cannot be installed (needs admin, invalid, installed) shows none. Whether Install is enabled is `canInstall`.
    public func action(for row: SelfServiceRow) -> SelfServiceRowAction {
        switch row.state {
        case .available, .failed: return row.entry == nil ? .none : .install
        case .installing: return canCancel(row) ? .cancel : .none
        case .installed, .done, .needsAdmin, .invalid: return .none
        }
    }

    /// How many apps can be installed now, for the summary line.
    public var installableCount: Int {
        rows.filter { row in
            switch row.state {
            case .available, .failed: return row.entry != nil
            default: return false
            }
        }.count
    }

    public var summaryText: String {
        let count = installableCount
        if catalogueProblem != nil && rows.isEmpty { return String(localized: "Self Service is unavailable.") }
        if rows.isEmpty { return String(localized: "No apps available.") }
        if count == 0 { return String(localized: "Nothing left to install.") }
        return count == 1 ? String(localized: "1 app available to install.") : String(localized: "\(count) apps available to install.")
    }

    /// What the list says when it has no rows to show, or nil when it has rows or the problem banner says enough.
    public func emptyStateText(search: String = "", category: String? = nil) -> String? {
        guard hasLoaded, visibleRows(search: search, category: category).isEmpty else { return nil }
        if rows.isEmpty {
            if catalogueProblem != nil { return nil }
            return isManaged ? Self.emptyCatalogueText : Self.notManagedText
        }
        return visibleRows().isEmpty ? Self.nothingLeftText : Self.noMatchText
    }

    @_spi(Testing) public static let installedHereText = String(localized: "Installed. Find it in Updates.")
    @_spi(Testing) public static let emptyCatalogueText = String(localized: "Your organisation hasn't added any apps yet.")
    @_spi(Testing) public static let nothingLeftText = String(localized: "Everything your organisation offers is already installed. Find your apps in Updates.")
    @_spi(Testing) public static let noMatchText = String(localized: "No apps match your search.")
}
