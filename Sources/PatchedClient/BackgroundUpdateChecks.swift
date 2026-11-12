import Foundation
import AppKit
import Combine
import SwiftUI
import UserNotifications
import ServiceManagement
import Security
import UpdateSources
import UpdateInstaller

// Scheduled checks. Patched checks for updates when the app opens, every 3 hours while it runs, and on
// demand. Scheduled and launch checks notify (a notification and a menu-bar count) and otherwise only call
// `check()`. The one exception is the opt-in "Install updates automatically" setting (off by default, and
// possibly set by an organisation). Only `runAutomaticIfDue()` below may install, and only when that setting
// is on, the chosen time has come and no run has happened today. It calls the same `updateAll` as the Update
// All button, in its narrower `automatic` form: no App Store, no installer packages, no admin, no Patched
// itself, no hidden apps and no open apps. Nothing else in this file can install.

// MARK: Seams

/// One available update, as listed in a notification.
public struct AvailableUpdate: Hashable, Sendable {
    public let path: String
    public let name: String
    public let version: String
    /// The offered build number, so a newer build of the same display version is a different update.
    public let build: String
    /// A Mac App Store update: the notification names it separately, and Patched never installs it.
    public let appStore: Bool
    public init(path: String, name: String, version: String, build: String = "", appStore: Bool = false) {
        self.path = path; self.name = name; self.version = version; self.build = build; self.appStore = appStore
    }
    /// Identity of this update for "has the set changed" comparisons: the app, display version and build on offer.
    @_spi(Testing) public var key: String { [path, version, build].joined(separator: "\u{1F}") }
}

/// Posts the "updates available" notification. Authorisation is requested lazily by the implementation,
/// the first time it is asked to notify, never at launch. `completion(true)` means the notification was
/// actually submitted; it is `false` when permission is denied or posting failed, so the scheduler does not
/// treat those updates as announced.
@MainActor public protocol UpdateNotifying: AnyObject {
    func notify(updates: [AvailableUpdate], completion: @escaping @MainActor (Bool) -> Void)
    /// "Patched 0.2.0 is available". One call per new version; clicking it opens the Updates view only, and
    /// its Update… button (installable releases only) opens Updates with the confirmation showing.
    func notify(selfUpdate: SelfUpdate, completion: @escaping @MainActor (Bool) -> Void)
}

extension UpdateNotifying {
    /// Notifiers that do not announce Patched's own releases say nothing.
    public func notify(selfUpdate: SelfUpdate, completion: @escaping @MainActor (Bool) -> Void) { completion(false) }
}

@MainActor public protocol CancellableToken: AnyObject { func cancel() }

/// A one-shot timer seam.
@MainActor public protocol CheckTimerScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> any CancellableToken
}

/// Tells the scheduler the Mac woke from sleep.
@MainActor public protocol WakeEventSourcing: AnyObject {
    func observe(_ handler: @escaping @MainActor () -> Void) -> any CancellableToken
}

/// Remembers when the last check ran and which updates the user has already been told about.
@MainActor public protocol BackgroundCheckStoring: AnyObject {
    var lastCheck: Date? { get set }
    var notifiedKeys: Set<String> { get set }
}

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound
    /// The running Patched is ad-hoc signed (no Team ID). `SMAppService` needs a properly signed app, so the
    /// setting is shown greyed out and nothing is registered.
    case needsDeveloperID
}

/// `SMAppService.mainApp` behind a seam, so tests never register a real login item.
@MainActor public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

// MARK: Scheduler

@MainActor public final class UpdateCheckScheduler {
    public static let interval: TimeInterval = 3 * 60 * 60
    /// A launch check is skipped when a check ran less than this long ago.
    public static let launchSkipWindow: TimeInterval = 10 * 60
    /// After waking, wait this long (for the network to come back) before deciding whether a check is due.
    public static let wakeDelay: TimeInterval = 20
    /// How long to wait before trying again when an install or rollback is in progress.
    public static let deferDelay: TimeInterval = 5 * 60
    /// After a check that mostly could not reach the network, look again after this long instead of the full interval.
    public static let offlineRetryDelay: TimeInterval = 10 * 60

