import Foundation
import Combine
import UpdateSources
import UpdateInstaller

// MARK: Seams

/// The installer operations the Updates screen uses. `UpdateInstaller` is the production conformance;
/// tests inject a fake. `update` always goes through the installable-enforcing `update(_:options:)`.
public protocol AppUpdateInstalling: Sendable {
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool) async throws -> AppUpdateReport
    func rollBack(appAt path: String, quitIfRunning: Bool) async throws -> AppUpdateReport
    func recoverUnfinished(quitIfRunning: Bool) async -> AppRecoveryResult
    func allBackups() -> [BackupRecord]
    func unfinishedTransactionCount() -> Int
    /// Journal files that could not be read. The installer refuses every update while one exists.
    func unreadableJournalPaths() -> [String]
    /// The experimental admin path. `admin` is passed only for an explicit click on a row that needs it;
    /// it is ignored unless admin updates are switched on in the installer.
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport
    func rollBack(appAt path: String, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport
}

extension AppUpdateInstalling {
    /// Installers without an admin path simply never use one.
    public func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport {
        try await update(outcome, quitIfRunning: quitIfRunning)
    }
    public func rollBack(appAt path: String, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport {
        try await rollBack(appAt: path, quitIfRunning: quitIfRunning)
    }
}

/// Plain values mirroring `InstallReport`, so fakes can be built without the installer's internal initialisers.
public struct AppUpdateReport: Sendable, Equatable {
    /// `installed`, `dry_run_passed` or `rolled_back`, as `OutcomeText` expects.
    public let status: String
    public let fromVersion: String
    public let toVersion: String
    public let backupFolder: String?
    public let leftovers: [String]
    /// Set by the experimental admin path, for example "installed with admin rights".
    public let note: String?
    public init(status: String, fromVersion: String, toVersion: String, backupFolder: String? = nil, leftovers: [String] = [],
                note: String? = nil) {
        self.status = status; self.fromVersion = fromVersion; self.toVersion = toVersion
        self.backupFolder = backupFolder; self.leftovers = leftovers; self.note = note
    }
    init(_ report: InstallReport) {
        self.init(status: report.status.rawValue, fromVersion: report.fromVersion, toVersion: report.toVersion,
                  backupFolder: report.backupFolder, leftovers: report.leftovers, note: report.note)
    }
}

public struct AppRecoveryResult: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let targetPath: String
        public let result: Result<RecoveryOutcome, InstallRefusal>
        public let leftovers: [String]
        public init(targetPath: String, result: Result<RecoveryOutcome, InstallRefusal>, leftovers: [String] = []) {
            self.targetPath = targetPath; self.result = result; self.leftovers = leftovers
        }
    }
    public let entries: [Entry]
    public let unreadable: [String]
    public init(entries: [Entry], unreadable: [String] = []) { self.entries = entries; self.unreadable = unreadable }
}

extension UpdateInstaller: AppUpdateInstalling {
    public func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool) async throws -> AppUpdateReport {
        try await update(outcome, quitIfRunning: quitIfRunning, admin: nil)
    }
    public func rollBack(appAt path: String, quitIfRunning: Bool) async throws -> AppUpdateReport {
        try await rollBack(appAt: path, quitIfRunning: quitIfRunning, admin: nil)
    }
    public func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport {
        // The installable-enforcing API; the installer refuses anything not installable.
        AppUpdateReport(try await update(outcome, options: UpdateOptions(quitIfRunning: quitIfRunning, dryRun: false), admin: admin))
    }
    public func rollBack(appAt path: String, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport {
        AppUpdateReport(try await rollback(appAt: path, quitIfRunning: quitIfRunning, admin: admin))
    }
    public func recoverUnfinished(quitIfRunning: Bool) async -> AppRecoveryResult {
        let result = await recover(quitIfRunning: quitIfRunning)
        return AppRecoveryResult(entries: result.reports.map {
            .init(targetPath: $0.targetPath, result: $0.result, leftovers: $0.leftovers)
        }, unreadable: result.unreadable)
    }
    public func allBackups() -> [BackupRecord] { backups(bundleID: nil) }
    public func unfinishedTransactionCount() -> Int { JournalStore(directory: locations.transactions).unfinished().count }
}

/// One installed app as scanned: what the checker needs, plus the display icon.
public struct AppUpdateScannedApp: Sendable {
    public let app: InstalledApp
    public let icon: LocalInstalledIcon?
    public init(app: InstalledApp, icon: LocalInstalledIcon?) { self.app = app; self.icon = icon }
}

public typealias AppUpdateScan = @Sendable () async -> [AppUpdateScannedApp]
/// Throws when the check cannot be made at all (for example the catalogue file is unreadable).
public typealias AppUpdateCheck = @Sendable ([InstalledApp]) async throws -> [AppCheckOutcome]
/// Rescans one app on disk and checks it afresh; nil when it is no longer there. Used immediately
/// before an install, and after anything that changes an app.
public typealias AppUpdateRecheck = @Sendable (String) async throws -> AppCheckOutcome?
/// Reads the catalogue; returns why it cannot be used, or nil when it is fine.
public typealias AppUpdateCatalogueProbe = @Sendable () -> String?
/// Adds (`ignored` true) or removes the catalogue's ignore entry for a bundle ID. Throws a `CatalogueError` with a
/// message for the user when the catalogue cannot be changed safely.
public typealias AppUpdateCatalogueEdit = @Sendable (_ bundleID: String, _ ignored: Bool) throws -> Void

extension InstalledApp {
    /// The one mapping from an inventory observation, shared by the app and the command line.
    public init(observation app: LocalApplicationObservation) {
        self.init(name: app.displayName, path: app.path, bundleID: app.claimedBundleIdentifier,
                  shortVersion: app.claimedShortVersion, build: app.claimedBuild,
                  sparkleFeed: app.vendorMetadata.sparkleFeedURL,
                  sparkleFeedRejected: app.vendorMetadata.sparkleFeedURL == nil && app.vendorMetadata.sparkleDisposition == .malformed,
                  electronConfig: app.vendorMetadata.electronConfigBytes,
                  isAppStore: FileManager.default.fileExists(atPath: app.path + "/Contents/_MASReceipt"),
                  isWrappedIOSApp: app.isWrappedIOSApp,
                  sparklePublicEDKey: app.vendorMetadata.sparklePublicEDKey)
    }
}

// MARK: Row model

