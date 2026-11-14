import Foundation
import AppKit
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
    /// As `update(_:quitIfRunning:admin:)`, reporting download, verification and the commit point to `progress`.
    /// Cancelling the calling task stops the update before the commit point and leaves nothing behind.
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?,
                progress: UpdateProgressHandler?) async throws -> AppUpdateReport
}

extension AppUpdateInstalling {
    /// Installers that report no progress just install.
    public func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?,
                       progress: UpdateProgressHandler?) async throws -> AppUpdateReport {
        try await update(outcome, quitIfRunning: quitIfRunning, admin: admin)
    }
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
    public func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?,
                       progress: UpdateProgressHandler?) async throws -> AppUpdateReport {
        AppUpdateReport(try await update(outcome, options: UpdateOptions(quitIfRunning: quitIfRunning, dryRun: false), admin: admin,
                                         progress: progress))
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
                  sparklePublicEDKey: app.vendorMetadata.sparklePublicEDKey,
                  isBackgroundOnly: app.vendorMetadata.backgroundOnly)
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
    /// The app is a `LSBackgroundOnly` helper with no icon of its own. The lists hide it unless there is an update to show.
    public internal(set) var isBackgroundOnly = false
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
    /// The last update came from an installer package, so there is no Roll back; the row says so instead.
    public internal(set) var rollbackUnsupported = false
    /// Set when the last check could not reach the network for this app, so the status and offer above are the
    /// previous check's, kept rather than replaced by an error. Cleared by the next check that gets an answer.
    public internal(set) var recheckNote: String?
    /// While an update runs: the download, then verification, then the commit point. nil before the download starts.
    public internal(set) var progress: UpdateProgress?
    /// Cancel was pressed; the update is stopping.
    public internal(set) var cancelRequested = false
    public static let offlineRecheckNote = String(localized: "Couldn't re-check (offline)")
    public static let rollbackUnsupportedCaption = String(localized: "Roll back isn't supported for installer packages.")
    public internal(set) var privilege: Privilege = .standard
    /// The app needs admin rights to replace and the experimental admin path is off, so Patched cannot update
    /// it. The row offers "Open <app>" instead of Update, for the app's own updater.
    public internal(set) var needsManualAdmin = false
    internal var outcome: AppCheckOutcome?
    /// Set only on Patched's own row when a newer Patched release has been announced. Notify-only: the row
    /// stays a no-source row, so it is never installable and never part of Update All.
    public internal(set) var selfUpdateVersion: String?

    /// "Downloading 12.3 of 48.0 MB", String(localized: "Verifying…") or String(localized: "Installing…") while an update runs; nil before it reports anything.
    public var progressText: String? {
        if cancelRequested { return String(localized: "Cancelling…") }
        guard let progress else { return nil }
        switch progress {
        case .downloading(let received, let expected): return Self.downloadText(received: received, expected: expected)
        case .verifying: return String(localized: "Verifying…")
        case .installing: return String(localized: "Installing…")
        }
    }
    /// Fraction downloaded (0...1), when the total is known; nil otherwise.
    public var downloadFraction: Double? {
        guard case .downloading(let received, let expected?)? = progress, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
    /// "Downloading 12.3 of 48.0 MB" with a known total, "Downloading 12.3 MB" without. Both numbers share the total's unit.
    public static func downloadText(received: Int64, expected: Int64?, locale: Locale = .current) -> String {
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("KB", 1e3)]
        let basis = Double(expected ?? received)
        let (name, size) = units.first { basis >= $0.1 } ?? ("KB", 1e3)
        if let expected, expected > 0 {
            let got = number(Double(min(received, expected)) / size), total = number(Double(expected) / size)
            return String(localized: "Downloading \(got) of \(total) \(name)")
        }
        let got = number(Double(received) / size)
        return String(localized: "Downloading \(got) \(name)")
    }

    public var hasUpdate: Bool { status == .updateAvailable }
    /// An App Store update: shown with Open in App Store, never installed by Patched.
    public var isAppStoreUpdate: Bool { status == .appStoreUpdate }
    /// An App Store app whose status Patched could not confirm (the public lookup lacks it or lists another version).
    public var isAppStoreUnconfirmed: Bool { status == .noSource && outcome?.noSourceReason == .appStoreNotListed }
    /// Rows that offer Open in App Store: Patched only opens the App Store, it never installs these apps.
    public var canOpenInAppStore: Bool { isAppStoreUpdate || isAppStoreUnconfirmed }
    /// What the automatic run may install: a plain update to an ordinary app. Never Patched itself, an installer
    /// package, an app that needs admin rights, a hidden app or a Mac App Store app.
    var isAutomaticallyInstallable: Bool {
        status == .updateAvailable && privilege == .standard && !needsManualAdmin && !isPatchedItself && !isIgnored
            && !isAppStoreUpdate && !isHiddenBackgroundHelper && outcome?.installable == true
    }
    /// Patched's own row: it is never hidden from the lists.
    var isPatchedItself: Bool { bundleID == NoSourceReason.patchedBundleID || outcome?.noSourceReason == .thisApp }
    /// The user's catalogue says to ignore (hide) this app: nothing is looked up for it and it is not listed under Updates.
    public var isIgnored: Bool { status == .noSource && outcome?.noSourceReason == .ignored }
    /// The row shows an Update (or Open <App>) button, so Roll back moves into its … menu.
    public var offersUpdateAction: Bool {
        status == .updateAvailable || status == .notInstallable || status == .packageUnsupported
    }
    /// The row's Update button.
    public var updateActionTitle: String {
        switch privilege {
        case .standard: return String(localized: "Update")
        case .admin: return String(localized: "Update (admin)")
        case .installer: return String(localized: "Update (installer)")
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
        if isAppStoreUpdate { return String(localized: "App Store") }
        if status == .packageUnsupported { return String(localized: "Installer package") }
        if status == .notInstallable {
            switch outcome?.edSignatureBlock {
            case .keyMalformed?: return String(localized: "Bad key")
            case .signatureMissing?, .signatureMalformed?: return String(localized: "Unsigned")
            case nil: return String(localized: "Unconfirmed")
            }
        }
        if needsManualAdmin || privilege == .admin { return String(localized: "Needs admin") }
        return nil
    }
    public var openAppActionTitle: String { String(localized: "Open \(name)") }
    public static let needsAdminCaption = String(localized: "Needs admin rights. Open the app and use its own updater.")

    public var statusText: String {
        switch status {
        case .pending: return String(localized: "Checking…")
        case .upToDate: return String(localized: "Up to date")
        case .updateAvailable:
            switch privilege {
            case .standard: return String(localized: "Update available")
            case .admin: return String(localized: "Update available. Needs admin rights: macOS asks for your password for this update.")
            case .installer: return String(localized: "Update available as an installer package. Apple's Installer will open and ask for your password.")
            }
        case .notInstallable:
            if let block = outcome?.edSignatureBlock { return block.message }
            return String(localized: "Update found, but Patched can't confirm where it comes from, so it won't install it. Update it from the app itself.")
        case .packageUnsupported: return String(localized: "Installer package updates are turned off")
        case .appStoreUpdate: return String(localized: "Update in the App Store")
        case .noSource:
            if let selfUpdateVersion, outcome?.noSourceReason == .thisApp { return String(localized: "Update to \(selfUpdateVersion)") }
            return outcome?.noSourceReason?.rowLabel ?? String(localized: "No update source")
        case .refused(let message): return String(localized: "Can't check: \(message)")
        case .needsRecheck: return String(localized: "Check again to refresh.")
        }
    }
}