    private enum Origin { case launch, interval, deferred }

    private let controller: AppUpdatesController
    private let now: () -> Date
    private let timer: any CheckTimerScheduling
    private let notifier: any UpdateNotifying
    private let wake: any WakeEventSourcing
    private let store: any BackgroundCheckStoring
    private let automatic: AutomaticUpdateSettings?
    private let summaryNotifier: (any UpdateSummaryNotifying)?
    private let calendar: Calendar
    private var automaticRetryToken: (any CancellableToken)?
    private var timerToken: (any CancellableToken)?
    private var wakeToken: (any CancellableToken)?
    private var ownCheckInFlight = false
    /// Set after a successful check until Patched's own release has been judged: whether to notify.
    private var pendingSelfSettle: Bool?
    /// Set when Patched was reopened by its own self-update: the first check runs even if the previous copy
    /// checked minutes ago, so the new version's list is never empty. Cleared once that check starts.
    private var checkDespiteRecentCheck = false
    public private(set) var started = false

    public init(controller: AppUpdatesController, now: @escaping () -> Date, timer: any CheckTimerScheduling,
                notifier: any UpdateNotifying, wake: any WakeEventSourcing, store: any BackgroundCheckStoring,
                automatic: AutomaticUpdateSettings? = nil, summaryNotifier: (any UpdateSummaryNotifying)? = nil,
                calendar: Calendar = .autoupdatingCurrent) {
        self.controller = controller; self.now = now; self.timer = timer
        self.notifier = notifier; self.wake = wake; self.store = store
        self.automatic = automatic; self.summaryNotifier = summaryNotifier; self.calendar = calendar
    }

    /// Begins the schedule: one check now (unless one ran in the last 10 minutes, or always after a
    /// self-update relaunch), then every 3 hours.
    public func start(afterSelfUpdate: Bool = false) {
        guard !started else { return }
        started = true
        checkDespiteRecentCheck = afterSelfUpdate
        controller.onCheckFinished = { [weak self] outcome in self?.finished(outcome) }
        controller.onSelfLookupFinished = { [weak self] in self?.settleSelfUpdateWhenReady() }
        controller.onSuccessfulCheckSettled = { [weak self] in self?.runAutomaticIfDue() }
        wakeToken = wake.observe { [weak self] in self?.woke() }
        attempt(.launch)
    }

    public func stop() {
        started = false
        timerToken?.cancel(); timerToken = nil
        wakeToken?.cancel(); wakeToken = nil
        controller.onCheckFinished = nil
        controller.onSelfLookupFinished = nil
        controller.onSuccessfulCheckSettled = nil
        automaticRetryToken?.cancel(); automaticRetryToken = nil
        pendingSelfSettle = nil
        // A check still running will finish unobserved; do not let its ownership outlive this run.
        ownCheckInFlight = false
    }

    // Seconds since the last check; nil when none is recorded. A clock set back reads as "long ago".
    private func age() -> TimeInterval? {
        guard let last = store.lastCheck else { return nil }
        let elapsed = now().timeIntervalSince(last)
        return elapsed < 0 ? .infinity : elapsed
    }

    private func arm(after seconds: TimeInterval? = nil) {
        timerToken?.cancel()
        let delay = seconds ?? max(1, min(Self.interval, Self.interval - (age() ?? Self.interval)))
        timerToken = timer.schedule(after: delay) { [weak self] in self?.evaluate() }
    }

    /// Wall-clock decision: check if 3 hours have passed since the last check, else wait for the rest.
    private func evaluate() {
        guard started else { return }
        if let age = age(), age < Self.interval { arm(); return }
        attempt(.interval)
    }

    private func woke() {
        guard started else { return }
        timerToken?.cancel()
        timerToken = timer.schedule(after: Self.wakeDelay) { [weak self] in self?.evaluate() }
    }