public struct AppUpdateRow: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case pending
        case upToDate
        case updateAvailable
        /// An update exists but the source is not confirmed (for example a filename-only Homebrew match).
        case notInstallable
        case packageUnsupported
        case noSource
        /// An update exists but the Mac App Store owns installing it. Patched only points the user there.
        case appStoreUpdate
        case refused(String)
        /// A rollback changed the installed version; a fresh check is needed.
        case needsRecheck
    }
    public enum Activity: Equatable, Sendable { case idle, checking, updating, rollingBack }
    /// How an update would be installed. Anything but `standard` exists only with admin updates switched on.
    public enum Privilege: Equatable, Sendable {
        case standard
        /// The app needs admin rights to replace; macOS asks once for this update.
        case admin
        /// A `.pkg` handed to Apple's Installer.
        case installer
    }
    public enum ResultKind: Equatable, Sendable { case success, info, failure }
    public struct Result: Equatable, Sendable {
        public let kind: ResultKind
        public let text: String
    }

    public var id: String { path }
    public let name: String
    public let path: String
    public let bundleID: String?
    public let icon: LocalInstalledIcon?
    public internal(set) var installedVersion: String
    public internal(set) var latestVersion: String?
    /// The installed display version alone (no build), for compact places such as the menu. nil after an
    /// install until the next check, when `installedVersion` is shown instead.
    public internal(set) var installedDisplayVersion: String?
    /// Source kind, with "?" appended for a low-confidence match.
    public let source: String
    public internal(set) var status: Status
    public internal(set) var activity: Activity
    public internal(set) var result: Result?
    /// Version a rollback would restore, when a backup exists.
    public internal(set) var rollbackVersion: String?
    public internal(set) var privilege: Privilege = .standard
    /// The app needs admin rights to replace and the experimental admin path is off, so Patched cannot update
    /// it. The row offers "Open <app>" instead of Update, for the app's own updater.
    public internal(set) var needsManualAdmin = false
    internal var outcome: AppCheckOutcome?
    /// Set only on Patched's own row when a newer Patched release has been announced. Notify-only: the row
    /// stays a no-source row, so it is never installable and never part of Update All.
    public internal(set) var selfUpdateVersion: String?

    public var hasUpdate: Bool { status == .updateAvailable }
    /// An App Store update: shown with Open in App Store, never installed by Patched.
    public var isAppStoreUpdate: Bool { status == .appStoreUpdate }
    /// An App Store app whose status Patched could not confirm (the public lookup lacks it or lists another version).
    public var isAppStoreUnconfirmed: Bool { status == .noSource && outcome?.noSourceReason == .appStoreNotListed }
    /// Rows that offer Open in App Store: Patched only opens the App Store, it never installs these apps.
    public var canOpenInAppStore: Bool { isAppStoreUpdate || isAppStoreUnconfirmed }
    /// The user's catalogue says to ignore this app: nothing is looked up for it and it is not listed under Updates.
    public var isIgnored: Bool { status == .noSource && outcome?.noSourceReason == .ignored }
    /// The row's Update button.
    public var updateActionTitle: String {
        switch privilege {
        case .standard: return "Update"
        case .admin: return "Update (admin)"
        case .installer: return "Update (installer)"
        }
    }
    public var canRollBack: Bool { rollbackVersion != nil }
    /// "1.0 → 2.0" when a different version is on offer, else the installed version.
    public var versionChange: String {
        if let latest = latestVersion, latest != installedVersion { return installedVersion + " → " + latest }
        return installedVersion
    }
    /// Short note for lists where the row is not a plain installable update.
    public var kindNote: String? {
        if isAppStoreUpdate { return "App Store" }
        if status == .packageUnsupported { return "Installer package" }
        if status == .notInstallable {
            switch outcome?.edSignatureBlock {
            case .keyMalformed?: return "Bad key"
            case .signatureMissing?, .signatureMalformed?: return "Unsigned"
            case nil: return "Unconfirmed"
            }
        }
        if needsManualAdmin || privilege == .admin { return "Needs admin" }
        return nil
    }
    public var openAppActionTitle: String { "Open " + name }
    public static let needsAdminCaption = "Needs admin rights. Open the app and use its own updater."

    public var statusText: String {
        switch status {
        case .pending: return "Checking…"
        case .upToDate: return "Up to date"
        case .updateAvailable:
            switch privilege {
            case .standard: return "Update available"
            case .admin: return "Update available. Needs admin rights: macOS asks for your password for this update."
            case .installer: return "Update available as an installer package. Apple's Installer will open and ask for your password."
            }
        case .notInstallable:
            if let block = outcome?.edSignatureBlock { return block.message }
            if case .homebrewCask? = outcome?.source, outcome?.lowConfidence == true {
                return "Homebrew (unconfirmed) — add a catalogue entry to enable updates"
            }
            return "Update found, but the source isn't confirmed. Add a catalogue entry to enable updates."
        case .packageUnsupported: return "Installer packages not supported yet"
        case .appStoreUpdate: return "Update in the App Store"
        case .noSource:
            if let selfUpdateVersion, outcome?.noSourceReason == .thisApp { return "Update to " + selfUpdateVersion }
            return outcome?.noSourceReason?.rowLabel ?? "No update source"
        case .refused(let message): return "Can't check: " + message
        case .needsRecheck: return "Check again to refresh."
        }
    }
}

extension NoSourceReason {
    /// The row's status line for an app with no update source.
    var rowLabel: String {
        switch self {
        case .noPublicFeed: return "No public update feed"
        case .appStoreNotListed: return "Updates through the App Store"
        case .ignored: return "Ignored"
        case .thisApp: return "This app"
        }
    }
}

/// A newer Patched release, validated by `PatchedReleaseChecker`. Shown in the menu, the Updates view and
/// Patched's own row; "Download" opens `url` (the release page) on a click and does nothing else.
public struct SelfUpdate: Equatable, Sendable {
    public let version: String
    public let url: URL
    public init(version: String, url: URL) { self.version = version; self.url = url }
    public var text: String { "Patched \(version) is available" }
    /// Identity for "have I told the user about this" (one notification per new version).
    @_spi(Testing) public var key: String { "im.patched.self-update\u{1F}" + version }
}

/// One lookup of Patched's own latest release. At most one request per call.
public typealias SelfUpdateCheck = @Sendable () async -> PatchedReleaseResult

public struct AppUpdateQuitConfirmation: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case update, rollback, recover }
    public let path: String
    public let action: Action
    public let message: String
    /// The controller state this confirmation was raised in; any later check, action or row change voids it.
    let epoch: Int
    let installedVersion: String?
}

/// Progress of an Update All run: apps finished, apps in the run, and whether Stop was chosen.
public struct UpdateAllProgress: Equatable, Sendable {
    public var done: Int
    public let total: Int
    public var stopping: Bool
    public var text: String {
        stopping ? "Stopping after this app…" : "Updating \(min(done + 1, total)) of \(total)…"
    }
}

/// What an Update All run did. The summary notification is built from this.
public struct UpdateAllSummary: Equatable, Sendable {
    public let updated: Int, failed: Int, skippedOpen: Int, needsAdmin: Int, stopped: Int
    /// App Store updates Patched pointed the user to by opening the App Store (it never installs them).
    public let appStore: Int
    /// App Store updates on offer when the App Store could not be opened at all.
    public let appStoreFailed: Int
    /// Scoped runs only: apps whose offer, on recheck, was no longer the one the notification advertised.
    public let changed: Int
    public init(updated: Int, failed: Int, skippedOpen: Int, needsAdmin: Int, stopped: Int = 0, changed: Int = 0,
                appStore: Int = 0, appStoreFailed: Int = 0) {
        self.updated = updated; self.failed = failed; self.skippedOpen = skippedOpen
        self.needsAdmin = needsAdmin; self.stopped = stopped; self.changed = changed; self.appStore = appStore
        self.appStoreFailed = appStoreFailed
    }
    private static func apps(_ n: Int) -> String { n == 1 ? "1 app" : "\(n) apps" }
    /// "Updated 3 apps; 1 skipped because it is open; 1 needs admin"
    public var text: String {
        let onlyAppStore = appStore + appStoreFailed > 0 && updated == 0 && failed == 0 && skippedOpen == 0 && needsAdmin == 0
            && stopped == 0 && changed == 0
        var parts = onlyAppStore ? [] : ["Updated \(Self.apps(updated))"]
        if failed > 0 { parts.append("\(failed) failed") }
        if skippedOpen > 0 { parts.append("\(skippedOpen) skipped because \(skippedOpen == 1 ? "it is" : "they are") open") }
        if needsAdmin > 0 { parts.append("\(needsAdmin) need\(needsAdmin == 1 ? "s" : "") admin") }
        if changed > 0 { parts.append("\(changed) changed since the notification, not installed") }
        if stopped > 0 { parts.append("\(stopped) not attempted after Stop") }
        if appStore > 0 { parts.append("\(appStore) to update in the App Store") }
        if appStoreFailed > 0 { parts.append("couldn't open the App Store for \(appStoreFailed)") }
        return parts.joined(separator: "; ")
    }
}

/// An Update All request that arrived while no check result was ready to act on.
struct QueuedUpdateAll {
    let keys: Set<String>?
    let onFinished: (@MainActor (UpdateAllSummary) -> Void)?
    /// Called when the request is abandoned without running (check failed or cancelled, or nothing in scope).
    let onDropped: (@MainActor () -> Void)?
}

public enum AppUpdatesPhase: Equatable, Sendable { case idle, checking }

/// Shown while Apple's Installer is open for a `.pkg` update (experimental admin path).
public struct AppUpdateInstallerWait: Equatable, Sendable {
    public let path: String
    public let name: String
    public let message: String
}

/// How a check ended, reported to the background scheduler (which only ever notifies).
enum AppCheckRunOutcome: Equatable { case succeeded, failed, cancelled }

// MARK: Controller

/// Runs the same pipeline as the command line (scan, check, install) behind the Updates screen.
/// Construction does no work. Checks run off the main actor, one at a time; installs, rollbacks and
/// recovery run one at a time too. Updates always go through the installer's installable-enforcing API
/// using a fresh rescan of the one app, and a running app is only ever asked to quit after an explicit
/// confirmation.
@MainActor public final class AppUpdatesController: ObservableObject {
    @Published public private(set) var phase: AppUpdatesPhase = .idle
    @Published public private(set) var rows: [AppUpdateRow] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var hasChecked = false
    /// When the last check finished successfully (this session). For the menu's "Up to date" line.
    @Published public private(set) var lastCheckedAt: Date?
    /// Where rows and the menu get app icons. Tests replace it with a fake.
    public var iconProvider: AppIconProviding = WorkspaceAppIconProvider.shared
    /// A row the menu asked the Updates window to bring into view. Cleared by the view once shown.
    @Published public var focusedRowID: String?
    /// Bumped on every menu selection, so picking the same app again still scrolls back to it.
    @Published public private(set) var focusRequest = 0
    public func focus(rowID: String) { focusedRowID = rowID; focusRequest &+= 1 }
    @Published public private(set) var summary: String = "Choose Check for Updates to look for newer versions."
    @Published public private(set) var notice: String?
    @Published public private(set) var catalogueError: String?
    /// The last Ignore or Stop ignoring failure, shown on both Updates and Applications (the row it belongs to
    /// may be hidden once ignored). Cleared by the next successful edit or by dismissing it.
    @Published public private(set) var ignoreEditFailure: String?
    public func dismissIgnoreEditFailure() { ignoreEditFailure = nil }
    /// Reports why the state folders are unusable, once they have been resolved (nil before, and when fine).
    var setupProbe: @Sendable () -> String? = { nil }
    @Published public private(set) var unfinishedCount = 0
    @Published public private(set) var unreadableJournals: [String] = []
    @Published public private(set) var recoveryMessage: String?
    /// Set only while an Update All run is in progress (from any entry point).
    @Published public private(set) var updateAllProgress: UpdateAllProgress?
    /// How many times `updateAll()` was called, accepted or not. For tests of the entry points.
    @_spi(Testing) public private(set) var updateAllInvocations = 0
    /// An Update All request is waiting for a running (or first) check to succeed. Cleared by Cancel in the
    /// menu, by `cancelCheck()`, and by any check that does not succeed.
    @Published public private(set) var updateAllQueued = false
    private var queuedUpdateAll: QueuedUpdateAll?
    @Published public private(set) var pendingQuit: AppUpdateQuitConfirmation?
    /// Apple's Installer is open; the view shows "Finish the installation in Apple's Installer, then press Done".
    @Published public private(set) var installerWait: AppUpdateInstallerWait?
    /// Experimental privileged replacement of root-owned apps (PATCHED_ENABLE_ADMIN_UPDATES=1). Off: as before.
    /// Known not to work for ad-hoc-signed builds (macOS refuses the replacement with EIO).
    public let adminUpdatesEnabled: Bool
    /// Experimental `.pkg` updates through Apple's Installer (PATCHED_ENABLE_PKG_UPDATES=1). Off: as before.
    public let packageUpdatesEnabled: Bool