extension NoSourceReason {
    /// The row's status line for an app with no update source.
    var rowLabel: String {
        switch self {
        case .noPublicFeed: return String(localized: "No public update feed")
        case .appStoreNotListed: return String(localized: "Updates through the App Store")
        case .ignored: return String(localized: "Hidden")
        case .thisApp: return String(localized: "This app")
        }
    }
}

/// A newer Patched release, validated by `PatchedReleaseChecker`. Shown in the menu, the Updates view and
/// Patched's own row; "Download" opens `url` (the release page) on a click and does nothing else. When the
/// release carries its signed zip (`assets`), "Update" asks for confirmation and then installs it.
public struct SelfUpdate: Equatable, Sendable {
    public let version: String
    public let url: URL
    /// The signed zip and its signature; nil for a release that can only be downloaded by hand.
    public let assets: PatchedReleaseAssets?
    public init(version: String, url: URL, assets: PatchedReleaseAssets? = nil) {
        self.version = version; self.url = url; self.assets = assets
    }
    public var text: String { String(localized: "Patched \(version) is available") }
    /// Identity for "have I told the user about this" (one notification per new version).
    @_spi(Testing) public var key: String { "im.patched.self-update\u{1F}" + version }
}

/// One lookup of Patched's own latest release. At most one request per call.
public typealias SelfUpdateCheck = @Sendable () async -> PatchedReleaseResult

/// Installs a signed Patched release over the running app, then reopens it. `SelfUpdater` in production;
/// tests use a fake. Only `confirmSelfUpdate()` ever calls it.
public protocol SelfInstalling: Sendable {
    func install(_ release: PatchedRelease, progress: @escaping @Sendable (SelfUpdateStep) -> Void) async throws -> SelfUpdateReport
    /// Starts the new Patched (it waits for this process to quit). Throws if it could not be started.
    func relaunch(_ report: SelfUpdateReport) throws
}

/// Where updating Patched itself has got to. Shown beside "Patched X is available".
public enum SelfInstallState: Equatable, Sendable {
    case idle
    /// Waiting for the user to confirm; nothing has been downloaded.
    case confirming(version: String)
    case working(version: String, step: SelfUpdateStep)
    case reopening(version: String)
    case failed(String)

    public var text: String? {
        switch self {
        case .idle: return nil
        case .confirming(let version): return String(localized: "Update Patched to \(version)? Patched will quit and reopen.")
        case .working(let version, .downloading): return String(localized: "Downloading Patched \(version)…")
        case .working(_, .verifying): return String(localized: "Checking the release signature…")
        case .working(let version, .installing): return String(localized: "Installing Patched \(version)…")
        case .reopening(let version): return String(localized: "Reopening Patched \(version)…")
        case .failed(let message): return message
        }
    }
    public var isConfirming: Bool { if case .confirming = self { return true }; return false }
    public var isFailed: Bool { if case .failed = self { return true }; return false }
    public var isBusy: Bool {
        switch self { case .working, .reopening: return true; default: return false }
    }
}

public struct AppUpdateQuitConfirmation: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case update, rollback, recover, updateOpen }
    public let path: String
    public let action: Action
    /// For `.updateOpen`: the apps an Update All run skipped because they were open, in run order.
    public let paths: [String]
    public let message: String
    /// The controller state this confirmation was raised in; any later check, action or row change voids it.
    let epoch: Int
    let installedVersion: String?

    init(path: String, action: Action, paths: [String] = [], message: String, epoch: Int, installedVersion: String?) {
        self.path = path; self.action = action; self.paths = paths; self.message = message
        self.epoch = epoch; self.installedVersion = installedVersion
    }
}