    private func attempt(_ origin: Origin) {
        guard started else { return }
        if origin != .interval, !checkDespiteRecentCheck, let age = age(), age < Self.launchSkipWindow { arm(); return }
        // One check at a time: a check already running (ours or the user's) will re-arm the timer when it ends.
        guard !ownCheckInFlight, controller.phase == .idle else { return }
        // Never overlap an install, rollback or recovery; look again shortly.
        guard !controller.isWorking else {
            timerToken?.cancel()
            timerToken = timer.schedule(after: Self.deferDelay) { [weak self] in self?.attempt(.deferred) }
            return
        }
        store.lastCheck = now()
        ownCheckInFlight = true
        checkDespiteRecentCheck = false
        controller.check()
        if controller.phase != .checking {
            // The controller refused (for example a broken catalogue). Retry at the next interval.
            ownCheckInFlight = false
            arm()
        }
    }

    private func finished(_ outcome: AppCheckRunOutcome) {
        guard started else { return }
        let mine = ownCheckInFlight
        ownCheckInFlight = false
        // A check the user started counts as the latest check too.
        if !mine { store.lastCheck = now() }
        // A check that was mostly offline says little: ask again soon. Backdating the stamp makes the timer's
        // wall-clock decision agree with the short wait.
        if outcome == .succeeded, controller.lastCheckMostlyOffline {
            store.lastCheck = now().addingTimeInterval(-(Self.interval - Self.offlineRetryDelay))
        }
        // The updates an automatic run is about to attempt are not announced (its summary follows). Every other
        // update, including ones the run leaves out, is announced as usual.
        let attempted = automaticRunWouldStart() ? controller.automaticallyInstallableKeys : []
        if outcome == .succeeded { settle(notify: mine, unannounced: attempted); pendingSelfSettle = mine; settleSelfUpdateWhenReady() }
        else { pendingSelfSettle = nil }
        arm()
    }

    // MARK: Automatic updates

    /// Setting on, chosen time reached (within 6 hours and before midnight), none yet today, and the last check was not mostly offline.
    private func automaticRunWouldStart() -> Bool {
        guard let automatic else { return false }
        automatic.refresh()
        return automatic.isEnabled && !controller.lastCheckMostlyOffline
            && AutomaticUpdateSchedule.isDue(now: now(), time: automatic.time, lastRunDay: automatic.lastRunDay, calendar: calendar)
    }

    /// The only place the scheduler installs anything. Runs after a successful check, once a day.
    private func runAutomaticIfDue() {
        guard started, let automatic, automaticRunWouldStart() else { return }
        // A check (the user's, say) is running: its own end comes back here.
        guard controller.phase == .idle else { return }
        // Never during an install, rollback or recovery, with installing blocked, or over an open confirmation:
        // look again shortly, while the window lasts. Nothing is recorded, so the day is not spent.
        guard !controller.automaticRunMustWait else {
            automaticRetryToken?.cancel()
            automaticRetryToken = timer.schedule(after: Self.deferDelay) { [weak self] in self?.runAutomaticIfDue() }
            return
        }
        automaticRetryToken?.cancel(); automaticRetryToken = nil
        // Recorded as the run starts, so a relaunch the same day, or a second check, never runs it again.
        automatic.lastRunDay = AutomaticUpdateSchedule.dayKey(now(), calendar: calendar)
        let notifier = summaryNotifier
        controller.updateAll(only: nil, askInWindow: false, automatic: true) { summary in
            // Quiet when nothing was installed, failed or skipped for being open.
            guard summary.updated + summary.failed + summary.skippedOpen > 0 else { return }
            notifier?.notify(automaticSummary: summary)
        }
    }

    private static let ownPrefix = "im.patched.self-update\u{1F}"

    /// Patched's own release is judged once the app check has finished and its lookup has answered, whichever is later.
    private func settleSelfUpdateWhenReady() {
        guard started, let shouldNotify = pendingSelfSettle, !controller.selfLookupPending, controller.phase == .idle else { return }
        pendingSelfSettle = nil
        settleSelfUpdate(notify: shouldNotify)
    }

    /// One notification per version, and only for a version strictly newer than any already announced. The highest
    /// announced version is remembered even while no release is showing, so a release that disappears and returns
    /// is not announced twice. A check the user started counts as the user having seen it.
    private var selfVersionInFlight: String?