    /// A newer Patched release, when one was found by the last check that could tell. Notify-only.
    @Published public private(set) var selfUpdate: SelfUpdate?
    /// Looks up Patched's own latest release, once per check, alongside the app checks. nil: no lookup.
    /// Only `live()` sets a real one; fixtures and tests keep nil or a fake.
    @_spi(Testing) public var selfUpdateCheck: SelfUpdateCheck?
    /// How long the lookup may take before it counts as unavailable.
    @_spi(Testing) public var selfLookupTimeout: TimeInterval = 15
    /// True from the start of a check until its lookup has answered (or the check ended without using it).
    @Published public private(set) var selfLookupPending = false
    private var selfApplyTask: Task<Void, Never>?
    /// Called when a lookup of the current check has been applied. Used by the background scheduler.
    var onSelfLookupFinished: (() -> Void)?
    private let scanApps: AppUpdateScan
    private let checkApps: AppUpdateCheck
    private let recheckApp: AppUpdateRecheck
    private let probeCatalogue: AppUpdateCatalogueProbe
    private let editCatalogue: AppUpdateCatalogueEdit?
    private let installer: any AppUpdateInstalling
    private var checkTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var epoch = 0
    private var deferredQuit: AppUpdateQuitConfirmation?
    private var rowsBeforeCheck: [AppUpdateRow] = []
    private var stopRequested = false
    /// Apps that refused with needs_admin; their rows offer "Update (admin)" from then on.
    private var needsAdminPaths: Set<String> = []
    /// The one admin action in progress, so Done can reach it.
    private var currentAdmin: AdminInteraction?
    private var adminToken: UUID?
    /// Opens the App Store (Open in App Store, Update All). Only an explicit click reaches it; the scheduler never
    /// does. Nothing opens unless a production opener is set (`live()` sets one; fixtures keep the inert default).
    @_spi(Testing) public var urlOpener: any ExternalURLOpening = InertURLOpener()
    /// Called once after every check ends, however it was started. Used by the background scheduler.
    var onCheckFinished: ((AppCheckRunOutcome) -> Void)?

    public init(scan: @escaping AppUpdateScan, check: @escaping AppUpdateCheck, recheck: @escaping AppUpdateRecheck,
                catalogue: @escaping AppUpdateCatalogueProbe = { nil }, editCatalogue: AppUpdateCatalogueEdit? = nil,
                installer: any AppUpdateInstalling, adminUpdates: Bool = false, packageUpdates: Bool = false) {
        scanApps = scan; checkApps = check; recheckApp = recheck; probeCatalogue = catalogue; self.installer = installer
        self.editCatalogue = editCatalogue
        adminUpdatesEnabled = adminUpdates
        packageUpdatesEnabled = packageUpdates
    }

    /// Injects the network edges and a scan root; builds the real `UpdateChecker` for each check.
    public convenience init(applicationsRoot: String? = nil, fetcher: any HTTPFetching, caskIndex: any CaskIndexProviding,
                            catalogue: UserCatalogue = .empty, installer: any AppUpdateInstalling) {
        let checker = UpdateChecker(fetcher: fetcher, caskIndex: caskIndex, catalogue: catalogue)
        self.init(scan: AppUpdatesController.inventoryScan(applicationsRoot: applicationsRoot),
                  check: { apps in await checker.check(apps, includeIgnored: true) },
                  recheck: { path in await AppUpdatesController.rescan(path).asyncMap { await checker.checkOne($0.app) } },
                  installer: installer)
    }

    /// The real app: /Applications and ~/Applications, the user catalogue (read afresh each time, and
    /// never replaced by an empty one when it is broken), the Homebrew cask index and the standard
    /// installer state folders. The parameters exist so tests can point everything at temporary folders.
    public static func live(catalogueURL explicitCatalogue: URL? = nil, applicationsRoot: String? = nil,
                            fetcher: any HTTPFetching = URLSessionFetcher(), caskIndex: (any CaskIndexProviding)? = nil,
                            installerLocations: InstallerLocations? = nil,
                            runningVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                            adminUpdates: Bool = AdminUpdateFlag.isEnabled(),
                            packageUpdates: Bool = AdminUpdateFlag.isPackageEnabled()) -> AppUpdatesController {
        // Nothing real is resolved here: the state folders are chosen on first use (a check, update,
        // rollback, recovery or state refresh), so constructing or rendering the app touches no user state.
        let state = LazyState(explicit: installerLocations)
        let index: any CaskIndexProviding = caskIndex ?? LazyCaskIndex(fetcher: fetcher)
        let installer = LazyInstaller(state, admin: adminUpdates || packageUpdates
                                      ? AdminUpdatePath.system(replacement: adminUpdates, packages: packageUpdates) : nil)
        // Read the catalogue from the state folder actually in use (as the CLI does), so the app and
        // the CLI never apply different ignore rules while a migration is held back.
        @Sendable func catalogueURL() -> URL {
            explicitCatalogue
                ?? state.locations.map { URL(fileURLWithPath: $0.supportRoot).appendingPathComponent("catalogue.json") }
                ?? UserCatalogue.defaultURL
        }
        @Sendable func checker() throws -> UpdateChecker {
            do {
                return UpdateChecker(fetcher: fetcher, caskIndex: index, catalogue: try UserCatalogue.load(from: catalogueURL()))
            } catch { throw AppUpdateCatalogueFailure(reason: "\(error)") }
        }
        let scan = inventoryScan(applicationsRoot: applicationsRoot)
        let controller = AppUpdatesController(scan: scan,
            check: { apps in try await checker().check(apps, includeIgnored: true) },
            recheck: { path in
                let live = try checker()
                return await rescan(path).asyncMap { await live.checkOne($0.app) }
            },
            catalogue: { do { _ = try UserCatalogue.load(from: catalogueURL()); return nil } catch { return "\(error)" } },
            editCatalogue: { bundleID, ignored in
                // The default location is the owner's real state: tests lift it with the tripwire's refusal.
                if explicitCatalogue == nil, state.locations == nil { try RealStateTripwire.check("default catalogue.json") }
                try UserCatalogue.setIgnored(ignored, bundleID: bundleID, at: catalogueURL())
            },
            installer: installer, adminUpdates: adminUpdates, packageUpdates: packageUpdates)
        controller.setupProbe = { state.problem }
        controller.urlOpener = WorkspaceURLOpener()
        // Patched's own release lookup: never under the test tripwire, and only for an installed build that
        // knows its version.
        if let runningVersion, !RealStateTripwire.isActive {
            controller.selfUpdateCheck = { await PatchedReleaseChecker.check(currentVersion: runningVersion, fetcher: fetcher) }
        }
        return controller
    }

    /// A controller that scans nothing and installs nothing, for fixtures that must not touch real state.
    @_spi(Testing) public static func inert() -> AppUpdatesController {
        AppUpdatesController(scan: { [] }, check: { _ in [] }, recheck: { _ in nil }, installer: UnavailableInstaller())
    }

    private static func inventoryScan(applicationsRoot: String?) -> AppUpdateScan {
        { @Sendable in
            let inventory = applicationsRoot.map { LocalApplicationInventory(scanningDirectories: [$0]) } ?? LocalApplicationInventory()
            return await inventory.scan().applications.map {
                AppUpdateScannedApp(app: InstalledApp(observation: $0), icon: $0.installedIcon)
            }
        }
    }