/// Progress of an Update All run: apps finished, apps in the run, and whether Stop was chosen.
public struct UpdateAllProgress: Equatable, Sendable {
    public var done: Int
    public let total: Int
    public var stopping: Bool
    public var text: String {
        stopping ? String(localized: "Stopping after this app…") : String(localized: "Updating \(min(done + 1, total)) of \(total)…")
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
    /// The paths skipped because the app was open, in run order. Not part of `text`. Empty when Stop was chosen.
    public let openPaths: [String]
    public init(updated: Int, failed: Int, skippedOpen: Int, needsAdmin: Int, stopped: Int = 0, changed: Int = 0,
                appStore: Int = 0, appStoreFailed: Int = 0, openPaths: [String] = []) {
        self.openPaths = openPaths
        self.updated = updated; self.failed = failed; self.skippedOpen = skippedOpen
        self.needsAdmin = needsAdmin; self.stopped = stopped; self.changed = changed; self.appStore = appStore
        self.appStoreFailed = appStoreFailed
    }
    private static func apps(_ n: Int) -> String { n == 1 ? String(localized: "1 app") : String(localized: "\(n) apps") }
    /// "Updated 3 apps; 1 skipped because it is open; 1 needs admin"
    public var text: String {
        let onlyAppStore = appStore + appStoreFailed > 0 && updated == 0 && failed == 0 && skippedOpen == 0 && needsAdmin == 0
            && stopped == 0 && changed == 0
        var parts = onlyAppStore ? [] : [String(localized: "Updated \(Self.apps(updated))")]
        if failed > 0 { parts.append(String(localized: "\(failed) failed")) }
        if skippedOpen > 0 { parts.append(skippedOpen == 1 ? String(localized: "\(skippedOpen) skipped because it is open")
                                       : String(localized: "\(skippedOpen) skipped because they are open")) }
        if needsAdmin > 0 { parts.append(needsAdmin == 1 ? String(localized: "\(needsAdmin) needs admin") : String(localized: "\(needsAdmin) need admin")) }
        if changed > 0 { parts.append(String(localized: "\(changed) changed since the notification, not installed")) }
        if stopped > 0 { parts.append(String(localized: "\(stopped) not attempted after Stop")) }
        if appStore > 0 { parts.append(String(localized: "\(appStore) to update in the App Store")) }
        if appStoreFailed > 0 { parts.append(String(localized: "couldn't open the App Store for \(appStoreFailed)")) }
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
    /// When the last check finished successfully (this session). For the menu's String(localized: "Up to date") line.
    @Published public private(set) var lastCheckedAt: Date?
    /// Where rows and the menu get app icons. Tests replace it with a fake.
    public var iconProvider: AppIconProviding = WorkspaceAppIconProvider.shared
    /// A row the menu asked the Updates window to bring into view. Cleared by the view once shown.
    @Published public var focusedRowID: String?
    /// Bumped on every menu selection, so picking the same app again still scrolls back to it.
    @Published public private(set) var focusRequest = 0
    public func focus(rowID: String) { focusedRowID = rowID; focusRequest &+= 1 }
    @Published public private(set) var summary: String = String(localized: "Choose Check for Updates to look for newer versions.")
    @Published public private(set) var notice: String?
    @Published public private(set) var catalogueError: String?
    /// The last Hide or Unhide failure, shown on both Updates and Applications (the row it belongs to
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
    /// `.pkg` updates handed to Apple's Installer, which asks for the password. On unless PATCHED_ENABLE_PKG_UPDATES=0.
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
    /// Updating Patched itself: confirmation, progress or failure. Only explicit clicks change it from idle.
    @Published public private(set) var selfInstall: SelfInstallState = .idle
    /// Installs a signed Patched release. Only `live()` sets a real one, and only for an installed Patched.app.
    @_spi(Testing) public var selfInstaller: (any SelfInstalling)?
    /// Quits this Patched once the new one has been started. `live()` sets the real terminate.
    @_spi(Testing) public var selfTerminate: @MainActor () -> Void = {}
    /// How many times an install was actually started. For tests of the entry points.
    @_spi(Testing) public private(set) var selfInstallStarts = 0
    private var selfInstallTask: Task<Void, Never>?
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
    /// From the last finished check: apps whose lookup failed on the network, and apps that needed the network at all
    /// (everything except those with no source). The scheduler uses them to retry sooner after an offline check.
    private(set) var lastCheckNetworkRefused = 0
    private(set) var lastCheckNetworked = 0
    /// Most of the apps that need the network could not reach it in the last check.
    var lastCheckMostlyOffline: Bool { lastCheckNetworkRefused > 0 && lastCheckNetworkRefused * 2 >= lastCheckNetworked }
    private var stopRequested = false
    /// The live app's installer state folders, shared with the Self Service controller. Nil in fixtures.
    var installerState: LazyState?
    /// The one row whose single update may be cancelled right now (see `canCancelUpdate`).
    private var cancellablePath: String?
    /// Apps that refused with needs_admin; their rows offer String(localized: "Update (admin)") from then on.
    private var needsAdminPaths: Set<String> = []
    /// The one admin action in progress, so Done can reach it.
    private var currentAdmin: AdminInteraction?
    private var adminToken: UUID?
    /// Opens the App Store (Open in App Store, Update All). Only an explicit click reaches it; the scheduler never
    /// does. Nothing opens unless a production opener is set (`live()` sets one; fixtures keep the inert default).
    @_spi(Testing) public var urlOpener: any ExternalURLOpening = InertURLOpener()
    /// Called once after every check ends, however it was started. Used by the background scheduler.
    var onCheckFinished: ((AppCheckRunOutcome) -> Void)?
    /// Called once a successful check is completely over: installer state refreshed and any queued Update All
    /// released. The scheduler decides there whether an automatic run is due.
    var onSuccessfulCheckSettled: (() -> Void)?

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
        controller.installerState = state
        controller.urlOpener = WorkspaceURLOpener()
        // Patched's own release lookup: never under the test tripwire, and only for an installed build that
        // knows its version.
        if let runningVersion, !RealStateTripwire.isActive {
            controller.selfUpdateCheck = { await PatchedReleaseChecker.check(currentVersion: runningVersion, fetcher: fetcher) }
            // Self-update only for a real Patched.app; a `swift run` build keeps Download only.
            let bundle = Bundle.main
            if bundle.bundlePath.hasSuffix(".app"), bundle.bundleIdentifier == PatchedReleaseKey.bundleID {
                controller.selfInstaller = LiveSelfInstaller(state: state, appPath: bundle.bundlePath, runningVersion: runningVersion)
                controller.selfTerminate = { NSApplication.shared.terminate(nil) }
            }
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
        rows.filter { $0.status == .updateAvailable || $0.status == .appStoreUpdate }.map(availableUpdate(for:))
    }
    private func availableUpdate(for row: AppUpdateRow) -> AvailableUpdate {
        var build = ""
        if case .updateAvailable(let offer)? = row.outcome?.result { build = offer.buildVersion ?? "" }
        return AvailableUpdate(path: row.path, name: row.name, version: row.latestVersion ?? "?", build: build,
                               appStore: row.status == .appStoreUpdate)
    }
    /// The identities (`AvailableUpdate.key`) of the updates an automatic run would attempt right now. Only these
    /// are left out of the "updates available" notification; everything else is announced as usual.
    var automaticallyInstallableKeys: Set<String> {
        Set(updatableRows.filter { $0.isAutomaticallyInstallable }.map { availableUpdate(for: $0).key })
    }
    /// Why an automatic run must wait: work in progress, installing blocked (a broken catalogue or an unreadable
    /// journal), or a confirmation the user has not answered (a "quit and update" question or Patched's own update).
    var automaticRunMustWait: Bool {
        if case .confirming = selfInstall { return true }
        return isWorking || installBlocked || pendingQuit != nil || deferredQuit != nil
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
            // A hidden (ignored) app is never looked up, so it keeps its Hidden row while the check runs instead
            // of reappearing as "Checking…" in the Applications list until its outcome arrives.
            let hidden = Dictionary(self.rowsBeforeCheck.filter(\.isIgnored).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let seeded = scanned.sorted { Self.ordered($0.app.name, $1.app.name) }.map { hidden[$0.app.path] ?? Self.pendingRow($0) }
            self.rows = seeded
            let outcomes: [AppCheckOutcome]
            do { outcomes = try await Self.background { try await checkApps(scanned.map(\.app)) } }
            catch {
                guard self.isCurrentCheck(mine) else { return }
                self.rows = self.rowsBeforeCheck
                self.phase = .idle; self.checkTask = nil
                self.stopSelfLookup()
                self.catalogueError = Self.catalogueMessage(error)
                self.summary = String(localized: "Check stopped: \(self.catalogueError ?? "\(error)")")
                self.onCheckFinished?(.failed)
                self.dropQueuedUpdateAll()
                return
            }
            guard self.isCurrentCheck(mine) else { return }
            let icons = Dictionary(scanned.map { ($0.app.path, $0.icon) }, uniquingKeysWith: { first, _ in first })
            let previous = Dictionary(self.rowsBeforeCheck.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            var refusedOnNetwork = 0, networked = 0
            self.rows = outcomes.sorted { Self.ordered($0.app.name, $1.app.name) }.map { outcome in
                if case .noSource = outcome.result {} else { networked += 1 }
                // Only "couldn't reach the server" counts: an HTTP error (a moved or broken feed) is shown as it is.
                if case .refused(.offline) = outcome.result {
                    refusedOnNetwork += 1
                    // One offline check must not erase what an earlier check found out.
                    if let old = previous[outcome.app.path], Self.keepsPreviousStatus(old, over: outcome) {
                        var kept = old
                        kept.activity = .idle; kept.recheckNote = AppUpdateRow.offlineRecheckNote
                        return kept
                    }
                }
                return self.makeRow(outcome, icon: icons[outcome.app.path] ?? nil)
            }
            self.lastCheckNetworkRefused = refusedOnNetwork; self.lastCheckNetworked = networked
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
            self.onSuccessfulCheckSettled?()
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
        if !updateAll(only: queued.keys, askInWindow: false, onFinished: queued.onFinished) { queued.onDropped?() }
    }

    /// Cancels an in-flight check and puts back the rows shown before it began.
    public func cancelCheck() {
        guard phase == .checking else { return }
        checkTask?.cancel(); checkTask = nil
        stopSelfLookup()
        generation += 1; epoch += 1; pendingQuit = nil
        rows = rowsBeforeCheck
        phase = .idle
        summary = hasChecked ? Self.checkSummary(rows) : String(localized: "Check cancelled.")
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
            case .newer(let release): self.selfUpdate = SelfUpdate(version: release.version, url: release.pageURL, assets: release.assets)
            case .noNews: self.selfUpdate = nil
            case .unavailable: break      // a failed lookup says nothing: keep what was known
            }
            // A confirmation names one version; if the offer changed under it, close it rather than let
            // Update quietly do nothing (or install something the user did not read).
            if case .confirming(let asked) = self.selfInstall, asked != self.selfUpdate?.version { self.selfInstall = .idle }
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

    /// Update is offered beside "Patched X is available" only for a release with a signed zip, in an installed
    /// Patched.app, when nothing else is running.
    public var canInstallSelfUpdate: Bool {
        selfUpdate?.assets != nil && selfInstaller != nil && !selfInstall.isBusy
    }

    /// A click on Update beside "Patched X is available" (menu, Updates, or the button on its notification).
    /// It only asks: nothing is downloaded until `confirmSelfUpdate()`. The scheduler, Update All and the
    /// command line never call it.
    public func requestSelfUpdate() {
        guard let own = selfUpdate, canInstallSelfUpdate else { return }
        selfInstall = .confirming(version: own.version)
    }

    /// Cancel on the confirmation, or dismissing a failure.
    public func cancelSelfUpdate() {
        if selfInstall.isConfirming || selfInstall.isFailed { selfInstall = .idle }
    }

    /// The confirmation's Update: download, verify against the release key, replace the running app, reopen
    /// the new one and quit. Any failure leaves the installed Patched as it was and says why. A release that
    /// would need admin rights opens the release page instead.
    public func confirmSelfUpdate() {
        guard case .confirming(let version) = selfInstall else { return }
        guard let own = selfUpdate, own.version == version, let assets = own.assets, let installer = selfInstaller else {
            selfInstall = .idle; return
        }
        guard phase == .idle, !isWorking else {
            selfInstall = .failed(String(localized: "Patched can't update itself while a check or another update is running. Try again when it has finished."))
            return
        }
        isWorking = true
        epoch += 1; pendingQuit = nil
        selfInstallStarts += 1
        selfInstall = .working(version: version, step: .downloading)
        let release = PatchedRelease(version: version, pageURL: own.url, assets: assets)
        let progress: @Sendable (SelfUpdateStep) -> Void = { [weak self] step in
            Task { @MainActor in
                guard let self, case .working(let v, let current) = self.selfInstall, v == version, step > current else { return }
                self.selfInstall = .working(version: version, step: step)
            }
        }
        selfInstallTask = Task { [weak self] in
            let outcome: Result<SelfUpdateReport, Error>
            do { outcome = .success(try await Self.background { try await installer.install(release, progress: progress) }) }
            catch { outcome = .failure(error) }
            guard let self else { return }
            self.selfInstallTask = nil
            switch outcome {
            case .success(let report):
                self.selfInstall = .reopening(version: version)
                do { try installer.relaunch(report) } catch {
                    self.isWorking = false
                    self.selfInstall = .failed(String(localized: "Patched \(version) is installed. Quit Patched and open it again to use it."))
                    return
                }
                self.selfTerminate()
            case .failure(let error):
                self.isWorking = false
                let refusal = error as? InstallRefusal
                if refusal?.code == "needs_admin" {
                    _ = self.urlOpener.open(own.url)
                    self.selfInstall = .failed(String(localized: "Patched can't replace itself here without admin rights, so the release page is open. Install Patched \(version) from there."))
                } else {
                    self.selfInstall = .failed(Self.selfInstallFailure(refusal, error: error))
                }
            }
        }
    }

    nonisolated static func selfInstallFailure(_ refusal: InstallRefusal?, error: Error) -> String {
        let reason: String
        switch refusal {
        case .releaseSignatureInvalid?: reason = String(localized: "the download isn't signed with Patched's release key")
        case .releaseTeamMismatch?: reason = String(localized: "the download isn't signed with Patched's Developer ID")
        case .releaseCertificateRevoked?: reason = String(localized: "Apple has revoked the download's signing certificate, so it can't be trusted")
        case .releaseCertificateUnchecked?:
            reason = String(localized: "Patched couldn't check the download's certificate with Apple. Check your connection and try again")
        case .cannotPinIdentity?: reason = String(localized: "this copy of Patched has a damaged release Team ID, so it can't check the download. Install the new version from the release page")
        case .download(let detail)?: reason = String(localized: "the download failed (\(detail))")
        case .insecureDownload?: reason = String(localized: "the download went somewhere other than GitHub")
        case .tooLarge?: reason = String(localized: "the download is larger than a Patched release can be")
        case .versionMismatch?, .notNewer?, .bundleNotFound?, .ambiguousBundle?: reason = String(localized: "the download isn't the Patched release it should be")
        case .signatureInvalid?: reason = String(localized: "the new app's code signature didn't verify")
        case .unresolved(let detail)?: return String(localized: "Patched couldn't finish updating and left everything in place: \(detail)")
        case let refusal?: reason = refusal.message
        case nil: reason = "\(error)"
        }
        return String(localized: "Couldn't update Patched: \(reason). Patched is unchanged.")
    }

    /// A click on one row's Update. Only here (and in its quit confirmation) can the admin path be used,
    /// and only for a row that shows String(localized: "Update (admin)") or String(localized: "Update (installer)").
    public func update(id: String) {
        guard let row = row(id: id), canUpdate(row) else { return }
        let admin = mayUseAdmin(row)
        launch { _ = await self.performUpdate(path: id, quit: false, interactive: true, admin: admin, cancellable: true) }
    }

    /// Cancel is offered on a single update while it is downloading or verifying, never once the swap has begun,
    /// and never during Update All (which has Stop) or on the admin and installer-package paths.
    public func canCancelUpdate(_ row: AppUpdateRow) -> Bool {
        guard cancellablePath == row.id, row.activity == .updating, !row.cancelRequested, let progress = row.progress else { return false }
        switch progress {
        case .downloading, .verifying: return true
        case .installing: return false
        }
    }

    /// A click on a row's Cancel. The update stops before anything is swapped: the download and staging folders are
    /// removed and the app is untouched. Does nothing once the commit point has been reached.
    public func cancelUpdate(id: String) {
        guard let row = row(id: id), canCancelUpdate(row) else { return }
        mutate(id) { $0.cancelRequested = true }
        operation?.cancel()
    }

    private func applyProgress(_ progress: UpdateProgress, to path: String) {
        func rank(_ p: UpdateProgress) -> Int {
            switch p { case .downloading: return 0; case .verifying: return 1; case .installing: return 2 }
        }
        mutate(path) { row in
            guard row.activity == .updating, row.progress.map({ rank($0) <= rank(progress) }) ?? true else { return }
            row.progress = progress
        }
    }

    /// Sequential; a failure on one app never stops the rest. Open apps are skipped, not quit.
    /// Each app is rescanned and rechecked just before it is installed. Never passes admin consent.
    /// Only an explicit click (the Updates window, the menu item or the notification's Update All button)
    /// may call this, or the scheduler's automatic run (`automatic: true`, gated on the Automatic updates setting). `onFinished` receives what happened, once, when the run ends.
    /// With `keys` (from a notification) only rows whose current offer is one of those advertised updates are
    /// installed, and each is rechecked to still be that same offer; everything else is left alone.
    /// Returns false when nothing was started.
    @discardableResult
    public func updateAll(onFinished: (@MainActor (UpdateAllSummary) -> Void)? = nil) -> Bool {
        // The Updates window's button: it has an alert, so it asks about the open apps itself.
        updateAll(only: nil, askInWindow: true, onFinished: onFinished)
    }

    @discardableResult
    func updateAll(only keys: Set<String>?, askInWindow: Bool = false, automatic: Bool = false,
                   onFinished: (@MainActor (UpdateAllSummary) -> Void)? = nil) -> Bool {
        updateAllInvocations += 1
        var candidates = updatableRows
        // The automatic run is narrower than Update All: plain installs only. It never opens the App Store, and
        // it names its exclusions again here so they hold even if `updatableRows` ever changes.
        if automatic { candidates = candidates.filter { $0.isAutomaticallyInstallable } }
        if let keys { candidates = candidates.filter { keys.contains(updateKey(of: $0)) } }
        let paths = candidates.map(\.id)
        // App Store updates are never installed here; Update All only opens the App Store for them, once, after
        // the installable updates have run. With nothing installable, that is all it does.
        let storeAtStart = automatic ? 0 : scopedAppStoreCount(keys)
        guard !paths.isEmpty || storeAtStart > 0, !isWorking, phase == .idle, !installBlocked else { return false }
        stopRequested = false
        if paths.isEmpty {
            launch {
                let opened = await self.urlOpener.openAppStoreUpdates()
                self.summary = opened ? String(localized: "\(storeAtStart) to update in the App Store.") : Self.appStoreOpenFailure
                onFinished?(UpdateAllSummary(updated: 0, failed: 0, skippedOpen: 0, needsAdmin: self.knownNeedsAdmin(keys).count,
                                             appStore: opened ? storeAtStart : 0, appStoreFailed: opened ? 0 : storeAtStart))
            }
            return true
        }
        updateAllProgress = UpdateAllProgress(done: 0, total: paths.count, stopping: false)
        launch {
            var updated = 0, failed = 0, skipped = 0, open = 0, stopped = 0, changed = 0
            var adminPaths = Set<String>()
            var openPaths: [String] = []
            for (index, path) in paths.enumerated() {
                if self.stopRequested { stopped = paths.count - index; skipped += stopped; break }
                // Never with admin rights: rows that need them are not in `updatableRows`, and one that turns
                // out to need them is skipped (and marked String(localized: "Update (admin)") when admin updates are on).
                switch await self.performUpdate(path: path, quit: false, interactive: false, admin: false, onlyKeys: keys) {
                case .updated: updated += 1
                case .failed: failed += 1
                case .changed: changed += 1
                case .skippedRunning: skipped += 1; open += 1; openPaths.append(path)
                case .needsAdmin: skipped += 1; adminPaths.insert(path)
                }
                self.updateAllProgress?.done = index + 1
            }
            self.updateAllProgress = nil
            // The App Store, once, after the installs; not when the user chose Stop.
            var store = 0, storeFailed = 0
            let storeNow = (self.stopRequested || automatic) ? 0 : self.scopedAppStoreCount(keys)
            if storeNow > 0 {
                if await self.urlOpener.openAppStoreUpdates() { store = storeNow } else { storeFailed = storeNow }
            }
            self.summary = String(localized: "\(updated) updated") + (failed > 0 ? String(localized: ", \(failed) failed") : "")
                + (skipped > 0 ? String(localized: ", \(skipped) skipped") : "")
                + (store > 0 ? String(localized: ", \(store) to update in the App Store") : "")
                + (storeFailed > 0 ? ". " + Self.appStoreOpenFailure : ".")
            // Admin and installer rows are never installed here, whether known up front or found out, and
            // whether or not experimental admin updates are switched on. Installer-only updates count too.
            // Rows outside a notification's scope are not part of this run's report.
            let known = self.knownNeedsAdmin(keys)
            if self.stopRequested { openPaths = [] }
            // The Updates window asks once, after the run, about the apps that were open; `launch` offers it
            // as soon as the run is over. The epoch is the one `launch` set for this run.
            if askInWindow, !openPaths.isEmpty {
                self.deferredQuit = .init(path: "", action: .updateOpen, paths: openPaths,
                                          message: self.openAppsQuestion(openPaths), epoch: self.epoch, installedVersion: nil)
            }
            onFinished?(UpdateAllSummary(updated: updated, failed: failed, skippedOpen: open,
                                         needsAdmin: adminPaths.union(known).count, stopped: stopped, changed: changed,
                                         appStore: store, appStoreFailed: storeFailed, openPaths: openPaths))
        }
        return true
    }

    /// "Claude is open. Quit it, update and reopen it?" / "Claude and Slack are open. Quit them, ..."
    @_spi(Testing) public static func openAppsQuestion(names: [String]) -> String {
        let list: String
        switch names.count {
        case 0, 1: list = names.first ?? String(localized: "The app")
        case 2: list = String(localized: "\(names[0]) and \(names[1])")
        default: list = String(localized: "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])")
        }
        return names.count <= 1 ? String(localized: "\(list) is open. Quit it, update and reopen it?")
                                : String(localized: "\(list) are open. Quit them, update and reopen them?")
    }
    /// The question for these rows, named as listed.
    public func openAppsQuestion(_ paths: [String]) -> String {
        Self.openAppsQuestion(names: paths.map { row(id: $0)?.name ?? ($0 as NSString).lastPathComponent })
    }

    /// Quits, updates and reopens these apps one at a time, as confirmed by the user (never the scheduler).
    /// Only apps whose row can still be updated are kept. Honours Stop. Returns false when nothing was started.
    @discardableResult
    public func quitAndUpdate(paths requested: [String], onFinished: (@MainActor (UpdateAllSummary) -> Void)? = nil) -> Bool {
        guard !isWorking, phase == .idle, !installBlocked else { return false }
        let paths = requested.filter { path in row(id: path).map(canUpdate) ?? false }
        guard !paths.isEmpty else { return false }
        stopRequested = false
        updateAllProgress = UpdateAllProgress(done: 0, total: paths.count, stopping: false)
        launch {
            var updated = 0, failed = 0, stopped = 0, needsAdmin = 0
            for (index, path) in paths.enumerated() {
                if self.stopRequested { stopped = paths.count - index; break }
                switch await self.performUpdate(path: path, quit: true, interactive: false, admin: false, cancellable: true) {
                case .updated: updated += 1
                case .needsAdmin: needsAdmin += 1
                case .failed, .changed, .skippedRunning: failed += 1
                }
                self.updateAllProgress?.done = index + 1
            }
            self.updateAllProgress = nil
            self.summary = String(localized: "\(updated) updated") + (failed > 0 ? String(localized: ", \(failed) failed") : "")
                + (stopped > 0 ? String(localized: ", \(stopped) skipped") : "") + "."
            onFinished?(UpdateAllSummary(updated: updated, failed: failed, skippedOpen: 0, needsAdmin: needsAdmin, stopped: stopped))
        }
        return true
    }

    static let appStoreOpenFailure = String(localized: "Couldn't open the App Store. Open it and choose Updates.")

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

    /// Whether the row's menu has a Hide item at all; `canIgnore` says whether it is enabled right now.
    public func offersHide(_ row: AppUpdateRow) -> Bool {
        editCatalogue != nil && row.bundleID != nil && !row.isIgnored && !row.isPatchedItself
    }
    public func canIgnore(_ row: AppUpdateRow) -> Bool {
        editCatalogue != nil && row.bundleID != nil && !row.isIgnored && !row.isPatchedItself && canEditIgnore(row)
    }
    public func canStopIgnoring(_ row: AppUpdateRow) -> Bool { editCatalogue != nil && row.isIgnored && canEditIgnore(row) }
    private func canEditIgnore(_ row: AppUpdateRow) -> Bool {
        phase == .idle && !isWorking && catalogueError == nil && row.activity == .idle
    }
    /// Rows the Updates screen lists: everything except apps the user ignores.
    public var updatesRows: [AppUpdateRow] { rows.filter { !$0.isIgnored && !$0.isHiddenBackgroundHelper } }
    /// Rows the Applications screen lists, hidden ones included (its Hidden segment shows them, helpers too, so
    /// each can be unhidden): everything except background-only helpers with no update to show.
    public var applicationsRows: [AppUpdateRow] { rows.filter { !$0.isHiddenBackgroundHelper || $0.isIgnored } }

    /// A click on Hide: writes an ignore entry for the app's bundle ID to the user catalogue, then checks that app again.
    public func ignore(id: String) {
        guard let row = row(id: id), canIgnore(row), let bundleID = row.bundleID else { return }
        editIgnore(row, bundleID: bundleID, ignored: true)
    }
    /// A click on Unhide: removes only that app's ignore entry, then checks the app again.
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
                let text = (ignored ? String(localized: "Couldn't hide \(row.name). ") : String(localized: "Couldn't unhide \(row.name). ")) + failure
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
            staleForOpen(id, String(localized: "\(name) can't be verified before opening. Check again."))
            return
        }
        mutate(id) { $0.result = nil }
        openTask = Task { [weak self] in
            switch await opener.openApplication(atPath: path, expectedBundleID: bundleID, expectedTeamID: team) {
            case .opened: return
            case .changed: self?.staleForOpen(id, String(localized: "\(name) has changed since the last check, so it was not opened. Check again."))
            case .failed: self?.mutate(id) { $0.result = .init(kind: .failure, text: String(localized: "Couldn't open \(name). Open it from your Applications folder.")) }
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
            launch { _ = await self.performUpdate(path: pending.path, quit: true, interactive: false, admin: admin, cancellable: true) }
        case .rollback:
            guard let row = row(id: pending.path), canRollBack(row), row.installedVersion == pending.installedVersion else { return }
            launch { await self.performRollback(path: pending.path, quit: true) }
        case .recover:
            launch { await self.performRecover(quit: true) }
        case .updateOpen:
            quitAndUpdate(paths: pending.paths)
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
        await selfInstallTask?.value
    }

    // MARK: Operations

    private enum StepResult { case updated, failed, skippedRunning, needsAdmin, changed }

    /// Runs one operation with `isWorking` set, so nothing else (a check, Update All, an automatic run, a rollback,
    /// recovery or a Self Service install) can start until it ends. `then` runs once `isWorking` is false again.
    /// Internal so the Self Service controller shares the same busy state.
    func launch(_ work: @escaping @MainActor () async -> Void, then: (@MainActor () -> Void)? = nil) {
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
            then?()
        }
    }

    /// Rescans one app and replaces its row with what is now on disk. When that cannot be done the row is
    /// marked as needing a new check, and its actions stay disabled until it has one.
    private func refreshRow(_ path: String) async {
        let recheck = recheckApp
        do {
            let fresh = try await Self.background { try await recheck(path) }
            guard let old = row(id: path) else { return }
            guard let fresh else { markStale(path, String(localized: "The app is no longer at this location.")); return }
            var row = makeRow(fresh, icon: old.icon)
            row.result = old.result
            row.rollbackVersion = old.rollbackVersion
            row.rollbackUnsupported = old.rollbackUnsupported
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

    private func performUpdate(path: String, quit: Bool, interactive: Bool, admin: Bool, onlyKeys: Set<String>? = nil,
                               cancellable: Bool = false) async -> StepResult {
        guard let shown = row(id: path), shown.outcome != nil else { return .failed }
        mutate(path) { $0.activity = .updating; $0.result = nil; $0.progress = nil; $0.cancelRequested = false }
        // Whatever way this ends, the row stops showing progress and Cancel.
        defer {
            if cancellablePath == path { cancellablePath = nil }
            mutate(path) { $0.progress = nil; $0.cancelRequested = false }
        }
        // Rescan this one app and check it afresh; install only what is still an installable update now.
        let recheck = recheckApp
        let outcome: AppCheckOutcome
        do {
            guard let fresh = try await Self.background({ try await recheck(path) }) else {
                markStale(path, String(localized: "\(shown.name) is no longer at this location. Check again."))
                return .failed
            }
            // A notification-scoped run installs only the very offer that was advertised.
            let inScope = onlyKeys.map { keys in Self.updateKey(fresh).map(keys.contains) ?? false } ?? true
            guard case .updateAvailable = fresh.result, fresh.installable, inScope else {
                var row = makeRow(fresh, icon: shown.icon)
                row.rollbackVersion = shown.rollbackVersion
                row.rollbackUnsupported = shown.rollbackUnsupported
                row.result = .init(kind: .info, text: String(localized: "\(shown.name) changed since the last check, so nothing was installed."))
                replace(row)
                return onlyKeys == nil ? .failed : .changed
            }
            outcome = fresh
            mutate(path) { $0.outcome = fresh }
        } catch {
            catalogueError = Self.catalogueMessage(error)
            markStale(path, String(localized: "\(shown.name): the catalogue could not be read, so nothing was installed."))
            return .failed
        }
        let interaction = admin ? makeAdminInteraction(path: path, name: outcome.app.name) : nil
        defer { if interaction != nil { endAdminInteraction() } }
        // Only the ordinary path reports progress and can be cancelled, and only for a single update.
        let reporting = interaction == nil
        if cancellable && reporting { cancellablePath = path }
        let report: UpdateProgressHandler = { [weak self] step in
            Task { @MainActor in self?.applyProgress(step, to: path) }
        }
        let progress: UpdateProgressHandler? = reporting ? report : nil
        do {
            // The installer enforces `installable` itself as well.
            let report = try await installer.update(outcome, quitIfRunning: quit, admin: interaction, progress: progress)
            mutate(path) {
                $0.result = .init(kind: .success, text: Self.reportText(name: outcome.app.name, report))
                $0.installedVersion = report.toVersion; $0.installedDisplayVersion = nil; $0.status = .needsRecheck; $0.outcome = nil
                $0.progress = nil; $0.cancelRequested = false
            }
            // A Cancel that arrived too late to matter must not spoil the recheck of what is now installed.
            if Task.isCancelled { await Task { @MainActor in await self.refreshRow(path) }.value } else { await refreshRow(path) }
            return .updated
        } catch is CancellationError {
            mutate(path) {
                $0.activity = .idle
                $0.result = .init(kind: .info, text: String(localized: "Cancelled. \(outcome.app.name) was not changed."))
            }
            return .failed
        } catch let refusal as InstallRefusal {
            let name = outcome.app.name
            if case .needsAdmin = refusal, interaction == nil {
                // Needs admin rights whether or not the experimental admin path is on; only with it on does
                // the row offer String(localized: "Update (admin)").
                if adminUpdatesEnabled {
                    needsAdminPaths.insert(path)
                    mutate(path) {
                        $0.activity = .idle; $0.privilege = .admin
                        $0.result = .init(kind: .info, text: String(localized: "\(name) needs admin rights. Choose Update (admin); macOS asks for your password for this one update."))
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
                    deferredQuit = .init(path: path, action: .update, message: String(localized: "\(name) is open. Quit it, update, and reopen it?"),
                                         epoch: epoch, installedVersion: shown.installedVersion)
                }
                mutate(path) {
                    $0.activity = .idle
                    $0.result = .init(kind: .info, text: String(localized: "\(name) is open. Choose Update to quit it, update and reopen it."))
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
                deferredQuit = .init(path: path, action: .rollback, message: String(localized: "\(row.name) is open. Quit it, roll it back, and reopen it?"),
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
        var lines: [String] = result.unreadable.map { String(localized: "journal \($0): unreadable, left in place for inspection") }
        var running = false
        var touched: [String] = []
        for report in result.entries {
            touched.append(report.targetPath)
            switch report.result {
            case .success(let outcome):
                let text: String
                switch outcome {
                case .discarded: text = String(localized: "interrupted before any change; leftovers removed")
                case .completed: text = String(localized: "finished; new version installed, old version backed up")
                case .reverted: text = String(localized: "undone; old version is back in place")
                case .cleanedUp: text = String(localized: "leftover temporary files removed")
                case .removedUnfinishedInstall: text = String(localized: "interrupted Self Service install undone; the unfinished copy was removed")
                case .finishedFreshInstall: text = String(localized: "interrupted Self Service install finished; the app passed every check and was kept")
                }
                lines.append("\((report.targetPath as NSString).lastPathComponent): \(text)")
                if !report.leftovers.isEmpty { lines.append(String(localized: "  could not remove: \(report.leftovers.joined(separator: ", "))")) }
            case .failure(let refusal):
                if case .appRunning = refusal { running = true }
                let appName = ((report.targetPath as NSString).lastPathComponent as NSString).deletingPathExtension
                lines.append("\(appName): " + PlainRefusalText.text(name: appName, refusal))
            }
        }
        if lines.isEmpty { lines = [String(localized: "Nothing to recover.")] }
        recoveryMessage = lines.joined(separator: "\n")
        // Recovery can change which version is installed, so what was checked no longer holds.
        for path in Set(touched) where row(id: path) != nil {
            mutate(path) { $0.status = .needsRecheck; $0.outcome = nil; $0.latestVersion = nil }
            await refreshRow(path)
        }
        if running && !quit {
            deferredQuit = .init(path: "", action: .recover,
                                 message: String(localized: "An app affected by an interrupted update is open. Quit it and finish recovery?"),
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
            let usable = row.bundleID == nil ? nil : match
            rows[index].rollbackUnsupported = usable?.installedByPackage == true
            rows[index].rollbackVersion = usable.flatMap {
                $0.installedByPackage == true ? nil : Self.versionText(short: $0.shortVersion, build: $0.build)
            }
        }
    }

    nonisolated static func catalogueMessage(_ error: Error) -> String {
        let reason = (error as? AppUpdateCatalogueFailure)?.reason ?? "\(error)"
        return catalogueBanner(reason)
    }
    nonisolated static func catalogueBanner(_ reason: String) -> String {
        String(localized: "catalogue.json can't be read: \(reason) — fix or remove it")
    }

    nonisolated static func ordered(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    nonisolated static func versionText(short: String?, build: String?) -> String { InstallTarget.versionText(short, build) }

    nonisolated static func reportText(name: String, _ report: AppUpdateReport) -> String {
        OutcomeText.line(name: name, status: report.status, from: report.fromVersion, to: report.toVersion,
            backupFolder: report.backupFolder, reason: report.leftovers.isEmpty ? nil : "cleanup_incomplete",
            detail: report.leftovers.isEmpty ? nil : "could not remove (use Recover): " + report.leftovers.joined(separator: ", "),
            note: report.note)
    }

    @_spi(Testing) nonisolated public static func refusalResult(name: String, _ refusal: InstallRefusal, format: ArtifactFormat?) -> AppUpdateRow.Result {
        switch refusal {
        case .needsAdmin:
            return .init(kind: .info, text: String(localized: "\(name): \(AppUpdateRow.needsAdminCaption)"))
        case .adminReplaceUnavailable:
            return .init(kind: .info, text: String(localized: "\(name): macOS refused the privileged replacement for this build. Update this app manually."))
        case .unsupportedFormat:
            return .init(kind: .info, text: format == .pkg ? String(localized: "\(name): Installer package updates are turned off")
                                                        : String(localized: "\(name): This download format is not supported yet"))
        default:
            return .init(kind: .failure, text: PlainRefusalText.text(name: name, refusal))
        }
    }

    nonisolated static func pendingRow(_ scanned: AppUpdateScannedApp) -> AppUpdateRow {
        let app = scanned.app
        var row = AppUpdateRow(name: app.name, path: app.path, bundleID: app.bundleID, icon: scanned.icon,
            installedVersion: versionText(short: app.shortVersion, build: app.build), latestVersion: nil,
            source: "—", status: .pending, activity: .checking, result: nil, rollbackVersion: nil, outcome: nil)
        row.isBackgroundOnly = app.isBackgroundOnly
        return row
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
        row.isBackgroundOnly = app.isBackgroundOnly
        return row
    }

    /// A network failure keeps the previous row when that row had settled (an answer from the source or the App Store)
    /// and the app on disk is still the version it was checked at.
    nonisolated static func keepsPreviousStatus(_ old: AppUpdateRow, over outcome: AppCheckOutcome) -> Bool {
        switch old.status {
        case .upToDate, .updateAvailable, .notInstallable, .packageUnsupported, .appStoreUpdate: break
        case .pending, .noSource, .refused, .needsRecheck: return false
        }
        return old.installedVersion == versionText(short: outcome.app.shortVersion, build: outcome.app.build)
    }

    nonisolated static func checkSummary(_ rows: [AppUpdateRow]) -> String {
        let rows = rows.filter { !$0.isIgnored && !$0.isHiddenBackgroundHelper }
        if rows.isEmpty { return String(localized: "No applications found.") }
        let updates = rows.filter { $0.status == .updateAvailable || $0.status == .packageUnsupported || $0.status == .notInstallable
            || $0.status == .appStoreUpdate }.count
        return String(localized: "\(rows.count) apps checked, \(updates) with updates available.")
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
        return String(localized: "Update state folders are unavailable, so updates are disabled.")
    }
}

/// The real self-update: the running Patched.app, the installer's backups folder (resolved on first use).
struct LiveSelfInstaller: SelfInstalling {
    let state: LazyState
    let appPath: String
    let runningVersion: String
    func install(_ release: PatchedRelease, progress: @escaping @Sendable (SelfUpdateStep) -> Void) async throws -> SelfUpdateReport {
        let locations = try state.result.get()
        return try await SelfUpdater(appPath: appPath, runningVersion: runningVersion, backupsRoot: locations.backups)
            .install(release, progress: progress)
    }
    func relaunch(_ report: SelfUpdateReport) throws { try SelfRelaunch.open(appPath: report.appPath) }
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
    func update(_ outcome: AppCheckOutcome, quitIfRunning: Bool, admin: AdminInteraction?,
                progress: UpdateProgressHandler?) async throws -> AppUpdateReport {
        try await real().update(outcome, quitIfRunning: quitIfRunning, admin: admin, progress: progress)
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
