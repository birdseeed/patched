import Foundation
import AppKit
import Combine
import SwiftUI
import UserNotifications
import ServiceManagement
import UpdateSources

// Scheduled checks. Patched checks for updates when the app opens, every 3 hours while it runs, and on
// demand. Scheduled and launch checks only notify (a notification and a menu-bar count). Nothing here
// can install: the scheduler holds an `AppUpdatesController` but only ever calls `check()`.

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

public enum LoginItemStatus: Equatable, Sendable { case notRegistered, enabled, requiresApproval, notFound }

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
    private var timerToken: (any CancellableToken)?
    private var wakeToken: (any CancellableToken)?
    private var ownCheckInFlight = false
    /// Set after a successful check until Patched's own release has been judged: whether to notify.
    private var pendingSelfSettle: Bool?
    public private(set) var started = false

    public init(controller: AppUpdatesController, now: @escaping () -> Date, timer: any CheckTimerScheduling,
                notifier: any UpdateNotifying, wake: any WakeEventSourcing, store: any BackgroundCheckStoring) {
        self.controller = controller; self.now = now; self.timer = timer
        self.notifier = notifier; self.wake = wake; self.store = store
    }

    /// Begins the schedule: one check now (unless one ran in the last 10 minutes), then every 3 hours.
    public func start() {
        guard !started else { return }
        started = true
        controller.onCheckFinished = { [weak self] outcome in self?.finished(outcome) }
        controller.onSelfLookupFinished = { [weak self] in self?.settleSelfUpdateWhenReady() }
        wakeToken = wake.observe { [weak self] in self?.woke() }
        attempt(.launch)
    }

    public func stop() {
        started = false
        timerToken?.cancel(); timerToken = nil
        wakeToken?.cancel(); wakeToken = nil
        controller.onCheckFinished = nil
        controller.onSelfLookupFinished = nil
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
        if origin != .interval, let age = age(), age < Self.launchSkipWindow { arm(); return }
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
        if outcome == .succeeded { settle(notify: mine); pendingSelfSettle = mine; settleSelfUpdateWhenReady() }
        else { pendingSelfSettle = nil }
        arm()
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
    private func settle(notify shouldNotify: Bool) {
        let rows = controller.rows
        let current = controller.availableUpdates
        let currentKeys = Set(current.map(\.key))
        var previous = store.notifiedKeys
        // Patched's own release has its own bookkeeping (`settleSelfUpdate`); its keys are left alone here.
        let ownKeys = previous.filter { $0.hasPrefix(Self.ownPrefix) }
        previous.subtract(ownKeys)
        // An app that could not be checked this time keeps its record, so a flaky network does not re-notify.
        let unsettled = Set(rows.compactMap { row -> String? in
            if case .refused = row.status { return row.path }
            return nil
        })
        let retained = previous.filter { key in unsettled.contains(String(key.split(separator: "\u{1F}", omittingEmptySubsequences: false).first ?? "")) }
        guard shouldNotify, !currentKeys.subtracting(previous).isEmpty else {
            store.notifiedKeys = retained.union(currentKeys).union(ownKeys)
            return
        }
        // New updates count as announced only once the notification was really submitted, so a denied or
        // failed notification is tried again at the next check (for example after permission is granted).
        store.notifiedKeys = retained.union(currentKeys.intersection(previous)).union(ownKeys)
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
    public var isAvailable: Bool { status != .notFound }

    public var statusText: String {
        if let errorText { return errorText }
        switch status {
        case .enabled: return "Patched opens when you log in."
        case .notRegistered: return "Patched does not open when you log in."
        case .requiresApproval:
            return "Approve Patched in System Settings > General > Login Items to finish turning this on."
        case .notFound: return "Open at login is only available from the installed Patched.app."
        }
    }

    public func refresh() { status = item.status }

    public func setEnabled(_ on: Bool) {
        errorText = nil
        do { if on { try item.register() } else { try item.unregister() } }
        catch { errorText = "Couldn't change Open at login: \(error.localizedDescription)" }
        refresh()
    }

    public func openSystemSettings() { item.openSystemSettings() }
}

// MARK: Production implementations

var runsFromAppBundle: Bool {
    Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
}

/// Lazily touches `SMAppService`, and only from an installed .app bundle.
@MainActor public final class SystemLoginItem: LoginItemControlling {
    public init() {}
    public var status: LoginItemStatus {
        guard runsFromAppBundle else { return .notFound }
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
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
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
    static func system(controller: AppUpdatesController, notifier: any UpdateNotifying) -> UpdateCheckScheduler {
        UpdateCheckScheduler(controller: controller, now: { Date() }, timer: SystemCheckTimer(),
                             notifier: notifier, wake: SystemWakeSource(), store: DefaultsCheckStore())
    }
}

extension OpenAtLoginController {
    static func system() -> OpenAtLoginController { OpenAtLoginController(item: SystemLoginItem()) }
}

extension NativeClientSession {
    public var backgroundChecksRunning: Bool { backgroundChecks?.started == true }

    /// Starts the schedule: a check now (unless one ran in the last 10 minutes), then every 3 hours.
    /// Scheduled checks only notify. `showMainWindow` brings the window forward when a notification is
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
        backgroundChecks.start()
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