    /// Rescans the folder holding one app, as the command line does for a path, and returns that app.
    nonisolated static func rescan(_ path: String) async -> AppUpdateScannedApp? {
        let inventory = LocalApplicationInventory(scanningDirectories: [(path as NSString).deletingLastPathComponent])
        return await inventory.scan().applications.first { $0.path == path }.map {
            AppUpdateScannedApp(app: InstalledApp(observation: $0), icon: $0.installedIcon)
        }
    }

    // MARK: Derived state

    /// Installing and rolling back are paused while the catalogue is broken or a journal cannot be read.
    public var installBlocked: Bool { catalogueError != nil || !unreadableJournals.isEmpty }
    /// What Update All installs: never anything that needs admin rights or Apple's Installer.
    public var updatableRows: [AppUpdateRow] {
        let ignored = ignoredBundleIDs
        return rows.filter { canUpdate($0) && $0.privilege == .standard && !$0.needsManualAdmin && !($0.bundleID.map(ignored.contains) ?? false) }
    }
    /// Bundle IDs the catalogue ignores: another copy of the same app is never updated or opened in the App Store either.
    private var ignoredBundleIDs: Set<String> { Set(rows.filter(\.isIgnored).compactMap(\.bundleID)) }
    public var canCheck: Bool { phase == .idle && !isWorking && catalogueError == nil }
    /// App Store updates on offer (never installed by Patched). Update All opens the App Store for these.
    public var appStoreRows: [AppUpdateRow] {
        let ignored = ignoredBundleIDs
        return rows.filter { $0.isAppStoreUpdate && !($0.bundleID.map(ignored.contains) ?? false) }
    }
    /// Same conditions as the menu item: App Store rows are subject to the idle, working and blocked guards too.
    public var canUpdateAll: Bool {
        !updatableRows.isEmpty || (!appStoreRows.isEmpty && phase == .idle && !isWorking && !installBlocked)
    }
    /// The installable updates waiting, as used for notifications. The offered build is part of each one's identity.
    var availableUpdates: [AvailableUpdate] {
        rows.filter { $0.status == .updateAvailable || $0.status == .appStoreUpdate }.map { row in
            var build = ""
            if case .updateAvailable(let offer)? = row.outcome?.result { build = offer.buildVersion ?? "" }
            return AvailableUpdate(path: row.path, name: row.name, version: row.latestVersion ?? "?", build: build,
                                   appStore: row.status == .appStoreUpdate)
        }
    }
    /// The same identity as `AvailableUpdate.key`, for an outcome freshly rechecked.
    nonisolated static func updateKey(_ outcome: AppCheckOutcome) -> String? {
        guard case .updateAvailable(let offer) = outcome.result else { return nil }
        return AvailableUpdate(path: outcome.app.path, name: outcome.app.name, version: offer.displayVersion,
                               build: offer.buildVersion ?? "").key
    }
    /// How many rows Update All would install right now: installable, standard-privilege updates. Unlike the
    /// badge it leaves out admin, installer-package and low-confidence rows. Keeps the previous result's
    /// count while a check runs.
    public var updateAllCount: Int {
        (phase == .checking && hasChecked ? rowsBeforeCheck : rows).filter {
            $0.status == .updateAvailable && $0.privilege == .standard && !$0.needsManualAdmin && $0.outcome?.installable == true
        }.count
    }
    /// Apps with an update waiting, App Store ones included: the menu-bar badge. While a check runs this keeps showing
    /// the previous result instead of dropping to zero.
    /// The rows the menu and badge describe: the previous result while a check runs, else the current rows.
    var displayedRows: [AppUpdateRow] { phase == .checking && hasChecked ? rowsBeforeCheck : rows }
    public var availableUpdateCount: Int {
        (phase == .checking && hasChecked ? rowsBeforeCheck : rows).filter {
            $0.status == .updateAvailable || $0.status == .appStoreUpdate
        }.count
    }
    /// How many App Store updates Update All would open the App Store for. Keeps the previous result's count while a check runs.
    public var appStoreUpdateCount: Int {
        (phase == .checking && hasChecked ? rowsBeforeCheck : rows).filter(\.isAppStoreUpdate).count
    }
    public func row(id: String) -> AppUpdateRow? { rows.first { $0.id == id } }

    /// Update is offered only for an installable available update, when nothing else is running.
    public func canUpdate(_ row: AppUpdateRow) -> Bool {
        phase == .idle && !isWorking && !installBlocked && row.activity == .idle && row.status == .updateAvailable
            && row.outcome?.installable == true && !row.needsManualAdmin
    }
    /// Open <app> is offered for an update that needs admin rights, when nothing else is running on that row.
    public func canOpenApp(_ row: AppUpdateRow) -> Bool {
        row.needsManualAdmin && row.status == .updateAvailable && row.activity == .idle
    }
    public func canRollBack(_ row: AppUpdateRow) -> Bool {
        phase == .idle && !isWorking && !installBlocked && row.activity == .idle && row.canRollBack
            && row.status != .needsRecheck
    }

    // MARK: Check

    public func check() {
        guard canCheck else { return }
        phase = .checking
        generation += 1; epoch += 1; pendingQuit = nil
        let mine = generation
        rowsBeforeCheck = rows
        let scanApps = scanApps, checkApps = checkApps
        startSelfLookup(generation: mine)
        checkTask = Task { [weak self] in
            let scanned = await Self.background { await scanApps() }
            guard let self, self.isCurrentCheck(mine) else { return }
            let seeded = scanned.sorted { Self.ordered($0.app.name, $1.app.name) }.map(Self.pendingRow)
            self.rows = seeded
            let outcomes: [AppCheckOutcome]
            do { outcomes = try await Self.background { try await checkApps(scanned.map(\.app)) } }
            catch {
                guard self.isCurrentCheck(mine) else { return }
                self.rows = self.rowsBeforeCheck
                self.phase = .idle; self.checkTask = nil
                self.stopSelfLookup()
                self.catalogueError = Self.catalogueMessage(error)
                self.summary = "Check stopped: \(self.catalogueError ?? "\(error)")"
                self.onCheckFinished?(.failed)
                self.dropQueuedUpdateAll()
                return
            }
            guard self.isCurrentCheck(mine) else { return }
            let icons = Dictionary(scanned.map { ($0.app.path, $0.icon) }, uniquingKeysWith: { first, _ in first })
            self.rows = outcomes.sorted { Self.ordered($0.app.name, $1.app.name) }
                .map { self.makeRow($0, icon: icons[$0.app.path] ?? nil) }
            self.hasChecked = true
            self.lastCheckedAt = Date()
            self.phase = .idle
            self.checkTask = nil
            self.summary = Self.checkSummary(self.rows)
            self.onCheckFinished?(.succeeded)
            await self.refreshInstallerState()
            // Only a successful check may release a queued Update All, and only after the install-blocking
            // state (catalogue, journals) has been refreshed.
            self.releaseQueuedUpdateAll()
        }
    }

    /// Queues an Update All to run once, after the next check that succeeds. `keys` scopes it to the updates
    /// a notification advertised. Replaces an earlier queued request. Not available while installing.
    func queueUpdateAll(only keys: Set<String>?, onFinished: (@MainActor (UpdateAllSummary) -> Void)?,
                        onDropped: (@MainActor () -> Void)?) {
        queuedUpdateAll = QueuedUpdateAll(keys: keys, onFinished: onFinished, onDropped: onDropped)
        updateAllQueued = true
    }

    /// Cancels the queued request without running it or calling its drop handler (the user chose Cancel).
    public func cancelQueuedUpdateAll() { queuedUpdateAll = nil; updateAllQueued = false }

    private func takeQueuedUpdateAll() -> QueuedUpdateAll? {
        defer { queuedUpdateAll = nil; updateAllQueued = false }
        return queuedUpdateAll
    }

    private func dropQueuedUpdateAll() { takeQueuedUpdateAll()?.onDropped?() }

    private func releaseQueuedUpdateAll() {
        guard let queued = takeQueuedUpdateAll() else { return }
        if !updateAll(only: queued.keys, onFinished: queued.onFinished) { queued.onDropped?() }
    }

    /// Cancels an in-flight check and puts back the rows shown before it began.
    public func cancelCheck() {
        guard phase == .checking else { return }
        checkTask?.cancel(); checkTask = nil
        stopSelfLookup()
        generation += 1; epoch += 1; pendingQuit = nil
        rows = rowsBeforeCheck
        phase = .idle
        summary = hasChecked ? Self.checkSummary(rows) : "Check cancelled."
        onCheckFinished?(.cancelled)
        dropQueuedUpdateAll()
    }

    private func stopSelfLookup() { selfApplyTask?.cancel(); selfApplyTask = nil; selfLookupPending = false }

