import Foundation
import Combine

// Explicit-click entry points to Update All besides the Updates window: the menu-bar item and the
// "Update All" button on the updates-available notification. Both end in the same
// `AppUpdatesController.updateAll()`, which rescans and rechecks each app before installing, skips open
// apps (never quits them), never passes admin consent and refuses while checking, working or blocked.
// The scheduler never reaches this file: it holds only `check()`.

/// What the Patched menu shows for Update All.
public struct UpdateAllMenuState: Equatable, Sendable {
    /// Nothing to offer (no installable or App Store updates waiting, no run in progress, nothing queued): no Update All row.
    public let visible: Bool
    /// "Update All (5)": every update Update All acts on, App Store ones included.
    public let title: String
    /// "4 here, 1 via the App Store" when App Store updates are included, because Update All only opens the
    /// App Store for those and installs the rest itself. Nil when all of them install here.
    public let detail: String?
    public let enabled: Bool
    /// Why the item is disabled, in a few words.
    public let reason: String?
    /// "Updating 2 of 5…" while a run is in progress, or the queued notice.
    public let progressText: String?
    /// "Stop Updating" is shown (and, until Stop is chosen, enabled) while a run is in progress.
    public let showsStop: Bool
    public let stopEnabled: Bool
    /// A request is waiting for a check; "Cancel" is shown instead of the Update All item.
    public let showsCancelQueued: Bool

    static let hidden = UpdateAllMenuState(visible: false, title: "", detail: nil, enabled: false, reason: nil,
                                           progressText: nil, showsStop: false, stopEnabled: false, showsCancelQueued: false)
    public static let queuedText = "Update All queued, waiting for the check"
}

extension AppUpdatesController {
    /// The menu title for an installable count and an App Store count: one total, never two competing numbers.
    static func updateAllTitle(installable: Int, appStore: Int) -> String {
        "Update All (\(installable + appStore))"
    }
    static func updateAllDetail(installable: Int, appStore: Int) -> String? {
        guard appStore > 0 else { return nil }
        return installable > 0 ? "\(installable) here, \(appStore) via the App Store" : "\(appStore) via the App Store"
    }

    public var updateAllMenu: UpdateAllMenuState {
        if let progress = updateAllProgress {
            return UpdateAllMenuState(visible: true, title: Self.updateAllTitle(installable: updateAllCount, appStore: appStoreUpdateCount),
                                      detail: Self.updateAllDetail(installable: updateAllCount, appStore: appStoreUpdateCount), enabled: false,
                                      reason: nil, progressText: progress.text, showsStop: true,
                                      stopEnabled: !progress.stopping, showsCancelQueued: false)
        }
        if updateAllQueued {
            return UpdateAllMenuState(visible: true, title: "Update All", detail: nil, enabled: false, reason: nil,
                                      progressText: UpdateAllMenuState.queuedText, showsStop: false,
                                      stopEnabled: false, showsCancelQueued: true)
        }
        let count = updateAllCount, store = appStoreUpdateCount
        guard count > 0 || store > 0 else { return .hidden }
        var reason: String?
        if phase == .checking { reason = "Checking for updates…" }
        else if isWorking { reason = "Another update is in progress" }
        else if installBlocked { reason = "Updates are paused. See the Updates window." }
        return UpdateAllMenuState(visible: true, title: Self.updateAllTitle(installable: count, appStore: store),
                                  detail: Self.updateAllDetail(installable: count, appStore: store), enabled: reason == nil, reason: reason,
                                  progressText: nil, showsStop: false, stopEnabled: false, showsCancelQueued: false)
    }
}

/// Posts the one summary notification after an Update All run started from the menu or the notification.
/// Never asks for permission: it posts only when notifications are already authorised.
@MainActor public protocol UpdateSummaryNotifying: AnyObject {
    func notify(summary: UpdateAllSummary)
}

/// Routes the menu item and the notification action to `AppUpdatesController.updateAll()`.
/// Neither opens the Updates window (nothing steals focus; progress is in the menu, the result in one
/// summary notification), and tapping the notification body still only opens the Updates screen.
@MainActor public final class UpdateAllEntryPoint {
    private let controller: AppUpdatesController
    private let summaryNotifier: (any UpdateSummaryNotifying)?
    /// Opens the Updates window; used when a notification's Update All cannot or need not run.
    public var openUpdates: (@MainActor () -> Void)?

    public init(controller: AppUpdatesController, summaryNotifier: (any UpdateSummaryNotifying)?) {
        self.controller = controller; self.summaryNotifier = summaryNotifier
    }

    public var menu: UpdateAllMenuState { controller.updateAllMenu }

    /// The menu item: acts on every installable row as listed now (the menu shows the count). Each app is
    /// rechecked just before it is installed. While a check is running the request waits for it to succeed.
    public func requestUpdateAll() { request(only: nil) }

    /// The notification's Update All button. `keys` are the updates that notification advertised: only those
    /// still installable after the normal recheck are installed. With none left, nothing is installed and the
    /// Updates window opens. A button press on a fresh launch (no result yet), or during a check, waits for a
    /// check that succeeds; if that check fails or is cancelled the request is dropped and Updates opens.
    public func requestUpdateAll(only keys: Set<String>) { request(only: keys) }

    public func requestStop() {
        controller.cancelQueuedUpdateAll()
        controller.stopUpdateAll()
    }

    private func request(only keys: Set<String>?) {
        let notifier = summaryNotifier
        let finished: @MainActor (UpdateAllSummary) -> Void = { notifier?.notify(summary: $0) }
        let open: @MainActor () -> Void = { [weak self] in self?.openUpdates?() }
        let dropped: (@MainActor () -> Void)? = keys == nil ? nil : open
        if controller.phase == .checking {
            controller.queueUpdateAll(only: keys, onFinished: finished, onDropped: dropped)
            return
        }
        if keys != nil, !controller.hasChecked {
            // Nothing to act on yet (fresh launch): get a result first.
            controller.queueUpdateAll(only: keys, onFinished: finished, onDropped: dropped)
            controller.check()
            if controller.phase != .checking { controller.cancelQueuedUpdateAll(); openUpdates?() }
            return
        }
        if !controller.updateAll(only: keys, onFinished: finished) { dropped?() }
    }
}

extension NativeClientSession {
    /// Sends the notification's Update All button to the entry point. Called when background checks start.
    func wireNotificationActions(openUpdates: @escaping @MainActor () -> Void) {
        updateAllEntry.openUpdates = openUpdates
        updateNotifier?.onUpdateAll = { [weak self] keys in self?.updateAllEntry.requestUpdateAll(only: keys) }
    }
}

extension NativeClientSession {
    /// The self-update notification's Update… button: open Updates and ask for confirmation. It never installs;
    /// installing needs a separate click on the confirmation itself.
    func wireSelfUpdateAction(openUpdates: @escaping @MainActor () -> Void) {
        wireSelfUpdateAction(updateNotifier, openUpdates: openUpdates)
    }

    @_spi(Testing) public func wireSelfUpdateAction(_ notifier: SystemUpdateNotifier?, openUpdates: @escaping @MainActor () -> Void) {
        notifier?.onSelfUpdate = { [weak self] in
            openUpdates()
            self?.appUpdates.requestSelfUpdate()
        }
    }
}
