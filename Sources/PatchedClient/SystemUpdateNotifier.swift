import Foundation
import UserNotifications

/// Posts through `UNUserNotificationCenter`, asking permission the first time there is something to say.
/// Does nothing outside an installed .app bundle (the notification centre cannot be used there).
@MainActor public final class SystemUpdateNotifier: NSObject, UpdateNotifying, UpdateSummaryNotifying,
                                                    @preconcurrency UNUserNotificationCenterDelegate {
    nonisolated public static let requestIdentifier = "im.patched.updates-available"
    /// The one summary notification after an Update All started from the menu or the notification.
    nonisolated public static let summaryIdentifier = "im.patched.update-all-summary"
    /// The "Patched X is available" notification. Clicking it opens Updates. When the release can be installed
    /// it has one button, Update…, which opens Updates and asks for confirmation; it never installs by itself.
    nonisolated public static let selfUpdateIdentifier = "im.patched.self-update"
    nonisolated public static let categoryIdentifier = "im.patched.updates-available.category"
    nonisolated public static let updateAllActionIdentifier = "im.patched.update-all"
    nonisolated public static let selfUpdateCategoryIdentifier = "im.patched.self-update.category"
    nonisolated public static let selfUpdateActionIdentifier = "im.patched.self-update.update"

    /// What a notification response asks for. `selfUpdate` only brings up the self-update confirmation.
    public enum Route: Equatable, Sendable { case openUpdates, updateAll, selfUpdate }

    /// The "updates available" category: an Update All button. It does not bring Patched to the front, and it
    /// needs the Mac unlocked. Only this one notification carries it, never the summary.
    public static func makeCategory() -> UNNotificationCategory {
        let action = UNNotificationAction(identifier: updateAllActionIdentifier, title: String(localized: "Update All"),
                                          options: [.authenticationRequired])
        return UNNotificationCategory(identifier: categoryIdentifier, actions: [action],
                                      intentIdentifiers: [], options: [])
    }

    /// The installable "Patched X is available" category: one Update… button that brings Patched to the front
    /// with the confirmation showing. Confirming is a separate click in Patched.
    public static func makeSelfUpdateCategory() -> UNNotificationCategory {
        let action = UNNotificationAction(identifier: selfUpdateActionIdentifier, title: String(localized: "Update…"),
                                          options: [.foreground, .authenticationRequired])
        return UNNotificationCategory(identifier: selfUpdateCategoryIdentifier, actions: [action],
                                      intentIdentifiers: [], options: [])
    }

    /// Body tap of either notification opens the Updates screen; only the button on the "updates available"
    /// notification updates anything. Anything else is ignored.
    nonisolated public static func route(requestIdentifier: String, actionIdentifier: String) -> Route? {
        if requestIdentifier == Self.requestIdentifier || requestIdentifier == Self.summaryIdentifier
            || requestIdentifier == Self.selfUpdateIdentifier,
           actionIdentifier == UNNotificationDefaultActionIdentifier { return .openUpdates }
        if requestIdentifier == Self.requestIdentifier, actionIdentifier == Self.updateAllActionIdentifier { return .updateAll }
        if requestIdentifier == Self.selfUpdateIdentifier, actionIdentifier == Self.selfUpdateActionIdentifier { return .selfUpdate }
        return nil
    }

    /// Called when the user clicks the notification.
    /// A click that arrives before a handler is set (for example the click that launched the app) is kept
    /// and delivered as soon as one is.
    public var onOpenUpdates: (@MainActor () -> Void)? {
        didSet { if pendingOpen, let handler = onOpenUpdates { pendingOpen = false; handler() } }
    }
    /// Called when the user chooses Update All on the notification, with the update keys that notification
    /// advertised. Queued like the open request (with its keys), and run once.
    public var onUpdateAll: (@MainActor (Set<String>) -> Void)? {
        didSet {
            if let keys = pendingUpdateAll, let handler = onUpdateAll { pendingUpdateAll = nil; handler(keys) }
        }
    }
    /// Called when the user chooses Update… on the self-update notification: open Updates and show the
    /// confirmation. Queued like the open request, and run once.
    public var onSelfUpdate: (@MainActor () -> Void)? {
        didSet { if pendingSelfUpdate, let handler = onSelfUpdate { pendingSelfUpdate = false; handler() } }
    }
    /// userInfo key holding the advertised update keys.
    nonisolated public static let updateKeysUserInfoKey = "updateKeys"
    private var pendingOpen = false
    private var pendingSelfUpdate = false
    private var pendingUpdateAll: Set<String>?
    private var delegateSet = false

    /// One notifier per process, so the app delegate can register it during launch.
    public static let shared = SystemUpdateNotifier()

    public override init() { super.init() }

    /// The user asked to see the updates. Runs the handler now, or as soon as there is one.
    public func openRequested() {
        if let onOpenUpdates { onOpenUpdates() } else { pendingOpen = true }
    }

    /// The user chose Update All. Runs the handler now, or as soon as there is one.
    public func updateAllRequested(keys: Set<String>) {
        if let onUpdateAll { onUpdateAll(keys) } else { pendingUpdateAll = keys }
    }

    /// Applies a notification response. Separate from the delegate callback so it can be exercised directly.
    public func handle(requestIdentifier: String, actionIdentifier: String, userInfo: [AnyHashable: Any] = [:]) {
        switch Self.route(requestIdentifier: requestIdentifier, actionIdentifier: actionIdentifier) {
        case .openUpdates?: openRequested()
        case .updateAll?:
            // A response without the advertised keys advertises nothing, so it can install nothing.
            updateAllRequested(keys: Set((userInfo[Self.updateKeysUserInfoKey] as? [String]) ?? []))
        case .selfUpdate?:
            if let onSelfUpdate { onSelfUpdate() } else { pendingSelfUpdate = true }
        case nil: break
        }
    }

    /// Registers as the delegate so clicks are delivered (also when a click launched the app), and registers
    /// the notification category so the Update All button is available.
    public func activate() {
        guard runsFromAppBundle, !delegateSet else { return }
        delegateSet = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.makeCategory(), Self.makeSelfUpdateCategory()])
    }

    public func notify(updates: [AvailableUpdate], completion: @escaping @MainActor (Bool) -> Void) {
        guard runsFromAppBundle, !updates.isEmpty else { completion(false); return }
        activate()
        let content = UNMutableNotificationContent()
        content.title = updates.count == 1 ? String(localized: "1 app update available") : String(localized: "\(updates.count) app updates available")
        content.body = Self.body(updates)
        content.threadIdentifier = Self.requestIdentifier
        content.categoryIdentifier = Self.categoryIdentifier
        // What this notification advertises; its Update All button may install only these.
        content.userInfo = [Self.updateKeysUserInfoKey: updates.map(\.key).sorted()]
        post(content, identifier: Self.requestIdentifier, completion: completion)
    }

    public func notify(selfUpdate: SelfUpdate, completion: @escaping @MainActor (Bool) -> Void) {
        guard runsFromAppBundle else { completion(false); return }
        activate()
        let content = UNMutableNotificationContent()
        content.title = selfUpdate.text
        content.body = Self.selfUpdateBody(installable: selfUpdate.assets != nil)
        content.threadIdentifier = Self.selfUpdateIdentifier
        if selfUpdate.assets != nil { content.categoryIdentifier = Self.selfUpdateCategoryIdentifier }
        post(content, identifier: Self.selfUpdateIdentifier, completion: completion)
    }

    /// Asks permission the first time, then submits the notification. `completion(true)` only once it was added.
    private func post(_ content: UNNotificationContent, identifier: String, completion: @escaping @MainActor (Bool) -> Void) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert])
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                completion(false); return
            }
            // A fixed identifier replaces the previous notification instead of stacking them.
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                completion(true)
            } catch { completion(false) }
        }
    }

    nonisolated public static func selfUpdateBody(installable: Bool) -> String {
        installable ? String(localized: "Choose Update… to install it after you confirm. Nothing is installed automatically.")
                    : String(localized: "Open Patched to see where to download it. Nothing is installed automatically.")
    }

    /// Posts the summary only when notifications are already authorised; never asks.
    public func notify(summary: UpdateAllSummary) {
        guard runsFromAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Update All finished")
        content.body = summary.text
        content.threadIdentifier = Self.requestIdentifier
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            try? await center.add(UNNotificationRequest(identifier: Self.summaryIdentifier, content: content, trigger: nil))
        }
    }

    /// "Chrome 2.0, Obsidian 1.5, plus Windows App 11.2 in the App Store": installable updates first, then the
    /// App Store ones, which Patched only points to.
    @_spi(Testing) nonisolated public static func body(_ updates: [AvailableUpdate]) -> String {
        func list(_ items: [AvailableUpdate], limit: Int) -> String {
            let names = items.prefix(limit).map { "\($0.name) \($0.version)" }
            let more = items.count > limit ? String(localized: " and \(items.count - limit) more") : ""
            return names.joined(separator: ", ") + more
        }
        let own = updates.filter { !$0.appStore }, store = updates.filter(\.appStore)
        guard !store.isEmpty else { return list(own, limit: 5) }
        let storePart = String(localized: "\(list(store, limit: own.isEmpty ? 5 : 2)) in the App Store")
        return own.isEmpty ? storePart : String(localized: "\(list(own, limit: 3)), plus \(storePart)")
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        handle(requestIdentifier: response.notification.request.identifier, actionIdentifier: response.actionIdentifier,
               userInfo: response.notification.request.content.userInfo)
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