    /// Looks up Patched's own release beside the app checks. The app rows never wait for it: its answer is applied
    /// when it arrives, and only if no newer check (or cancel) has happened since.
    private func startSelfLookup(generation mine: Int) {
        selfApplyTask?.cancel(); selfApplyTask = nil
        guard let lookup = selfUpdateCheck else { selfLookupPending = false; return }
        selfLookupPending = true
        let timeout = selfLookupTimeout
        selfApplyTask = Task { [weak self] in
            let result = await Self.raced(lookup, timeout: timeout)
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            switch result {
            case .newer(let release): self.selfUpdate = SelfUpdate(version: release.version, url: release.pageURL)
            case .noNews: self.selfUpdate = nil
            case .unavailable: break      // a failed lookup says nothing: keep what was known
            }
            let version = self.selfUpdate?.version
            for index in self.rows.indices where self.rows[index].outcome?.noSourceReason == .thisApp {
                self.rows[index].selfUpdateVersion = version
            }
            self.selfLookupPending = false
            self.onSelfLookupFinished?()
        }
    }

    /// The lookup, or `.unavailable` once `timeout` passes, whichever is first. A lookup that never returns is
    /// abandoned rather than awaited.
    @_spi(Testing) nonisolated public static func raced(_ lookup: @escaping SelfUpdateCheck, timeout: TimeInterval) async -> PatchedReleaseResult {
        let box = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PatchedReleaseResult, Never>) in
                box.install(continuation)
                box.add(Task.detached { box.resume(await lookup()) })
                box.add(Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    box.resume(.unavailable)
                })
            }
        } onCancel: { box.resume(.unavailable) }
    }

    private func isCurrentCheck(_ mine: Int) -> Bool { !Task.isCancelled && generation == mine && phase == .checking }

    // MARK: Actions

    /// A click on Download beside "Patched X is available": opens the validated release page, nothing else.
    /// It downloads, installs and launches nothing; the scheduler never calls it.
    public func downloadSelfUpdate() {
        guard let selfUpdate else { return }
        _ = urlOpener.open(selfUpdate.url)
    }

    /// A click on one row's Update. Only here (and in its quit confirmation) can the admin path be used,
    /// and only for a row that shows "Update (admin)" or "Update (installer)".
    public func update(id: String) {
        guard let row = row(id: id), canUpdate(row) else { return }
        let admin = mayUseAdmin(row)
        launch { await self.performUpdate(path: id, quit: false, interactive: true, admin: admin) }
    }

    /// Sequential; a failure on one app never stops the rest. Open apps are skipped, not quit.
    /// Each app is rescanned and rechecked just before it is installed. Never passes admin consent.
    /// Only an explicit click (the Updates window, the menu item or the notification's Update All button)
    /// may call this; the scheduler never does. `onFinished` receives what happened, once, when the run ends.
    /// With `keys` (from a notification) only rows whose current offer is one of those advertised updates are
    /// installed, and each is rechecked to still be that same offer; everything else is left alone.
    /// Returns false when nothing was started.
    @discardableResult
    public func updateAll(onFinished: (@MainActor (UpdateAllSummary) -> Void)? = nil) -> Bool {
        updateAll(only: nil, onFinished: onFinished)
    }

    @discardableResult
    func updateAll(only keys: Set<String>?, onFinished: (@MainActor (UpdateAllSummary) -> Void)? = nil) -> Bool {
        updateAllInvocations += 1
        var candidates = updatableRows
        if let keys { candidates = candidates.filter { keys.contains(updateKey(of: $0)) } }
        let paths = candidates.map(\.id)
        // App Store updates are never installed here; Update All only opens the App Store for them, once, after
        // the installable updates have run. With nothing installable, that is all it does.
        let storeAtStart = scopedAppStoreCount(keys)
        guard !paths.isEmpty || storeAtStart > 0, !isWorking, phase == .idle, !installBlocked else { return false }
        stopRequested = false
        if paths.isEmpty {
            launch {
                let opened = await self.urlOpener.openAppStoreUpdates()
                self.summary = opened ? "\(storeAtStart) to update in the App Store." : Self.appStoreOpenFailure
                onFinished?(UpdateAllSummary(updated: 0, failed: 0, skippedOpen: 0, needsAdmin: self.knownNeedsAdmin(keys).count,
                                             appStore: opened ? storeAtStart : 0, appStoreFailed: opened ? 0 : storeAtStart))
            }
            return true
        }
        updateAllProgress = UpdateAllProgress(done: 0, total: paths.count, stopping: false)
        launch {
            var updated = 0, failed = 0, skipped = 0, open = 0, stopped = 0, changed = 0
            var adminPaths = Set<String>()
            for (index, path) in paths.enumerated() {
                if self.stopRequested { stopped = paths.count - index; skipped += stopped; break }
                // Never with admin rights: rows that need them are not in `updatableRows`, and one that turns
                // out to need them is skipped (and marked "Update (admin)" when admin updates are on).
                switch await self.performUpdate(path: path, quit: false, interactive: false, admin: false, onlyKeys: keys) {
                case .updated: updated += 1
                case .failed: failed += 1
                case .changed: changed += 1
                case .skippedRunning: skipped += 1; open += 1
                case .needsAdmin: skipped += 1; adminPaths.insert(path)
                }
                self.updateAllProgress?.done = index + 1
            }
            self.updateAllProgress = nil
            // The App Store, once, after the installs; not when the user chose Stop.
            var store = 0, storeFailed = 0
            let storeNow = self.stopRequested ? 0 : self.scopedAppStoreCount(keys)
            if storeNow > 0 {
                if await self.urlOpener.openAppStoreUpdates() { store = storeNow } else { storeFailed = storeNow }
            }
            self.summary = "\(updated) updated" + (failed > 0 ? ", \(failed) failed" : "")
                + (skipped > 0 ? ", \(skipped) skipped" : "") + (store > 0 ? ", \(store) to update in the App Store" : "")
                + (storeFailed > 0 ? ". " + Self.appStoreOpenFailure : ".")
            // Admin and installer rows are never installed here, whether known up front or found out, and
            // whether or not experimental admin updates are switched on. Installer-only updates count too.
            // Rows outside a notification's scope are not part of this run's report.
            let known = self.knownNeedsAdmin(keys)
            onFinished?(UpdateAllSummary(updated: updated, failed: failed, skippedOpen: open,
                                         needsAdmin: adminPaths.union(known).count, stopped: stopped, changed: changed,
                                         appStore: store, appStoreFailed: storeFailed))
        }
        return true
    }

    static let appStoreOpenFailure = "Couldn't open the App Store. Open it and choose Updates."

    /// Paths of in-scope rows Update All never installs: admin and installer rows, and unsupported packages.
    private func knownNeedsAdmin(_ keys: Set<String>?) -> [String] {
        rows.filter {
            (keys == nil || keys!.contains(updateKey(of: $0)))
            && (($0.status == .updateAvailable && ($0.privilege != .standard || $0.needsManualAdmin)) || $0.status == .packageUnsupported)
        }.map(\.id)
    }

    /// App Store updates inside an Update All run's scope: every one, or those a notification advertised.
    private func scopedAppStoreCount(_ keys: Set<String>?) -> Int {
        appStoreRows.filter { keys == nil || keys!.contains(updateKey(of: $0)) }.count
    }

    /// Where Spotlight says the App Store's ID for an app is; replaced in tests. Read only on a click.
    @_spi(Testing) public var appStoreAdamID: @Sendable (String) -> Int? = { SpotlightAppStoreID.adamID(forPath: $0) }

    /// A click on a row's Open in App Store: that app's page when the lookup gave a listing, else the page for the
    /// App Store ID Spotlight holds for the app, else the Updates page, else the App Store app.
    /// Patched never installs an App Store app.
    public func openInAppStore(id: String) {
        guard let row = row(id: id), row.canOpenInAppStore, row.activity == .idle else { return }
        let page = row.outcome?.appStoreURL ?? appStoreAdamID(row.path).flatMap { $0 > 0 ? AppStoreLinks.appURL(trackID: $0) : nil }
        let direct = page.map { urlOpener.open($0) } ?? false
        if direct { return }
        let opener = urlOpener
        openTask = Task { [weak self] in
            if await opener.openAppStoreUpdates() { return }
            self?.mutate(id) { $0.result = .init(kind: .info, text: Self.appStoreOpenFailure) }
        }
    }

    // MARK: Ignoring

    public func canIgnore(_ row: AppUpdateRow) -> Bool {
        editCatalogue != nil && row.bundleID != nil && !row.isIgnored && canEditIgnore(row)
    }
    public func canStopIgnoring(_ row: AppUpdateRow) -> Bool { editCatalogue != nil && row.isIgnored && canEditIgnore(row) }
    private func canEditIgnore(_ row: AppUpdateRow) -> Bool {
        phase == .idle && !isWorking && catalogueError == nil && row.activity == .idle
    }
    /// Rows the Updates screen lists: everything except apps the user ignores.
    public var updatesRows: [AppUpdateRow] { rows.filter { !$0.isIgnored } }

    /// A click on Ignore: writes an ignore entry for the app's bundle ID to the user catalogue, then checks that app again.
    public func ignore(id: String) {
        guard let row = row(id: id), canIgnore(row), let bundleID = row.bundleID else { return }
        editIgnore(row, bundleID: bundleID, ignored: true)
    }
    /// A click on Stop ignoring: removes only that app's ignore entry, then checks the app again.
    public func stopIgnoring(id: String) {
        guard let row = row(id: id), canStopIgnoring(row), let bundleID = row.bundleID else { return }
        editIgnore(row, bundleID: bundleID, ignored: false)
    }
    private func editIgnore(_ row: AppUpdateRow, bundleID: String, ignored: Bool) {
        guard let edit = editCatalogue else { return }
        let path = row.id
        launch {
            var failure: String?
            do { try await Self.background { try edit(bundleID, ignored) } }
            catch { failure = (error as? CatalogueError)?.message ?? "\(error)" }
            // Every installed copy of the app shares the entry, so every copy is checked again, even after an
            // error: an edit can be committed and then fail its final sync, and the rows must match what is on
            // disk. Rechecking reads the catalogue as it really is.
            let copies = self.rows.filter { $0.bundleID == bundleID }.map(\.id)
            for copy in (copies.contains(path) ? copies : copies + [path]) { await self.refreshRow(copy) }
            if let failure {
                let text = (ignored ? "Couldn't ignore " : "Couldn't stop ignoring ") + row.name + ". " + failure
                self.mutate(path) { $0.result = .init(kind: .failure, text: text) }
                self.ignoreEditFailure = text
            } else {
                self.ignoreEditFailure = nil
            }
        }
    }
    private var openTask: Task<Void, Never>?

    /// A click on an admin-required row's Open <app>: opens that app at its installed path so the user can
    /// use its own updater. Only this click opens an app; checks, notifications and Update All never do.
    public func openApp(id: String) {
        guard let row = row(id: id), canOpenApp(row) else { return }
        let opener = urlOpener, path = row.path, name = row.name, team = row.outcome?.teamID
        // The bundle ID seen when the row was built is what must still be at the path.
        guard let bundleID = row.bundleID else {
            staleForOpen(id, "\(name) can't be verified before opening. Check again.")
            return
        }
        mutate(id) { $0.result = nil }
        openTask = Task { [weak self] in
            switch await opener.openApplication(atPath: path, expectedBundleID: bundleID, expectedTeamID: team) {
            case .opened: return
            case .changed: self?.staleForOpen(id, "\(name) has changed since the last check, so it was not opened. Check again.")
            case .failed: self?.mutate(id) { $0.result = .init(kind: .failure, text: "Couldn't open \(name). Open it from your Applications folder.") }
            }
        }
    }

    /// Identity of a row's current offer, as a notification advertises it.
    func updateKey(of row: AppUpdateRow) -> String {
        var build = ""
        if case .updateAvailable(let offer)? = row.outcome?.result { build = offer.buildVersion ?? "" }
        return AvailableUpdate(path: row.path, name: row.name, version: row.latestVersion ?? "?", build: build).key
    }

    /// Stops Update All after the app currently being installed; an install already begun is never interrupted.
    public func stopUpdateAll() {
        cancelQueuedUpdateAll()
        guard updateAllProgress != nil else { return }
        stopRequested = true; updateAllProgress?.stopping = true
    }

    /// A click on Roll back. With admin updates on, an app that needs admin rights is rolled back through
    /// macOS's prompt; a user-replaceable one never prompts.
    public func rollBack(id: String) {
        guard let row = row(id: id), canRollBack(row) else { return }
        launch { await self.performRollback(path: id, quit: false) }
    }

    /// Whether a click on this row's Update may pass admin consent: only for the part that is switched on.
    private func mayUseAdmin(_ row: AppUpdateRow) -> Bool {
        switch row.privilege {
        case .standard: return false
        case .admin: return adminUpdatesEnabled
        case .installer: return packageUpdatesEnabled
        }
    }

    /// The Done button while Apple's Installer is open: Patched then checks what was installed.
    public func finishInstaller() { currentAdmin?.userFinishedInstaller() }

    public func recover() {
        guard !isWorking, phase == .idle else { return }
        launch { await self.performRecover(quit: false) }
    }

    /// Acts only if the confirmation is still the one raised for the current state of the same row.
    public func confirmQuit() {
        guard let pending = pendingQuit, !isWorking, phase == .idle, pending.epoch == epoch else { pendingQuit = nil; return }
        pendingQuit = nil
        switch pending.action {
        case .update:
            guard let row = row(id: pending.path), canUpdate(row), row.installedVersion == pending.installedVersion else { return }
            let admin = mayUseAdmin(row)
            launch { _ = await self.performUpdate(path: pending.path, quit: true, interactive: false, admin: admin) }
        case .rollback:
            guard let row = row(id: pending.path), canRollBack(row), row.installedVersion == pending.installedVersion else { return }
            launch { await self.performRollback(path: pending.path, quit: true) }
        case .recover:
            launch { await self.performRecover(quit: true) }
        }
    }
    public func cancelQuit() { pendingQuit = nil }

    /// Re-reads backups, unfinished and unreadable journals, and whether the catalogue can be loaded.
    public func refreshInstallerState() async {
        let installer = installer, probe = probeCatalogue
        let state = await Self.background { (installer.unfinishedTransactionCount(), installer.allBackups(),
                                              installer.unreadableJournalPaths(), probe()) }
        unfinishedCount = state.0
        notice = setupProbe()
        unreadableJournals = state.2
        catalogueError = state.3.map { Self.catalogueBanner($0) }
        applyBackups(state.1)
    }

    @_spi(Testing) public func waitUntilIdle() async {
        await checkTask?.value
        await operation?.value
        await openTask?.value
        await selfApplyTask?.value
    }

    // MARK: Operations

    private enum StepResult { case updated, failed, skippedRunning, needsAdmin, changed }

    private func launch(_ work: @escaping @MainActor () async -> Void) {
        isWorking = true
        epoch += 1; pendingQuit = nil; deferredQuit = nil
        operation = Task { [weak self] in
            await work()
            guard let self else { return }
            await self.refreshInstallerState()
            self.isWorking = false
            self.operation = nil
            // Offered only now that confirming can actually run.
            self.pendingQuit = self.deferredQuit
            self.deferredQuit = nil
        }
    }

    /// Rescans one app and replaces its row with what is now on disk. When that cannot be done the row is
    /// marked as needing a new check, and its actions stay disabled until it has one.
    private func refreshRow(_ path: String) async {
        let recheck = recheckApp
        do {
            let fresh = try await Self.background { try await recheck(path) }
            guard let old = row(id: path) else { return }
            guard let fresh else { markStale(path, "The app is no longer at this location."); return }
            var row = makeRow(fresh, icon: old.icon)
            row.result = old.result
            row.rollbackVersion = old.rollbackVersion
            replace(row)
        } catch {
            catalogueError = Self.catalogueMessage(error)
            markStale(path, nil)
        }
    }

    /// An Open that was refused because the app is no longer the one that was checked: show it as an error on
    /// the row, drop the Open button and require a fresh check.
    private func staleForOpen(_ path: String, _ message: String) {
        mutate(path) {
            $0.status = .needsRecheck; $0.outcome = nil; $0.latestVersion = nil; $0.activity = .idle
            $0.needsManualAdmin = false
            $0.result = .init(kind: .failure, text: message)
        }
    }

    private func markStale(_ path: String, _ detail: String?) {
        mutate(path) {
            $0.status = .needsRecheck; $0.outcome = nil; $0.latestVersion = nil; $0.activity = .idle
            if let detail { $0.result = .init(kind: .info, text: detail) }
        }
    }

    private func replace(_ row: AppUpdateRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[index] = row
    }

    /// An `AdminInteraction` for one explicit action; it routes Apple's Installer's notice to the sheet.
    private func makeAdminInteraction(path: String, name: String) -> AdminInteraction {
        let token = UUID()
        let interaction = AdminInteraction(onInstallerOpened: { [weak self] message in
            Task { @MainActor in
                // A notice that arrives after its action ended must not reopen the sheet.
                guard let self, self.adminToken == token else { return }
                self.installerWait = AppUpdateInstallerWait(path: path, name: name, message: message)
            }
        })
        adminToken = token
        currentAdmin = interaction
        return interaction
    }

    private func endAdminInteraction() { currentAdmin = nil; adminToken = nil; installerWait = nil }

    private func performUpdate(path: String, quit: Bool, interactive: Bool, admin: Bool, onlyKeys: Set<String>? = nil) async -> StepResult {
        guard let shown = row(id: path), shown.outcome != nil else { return .failed }
        mutate(path) { $0.activity = .updating; $0.result = nil }
        // Rescan this one app and check it afresh; install only what is still an installable update now.
        let recheck = recheckApp
        let outcome: AppCheckOutcome
        do {
            guard let fresh = try await Self.background({ try await recheck(path) }) else {
                markStale(path, "\(shown.name) is no longer at this location. Check again.")
                return .failed
            }
            // A notification-scoped run installs only the very offer that was advertised.
            let inScope = onlyKeys.map { keys in Self.updateKey(fresh).map(keys.contains) ?? false } ?? true
            guard case .updateAvailable = fresh.result, fresh.installable, inScope else {
                var row = makeRow(fresh, icon: shown.icon)
                row.rollbackVersion = shown.rollbackVersion
                row.result = .init(kind: .info, text: "\(shown.name) changed since the last check, so nothing was installed.")
                replace(row)
                return onlyKeys == nil ? .failed : .changed
            }
            outcome = fresh
            mutate(path) { $0.outcome = fresh }
        } catch {
            catalogueError = Self.catalogueMessage(error)
            markStale(path, "\(shown.name): the catalogue could not be read, so nothing was installed.")
            return .failed
        }
        let interaction = admin ? makeAdminInteraction(path: path, name: outcome.app.name) : nil
        defer { if interaction != nil { endAdminInteraction() } }
        do {
            // The installer enforces `installable` itself as well.
            let report = try await installer.update(outcome, quitIfRunning: quit, admin: interaction)
            mutate(path) {
                $0.result = .init(kind: .success, text: Self.reportText(name: outcome.app.name, report))
                $0.installedVersion = report.toVersion; $0.installedDisplayVersion = nil; $0.status = .needsRecheck; $0.outcome = nil
            }
            await refreshRow(path)
            return .updated
        } catch let refusal as InstallRefusal {
            let name = outcome.app.name
            if case .needsAdmin = refusal, interaction == nil {
                // Needs admin rights whether or not the experimental admin path is on; only with it on does
                // the row offer "Update (admin)".
                if adminUpdatesEnabled {
                    needsAdminPaths.insert(path)
                    mutate(path) {
                        $0.activity = .idle; $0.privilege = .admin
                        $0.result = .init(kind: .info, text: "\(name) needs admin rights. Choose Update (admin); macOS asks for your password for this one update.")
                    }
                } else {
                    // Patched cannot do this one. Remember it, so the row offers Open <app> from now on.
                    needsAdminPaths.insert(path)
                    let format: ArtifactFormat? = { if case .updateAvailable(let offer) = outcome.result { return offer.format }; return nil }()
                    let result = Self.refusalResult(name: name, refusal, format: format)
                    mutate(path) { $0.activity = .idle; $0.needsManualAdmin = true; $0.result = result }
                }
                return .needsAdmin
            }
            if case .appRunning = refusal, !quit {
                if interactive {
                    deferredQuit = .init(path: path, action: .update, message: "\(name) is open. Quit it, update, and reopen it?",
                                         epoch: epoch, installedVersion: shown.installedVersion)
                }
                mutate(path) {
                    $0.activity = .idle
                    $0.result = .init(kind: .info, text: "\(name) is open. Choose Update to quit it, update and reopen it.")
                }
                return .skippedRunning
            }
            let format: ArtifactFormat? = { if case .updateAvailable(let offer) = outcome.result { return offer.format }; return nil }()
            let result = Self.refusalResult(name: name, refusal, format: format)
            mutate(path) { $0.activity = .idle; $0.result = result }
            return .failed
        } catch {
            mutate(path) {
                $0.activity = .idle
                $0.result = .init(kind: .failure, text: OutcomeText.line(name: outcome.app.name, status: "refused", from: nil,
                    to: nil, backupFolder: nil, reason: "internal_error", detail: "\(error)"))
            }
            return .failed
        }
    }

    private func performRollback(path: String, quit: Bool) async {
        guard let row = row(id: path) else { return }
        mutate(path) { $0.activity = .rollingBack; $0.result = nil }
        // An explicit click: with admin updates on, an admin-owned app may be rolled back through macOS's prompt.
        let interaction = adminUpdatesEnabled ? makeAdminInteraction(path: path, name: row.name) : nil
        defer { if interaction != nil { endAdminInteraction() } }
        do {
            let report = try await installer.rollBack(appAt: path, quitIfRunning: quit, admin: interaction)
            mutate(path) {
                $0.installedVersion = report.toVersion; $0.installedDisplayVersion = nil; $0.status = .needsRecheck; $0.outcome = nil; $0.latestVersion = nil
                $0.result = .init(kind: .success, text: Self.reportText(name: row.name, report))
            }
            await refreshRow(path)
            mutate(path) { $0.activity = .idle }
        } catch let refusal as InstallRefusal {
            if case .appRunning = refusal, !quit {
                deferredQuit = .init(path: path, action: .rollback, message: "\(row.name) is open. Quit it, roll it back, and reopen it?",
                                     epoch: epoch, installedVersion: row.installedVersion)
                mutate(path) { $0.activity = .idle }
                return
            }
            let result = Self.refusalResult(name: row.name, refusal, format: nil)
            mutate(path) { $0.activity = .idle; $0.result = result }
        } catch {
            mutate(path) {
                $0.activity = .idle
                $0.result = .init(kind: .failure, text: OutcomeText.line(name: row.name, status: "refused", from: nil,
                    to: nil, backupFolder: nil, reason: "internal_error", detail: "\(error)"))
            }
        }
    }

    private func performRecover(quit: Bool) async {
        let result = await installer.recoverUnfinished(quitIfRunning: quit)
        var lines: [String] = result.unreadable.map { "journal \($0): unreadable, left in place for inspection" }
        var running = false
        var touched: [String] = []
        for report in result.entries {
            touched.append(report.targetPath)
            switch report.result {
            case .success(let outcome):
                let text: String
                switch outcome {
                case .discarded: text = "interrupted before any change; leftovers removed"
                case .completed: text = "finished; new version installed, old version backed up"
                case .reverted: text = "undone; old version is back in place"
                case .cleanedUp: text = "leftover temporary files removed"
                }
                lines.append("\((report.targetPath as NSString).lastPathComponent): \(text)")
                if !report.leftovers.isEmpty { lines.append("  could not remove: " + report.leftovers.joined(separator: ", ")) }
            case .failure(let refusal):
                if case .appRunning = refusal { running = true }
                lines.append("\((report.targetPath as NSString).lastPathComponent): refused [\(refusal.code)] \(refusal.message)")
            }
        }
        if lines.isEmpty { lines = ["Nothing to recover."] }
        recoveryMessage = lines.joined(separator: "\n")
        // Recovery can change which version is installed, so what was checked no longer holds.
        for path in Set(touched) where row(id: path) != nil {
            mutate(path) { $0.status = .needsRecheck; $0.outcome = nil; $0.latestVersion = nil }
            await refreshRow(path)
        }
        if running && !quit {
            deferredQuit = .init(path: "", action: .recover,
                                 message: "An app affected by an interrupted update is open. Quit it and finish recovery?",
                                 epoch: epoch, installedVersion: nil)
        }
    }

    // MARK: Pure helpers

    private func mutate(_ path: String, _ change: (inout AppUpdateRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == path }) else { return }
        change(&rows[index])
    }

    private func applyBackups(_ records: [BackupRecord]) {
        for index in rows.indices {
            let row = rows[index]
            let match = records.first { record in
                record.bundleID == row.bundleID && (record.originalPath.isEmpty || record.originalPath == row.path)
            }
            rows[index].rollbackVersion = row.bundleID == nil ? nil : match.map {
                Self.versionText(short: $0.shortVersion, build: $0.build)
            }
        }
    }

    nonisolated static func catalogueMessage(_ error: Error) -> String {
        let reason = (error as? AppUpdateCatalogueFailure)?.reason ?? "\(error)"
        return catalogueBanner(reason)
    }
    nonisolated static func catalogueBanner(_ reason: String) -> String {
        "catalogue.json can't be read: \(reason) — fix or remove it"
    }

    nonisolated static func ordered(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    nonisolated static func versionText(short: String?, build: String?) -> String {
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        case let (nil, b?): return b
        default: return "?"
        }
    }

    nonisolated static func reportText(name: String, _ report: AppUpdateReport) -> String {
        OutcomeText.line(name: name, status: report.status, from: report.fromVersion, to: report.toVersion,
            backupFolder: report.backupFolder, reason: report.leftovers.isEmpty ? nil : "cleanup_incomplete",
            detail: report.leftovers.isEmpty ? nil : "could not remove (use Recover): " + report.leftovers.joined(separator: ", "),
            note: report.note)
    }

    nonisolated static func refusalResult(name: String, _ refusal: InstallRefusal, format: ArtifactFormat?) -> AppUpdateRow.Result {
        switch refusal {
        case .needsAdmin:
            return .init(kind: .info, text: "\(name): " + AppUpdateRow.needsAdminCaption)
        case .adminReplaceUnavailable:
            return .init(kind: .info, text: "\(name): macOS refused the privileged replacement for this build. Update this app manually.")
        case .unsupportedFormat:
            return .init(kind: .info, text: format == .pkg ? "\(name): Installer packages not supported yet"
                                                        : "\(name): This download format is not supported yet")
        default:
            return .init(kind: .failure, text: OutcomeText.line(name: name, status: "refused", from: nil, to: nil,
                backupFolder: nil, reason: refusal.code, detail: refusal.message))
        }
    }

    nonisolated static func pendingRow(_ scanned: AppUpdateScannedApp) -> AppUpdateRow {
        let app = scanned.app
        return AppUpdateRow(name: app.name, path: app.path, bundleID: app.bundleID, icon: scanned.icon,
            installedVersion: versionText(short: app.shortVersion, build: app.build), latestVersion: nil,
            source: "—", status: .pending, activity: .checking, result: nil, rollbackVersion: nil, outcome: nil)
    }

    /// `makeRow` with this controller's admin setting and the apps already known to need admin rights.
    private func makeRow(_ outcome: AppCheckOutcome, icon: LocalInstalledIcon?) -> AppUpdateRow {
        var row = Self.makeRow(outcome, icon: icon, adminUpdates: adminUpdatesEnabled, packageUpdates: packageUpdatesEnabled,
                               needsAdmin: needsAdminPaths.contains(outcome.app.path))
        if outcome.noSourceReason == .thisApp { row.selfUpdateVersion = selfUpdate?.version }
        return row
    }

    nonisolated static func makeRow(_ outcome: AppCheckOutcome, icon: LocalInstalledIcon?, adminUpdates: Bool = false,
                                    packageUpdates: Bool = false, needsAdmin: Bool = false) -> AppUpdateRow {
        let app = outcome.app
        let installed = versionText(short: app.shortVersion, build: app.build)
        var latest: String?
        var status: AppUpdateRow.Status
        var privilege = AppUpdateRow.Privilege.standard
        switch outcome.result {
        case .upToDate: status = .upToDate; latest = installed
        case .noSource: status = .noSource
        case .refused(let reason): status = .refused(reason.message)
        case .updateAvailable(let offer):
            latest = offer.displayVersion
            if outcome.isAppStoreUpdate { status = .appStoreUpdate }
            else if !outcome.installable { status = .notInstallable }
            else if offer.format == .pkg && packageUpdates { status = .updateAvailable; privilege = .installer }
            else if offer.format == .pkg { status = .packageUnsupported }
            else { status = .updateAvailable; privilege = adminUpdates && needsAdmin ? .admin : .standard }
        }
        let manualAdmin = needsAdmin && !adminUpdates && status == .updateAvailable && privilege == .standard
        let source = outcome.isAppStoreUpdate || outcome.source?.isAppStore == true ? "App Store"
            : (outcome.source.map { $0.kind + (outcome.lowConfidence ? "?" : "") } ?? "—")
        var row = AppUpdateRow(name: app.name, path: app.path, bundleID: app.bundleID, icon: icon,
            installedVersion: installed, latestVersion: latest, source: source, status: status,
            activity: .idle, result: nil, rollbackVersion: nil, privilege: privilege, needsManualAdmin: manualAdmin,
            outcome: outcome)
        row.installedDisplayVersion = app.shortVersion ?? app.build
        return row
    }

    nonisolated static func checkSummary(_ rows: [AppUpdateRow]) -> String {
        let rows = rows.filter { !$0.isIgnored }
        if rows.isEmpty { return "No applications found." }
        let updates = rows.filter { $0.status == .updateAvailable || $0.status == .packageUnsupported || $0.status == .notInstallable
            || $0.status == .appStoreUpdate }.count
        return "\(rows.count) apps checked, \(updates) with updates available."
    }

    /// Throwing variant of `background`.
    nonisolated private static func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached { try await work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Runs `work` off the main actor and forwards cancellation to it.
    nonisolated private static func background<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let task = Task.detached { await work() }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

/// Thrown by the live checker when the catalogue file is unusable; never replaced by an empty catalogue.
/// Resumes a continuation exactly once and cancels the tasks racing for it.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PatchedReleaseResult, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var done = false
    /// The answer given before the continuation existed (a task cancelled before it first ran resumes
    /// through onCancel first); `install` hands it over at once, so the continuation can never leak.
    private var early: PatchedReleaseResult?
    func install(_ c: CheckedContinuation<PatchedReleaseResult, Never>) {
        let now = lock.withLock { () -> PatchedReleaseResult? in
            if done { return early ?? .unavailable }
            continuation = c; return nil
        }
        if let now { c.resume(returning: now) }
    }
    func add(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in tasks.append(task); return done }
        if cancelNow { task.cancel() }
    }
    func resume(_ value: PatchedReleaseResult) {
        let (c, all) = lock.withLock { () -> (CheckedContinuation<PatchedReleaseResult, Never>?, [Task<Void, Never>]) in
            guard !done else { return (nil, []) }
            done = true; let c = continuation; continuation = nil
            if c == nil { early = value }
            return (c, tasks)
        }
        all.forEach { $0.cancel() }
        c?.resume(returning: value)
    }
}