    private func settleSelfUpdate(notify shouldNotify: Bool) {
        guard let own = controller.selfUpdate else { return }
        let known = store.notifiedKeys.filter { $0.hasPrefix(Self.ownPrefix) }.map { String($0.dropFirst(Self.ownPrefix.count)) }
        let highest = known.max { VersionComparator.compare($0, $1) == .orderedAscending }
        if let highest, !VersionComparator.isNewer(own.version, than: highest) { return }
        if !shouldNotify { rememberSelf(own.key); return }
        // A delivery still waiting (e.g. on the first permission prompt) is not posted a second time.
        guard selfVersionInFlight != own.version else { return }
        selfVersionInFlight = own.version
        notifier.notify(selfUpdate: own) { [weak self] delivered in
            guard let self else { return }
            if self.selfVersionInFlight == own.version { self.selfVersionInFlight = nil }
            if delivered { self.rememberSelf(own.key) }
        }
    }

    /// Keeps only the highest version ever remembered, so a late completion for an older release can't lower it.
    private func rememberSelf(_ key: String) {
        let existing = store.notifiedKeys.filter { $0.hasPrefix(Self.ownPrefix) }
        let version = String(key.dropFirst(Self.ownPrefix.count))
        if existing.contains(where: { !VersionComparator.isNewer(version, than: String($0.dropFirst(Self.ownPrefix.count))) }) { return }
        store.notifiedKeys = store.notifiedKeys.subtracting(existing).union([key])
    }

    /// Only a changed set of available updates produces a notification. Failed or cancelled checks never do.
    private func settle(notify shouldNotify: Bool, unannounced: Set<String> = []) {
        let rows = controller.rows
        // Updates an automatic run will attempt stay un-announced: if one fails or is skipped as open, a later check can still tell the user.
        let current = controller.availableUpdates.filter { !unannounced.contains($0.key) }
        let currentKeys = Set(current.map(\.key))
        var previous = store.notifiedKeys
        // Patched's own release has its own bookkeeping (`settleSelfUpdate`); its keys are left alone here.
        let ownKeys = previous.filter { $0.hasPrefix(Self.ownPrefix) }
        previous.subtract(ownKeys)
        // An attempted update that was announced before stays announced, so an app that is always open at the chosen
        // time is not announced again after every day's run; the run's summary already says it was skipped.
        let announcedBefore = previous.intersection(unannounced)
        // An app that could not be checked this time keeps its record, so a flaky network does not re-notify.
        let unsettled = Set(rows.compactMap { row -> String? in
            if case .refused = row.status { return row.path }
            return nil
        })
        let retained = previous.filter { key in unsettled.contains(String(key.split(separator: "\u{1F}", omittingEmptySubsequences: false).first ?? "")) }
        guard shouldNotify, !currentKeys.subtracting(previous).isEmpty else {
            store.notifiedKeys = retained.union(currentKeys).union(ownKeys).union(announcedBefore)
            return
        }
        // New updates count as announced only once the notification was really submitted, so a denied or
        // failed notification is tried again at the next check (for example after permission is granted).
        store.notifiedKeys = retained.union(currentKeys.intersection(previous)).union(ownKeys).union(announcedBefore)
        let sorted = current.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        notifier.notify(updates: sorted) { [weak self] delivered in
            if delivered { self?.store.notifiedKeys.formUnion(currentKeys) }
        }
    }
}

// MARK: Open at login

@MainActor public final class OpenAtLoginController: ObservableObject {
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var errorText: String?
    private let item: any LoginItemControlling

    public init(item: any LoginItemControlling) { self.item = item; status = item.status }

    /// On while registered, or registered but waiting for approval in System Settings.
    public var isOn: Bool { status == .enabled || status == .requiresApproval }
    public var needsApproval: Bool { status == .requiresApproval }
    /// Greyed out outside the installed app and for an ad-hoc signed build.
    public var isAvailable: Bool { status != .notFound && status != .needsDeveloperID }