struct AppUpdateCatalogueFailure: Error { let reason: String }

extension Optional where Wrapped: Sendable {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}

/// Chooses the installer state folders on first use only, and remembers the result.
final class LazyState: @unchecked Sendable {
    private let lock = NSLock()
    private let explicit: InstallerLocations?
    private var resolved: Result<InstallerLocations, Error>?
    init(explicit: InstallerLocations?) { self.explicit = explicit }

    var result: Result<InstallerLocations, Error> {
        lock.lock(); defer { lock.unlock() }
        if let resolved { return resolved }
        let value: Result<InstallerLocations, Error> = explicit.map { .success($0) } ?? Result { try InstallerLocations.standard() }
        resolved = value
        return value
    }
    var locations: InstallerLocations? { if case .success(let l) = result { return l }; return nil }
    var problem: String? {
        lock.lock(); let known = resolved; lock.unlock()
        guard case .failure? = known else { return nil }
        return "Update state folders are unavailable, so updates are disabled."
    }
}

/// An installer that only resolves its folders when first asked to do something.
struct LazyInstaller: AppUpdateInstalling {
    let state: LazyState
    /// The experimental admin path, present only when admin updates are switched on.
    let admin: AdminUpdatePath?
    init(_ state: LazyState, admin: AdminUpdatePath? = nil) { self.state = state; self.admin = admin }
    private func real() throws -> UpdateInstaller { UpdateInstaller(locations: try state.result.get(), adminPath: admin) }
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool) async throws -> AppUpdateReport {
        try await real().update(outcome, quitIfRunning: quitIfRunning, admin: nil)
    }
    func rollBack(appAt path: String, quitIfRunning: Bool) async throws -> AppUpdateReport {
        try await real().rollBack(appAt: path, quitIfRunning: quitIfRunning, admin: nil)
    }
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport {
        try await real().update(outcome, quitIfRunning: quitIfRunning, admin: admin)
    }
    func rollBack(appAt path: String, quitIfRunning: Bool, admin: AdminInteraction?) async throws -> AppUpdateReport {
        try await real().rollBack(appAt: path, quitIfRunning: quitIfRunning, admin: admin)
    }
    func recoverUnfinished(quitIfRunning: Bool) async -> AppRecoveryResult {
        guard let installer = try? real() else { return AppRecoveryResult(entries: []) }
        return await installer.recoverUnfinished(quitIfRunning: quitIfRunning)
    }
    func allBackups() -> [BackupRecord] { (try? real())?.allBackups() ?? [] }
    func unfinishedTransactionCount() -> Int { (try? real())?.unfinishedTransactionCount() ?? 0 }
    func unreadableJournalPaths() -> [String] { (try? real())?.unreadableJournalPaths() ?? [] }
}

/// The Homebrew index, created (and its cache folder chosen) only when a check first needs it.
final class LazyCaskIndex: CaskIndexProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let fetcher: any HTTPFetching
    private var provider: CaskIndexProvider?
    init(fetcher: any HTTPFetching) { self.fetcher = fetcher }
    func index() async -> Result<CaskIndex, RefusalReason> {
        await made().index()
    }
    private func made() -> CaskIndexProvider {
        lock.lock(); defer { lock.unlock() }
        if let provider { return provider }
        let made = CaskIndexProvider(fetcher: fetcher)
        provider = made
        return made
    }
}

/// Used only when the standard state folders cannot be found; every operation refuses.
private struct UnavailableInstaller: AppUpdateInstalling {
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool) async throws -> AppUpdateReport {
        throw InstallRefusal.io("update state folders are unavailable")
    }
    func rollBack(appAt path: String, quitIfRunning: Bool) async throws -> AppUpdateReport {
        throw InstallRefusal.io("update state folders are unavailable")
    }
    func recoverUnfinished(quitIfRunning: Bool) async -> AppRecoveryResult { AppRecoveryResult(entries: []) }
    func allBackups() -> [BackupRecord] { [] }
    func unfinishedTransactionCount() -> Int { 0 }
    func unreadableJournalPaths() -> [String] { [] }
}