    public var statusText: String {
        if let errorText { return errorText }
        switch status {
        case .enabled: return String(localized: "Patched opens when you log in.")
        case .notRegistered: return String(localized: "Patched does not open when you log in.")
        case .requiresApproval:
            return String(localized: "Approve Patched in System Settings > General > Login Items to finish turning this on.")
        case .notFound: return String(localized: "Open at login is only available from the installed Patched.app.")
        case .needsDeveloperID:
            return String(localized: "Open at login needs a copy of Patched signed with a Developer ID. This copy is ad-hoc signed, so macOS won't keep it as a login item.")
        }
    }

    public func refresh() { status = item.status }

    public func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        errorText = nil
        do { if on { try item.register() } else { try item.unregister() } }
        catch { errorText = String(localized: "Couldn't change Open at login: \(error.localizedDescription)") }
        refresh()
    }

    public func openSystemSettings() { item.openSystemSettings() }
}

// MARK: Production implementations

/// The running process's own code signature (dynamic code, `SecCodeCopySelf`), not whatever is on disk at its path.
@_spi(Testing) public enum RunningCodeSignature {
    /// The Team ID, or nil when this process is unsigned or ad-hoc signed.
    public static func teamID() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        // SecCodeCopySigningInformation takes dynamic code as well as static code (SecCode is a SecStaticCode in C);
        // Swift imports them as separate types, so the dynamic reference is passed as is.
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }
}

var runsFromAppBundle: Bool {
    Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
}

/// `SMAppService.mainApp` itself, behind a seam so the checks can drive `SystemLoginItem` without registering anything.
@MainActor public protocol MainAppServicing: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// The real `SMAppService.mainApp` (macOS 13 and later).
@MainActor public final class SystemMainAppService: MainAppServicing {
    public init() {}
    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Lazily touches `SMAppService`, and only from an installed .app bundle. An ad-hoc build (no Team ID in the
/// running process's own code signature) cannot register: it is `.needsDeveloperID` unless the service says it
/// is already registered (for example by an earlier signed copy), in which case that is shown and it can
/// still be turned off.
@MainActor public final class SystemLoginItem: LoginItemControlling {
    private let inAppBundle: () -> Bool
    private let readTeamID: () -> String?
    private let service: any MainAppServicing
    private var cachedSigned: Bool?

    /// Production: this process's own bundle and signature, and `SMAppService.mainApp`.
    public convenience init() {
        self.init(inAppBundle: { runsFromAppBundle },
                  teamID: { RunningCodeSignature.teamID() },
                  service: SystemMainAppService())
    }

    @_spi(Testing) public init(inAppBundle: @escaping () -> Bool, teamID: @escaping () -> String?, service: any MainAppServicing) {
        self.inAppBundle = inAppBundle; self.readTeamID = teamID; self.service = service
    }

    /// Whether the running app's own signature carries a Team ID. Read once: it cannot change while it runs.
    private var isTeamSigned: Bool {
        if let cachedSigned { return cachedSigned }
        let signed = readTeamID().map { !$0.isEmpty } ?? false
        cachedSigned = signed
        return signed
    }

    public var status: LoginItemStatus {
        guard inAppBundle() else { return .notFound }
        if isTeamSigned { return service.status }
        let registered = service.status
        return registered == .enabled || registered == .requiresApproval ? registered : .needsDeveloperID
    }
    /// Only a Team ID signed build registers.
    public func register() throws {
        guard inAppBundle(), isTeamSigned else { return }
        try service.register()
    }
    /// Always allowed from the app, so a login item can never be stuck on.
    public func unregister() throws {
        guard inAppBundle() else { return }
        try service.unregister()
    }
    public func openSystemSettings() { service.openSystemSettingsLoginItems() }
}

@MainActor private final class TimerToken: CancellableToken {
    var timer: Timer?
    func cancel() { timer?.invalidate(); timer = nil }
}

@MainActor public final class SystemCheckTimer: CheckTimerScheduling {
    public init() {}
    public func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> any CancellableToken {
        let token = TimerToken()
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        timer.tolerance = min(60, seconds * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        token.timer = timer
        return token
    }
}

@MainActor private final class ObserverToken: CancellableToken {
    var observer: NSObjectProtocol?
    func cancel() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}

@MainActor public final class SystemWakeSource: WakeEventSourcing {
    public init() {}
    public func observe(_ handler: @escaping @MainActor () -> Void) -> any CancellableToken {
        let token = ObserverToken()
        token.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return token
    }
}

/// UserDefaults-backed. Under the test tripwire it keeps everything in memory instead.
@MainActor public final class DefaultsCheckStore: BackgroundCheckStoring {
    private static let lastKey = "im.patched.lastUpdateCheck"
    private static let notifiedKey = "im.patched.notifiedUpdates"
    private var memoryLast: Date?
    private var memoryNotified: Set<String> = []
    private var useMemory: Bool { RealStateTripwire.isActive }
    public init() {}
    public var lastCheck: Date? {
        get {
            if useMemory { return memoryLast }
            let value = UserDefaults.standard.double(forKey: Self.lastKey)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if useMemory { memoryLast = newValue; return }
            UserDefaults.standard.set(newValue?.timeIntervalSince1970, forKey: Self.lastKey)
        }
    }
    public var notifiedKeys: Set<String> {
        get {
            if useMemory { return memoryNotified }
            return Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
        }
        set {
            if useMemory { memoryNotified = newValue; return }
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.notifiedKey)
        }
    }
}

/// Never registers anything; used where no real login item may be touched.
@MainActor public final class UnavailableLoginItem: LoginItemControlling {
    public init() {}
    public var status: LoginItemStatus { .notFound }
    public func register() throws {}
    public func unregister() throws {}
    public func openSystemSettings() {}
}

// MARK: Wiring

extension UpdateCheckScheduler {
    /// The real timer, wake notification and stored state. Nothing is touched until `start()`.
    static func system(controller: AppUpdatesController, notifier: SystemUpdateNotifier,
                       automatic: AutomaticUpdateSettings) -> UpdateCheckScheduler {
        UpdateCheckScheduler(controller: controller, now: { Date() }, timer: SystemCheckTimer(),
                             notifier: notifier, wake: SystemWakeSource(), store: DefaultsCheckStore(),
                             automatic: automatic, summaryNotifier: notifier)
    }
}

extension OpenAtLoginController {
    static func system() -> OpenAtLoginController { OpenAtLoginController(item: SystemLoginItem()) }
}

extension NativeClientSession {
    public var backgroundChecksRunning: Bool { backgroundChecks?.started == true }

    /// Starts the schedule: a check now (unless one ran in the last 10 minutes; always when this
    /// copy was reopened by a self-update), then every 3 hours. Scheduled checks only notify. `showMainWindow` brings the window forward when a notification is
    /// clicked. Safe to call more than once; does nothing for a fixture session.
    public func startBackgroundChecks(showMainWindow: @escaping @MainActor () -> Void) {
        guard let backgroundChecks, !backgroundChecks.started else { return }
        let openUpdates: @MainActor () -> Void = { [weak self] in
            self?.navigation.select(.updates)
            showMainWindow()
        }
        updateNotifier?.onOpenUpdates = openUpdates
        wireNotificationActions(openUpdates: openUpdates)
        wireSelfUpdateAction(openUpdates: openUpdates)
        updateNotifier?.activate()
        backgroundChecks.start(afterSelfUpdate: SelfRelaunch.pidToAwait(in: CommandLine.arguments) != nil)
    }
}

/// Starts the background schedule when the modified view first appears (the menu-bar item, at launch).
private struct StartsBackgroundChecks: ViewModifier {
    let session: NativeClientSession
    let showMainWindow: @MainActor () -> Void
    func body(content: Content) -> some View {
        content.task { session.startBackgroundChecks(showMainWindow: showMainWindow) }
    }
}

extension View {
    public func startsBackgroundChecks(session: NativeClientSession,
                                       showMainWindow: @escaping @MainActor () -> Void) -> some View {
        modifier(StartsBackgroundChecks(session: session, showMainWindow: showMainWindow))
    }
}
