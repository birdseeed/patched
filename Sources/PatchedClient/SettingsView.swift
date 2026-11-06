import SwiftUI
import AppKit
import UserNotifications

/// What macOS currently allows for Patched's notifications.
public enum NotificationPermission: Equatable, Sendable { case unknown, notDetermined, denied, allowed }

/// Reads the notification permission only when Settings is shown or refreshed. It never asks for permission.
@MainActor public final class NotificationStatusController: ObservableObject {
    public typealias Reader = @MainActor (@escaping @MainActor (NotificationPermission) -> Void) -> Void
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    @Published public private(set) var permission: NotificationPermission = .unknown
    private let reader: Reader
    public init(reader: @escaping Reader) { self.reader = reader }

    /// `UNUserNotificationCenter`, only from an installed .app bundle; otherwise always unknown.
    public static func system() -> NotificationStatusController {
        NotificationStatusController(reader: { deliver in
            guard runsFromAppBundle else { deliver(.unknown); return }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let permission: NotificationPermission
                switch settings.authorizationStatus {
                case .authorized, .provisional: permission = .allowed
                case .denied: permission = .denied
                case .notDetermined: permission = .notDetermined
                default: permission = .unknown
                }
                Task { @MainActor in deliver(permission) }
            }
        })
    }

    public func refresh() { reader { [weak self] in self?.permission = $0 } }

    public var statusText: String {
        switch permission {
        case .allowed: return "Notifications are on. Patched tells you when updates are available."
        case .denied: return "Notifications are off, so Patched cannot tell you about updates. You can turn them on in System Settings."
        case .notDetermined: return "Patched asks for permission the first time it has an update to tell you about."
        case .unknown: return "Notification status is unavailable."
        }
    }
}

/// The whole Settings screen: Open at login, how checking works, notifications and the version.
public struct SettingsView: View {
    public static let scheduleText = "Patched checks for updates when it opens and every 3 hours. It never installs anything on its own."
    @ObservedObject private var openAtLogin: OpenAtLoginController
    @ObservedObject private var notifications: NotificationStatusController
    private let openNotificationSettings: () -> Void
    private let version: String?

    public init(openAtLogin: OpenAtLoginController, notifications: NotificationStatusController,
                version: String?, openNotificationSettings: @escaping () -> Void) {
        self.openAtLogin = openAtLogin
        self.notifications = notifications
        self.version = version
        self.openNotificationSettings = openNotificationSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OpenAtLoginView(controller: openAtLogin)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Checking for updates").font(.title2).accessibilityAddTraits(.isHeader)
                Text(verbatim: Self.scheduleText).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Notifications").font(.title2).accessibilityAddTraits(.isHeader)
                Text(verbatim: notifications.statusText).fixedSize(horizontal: false, vertical: true)
                Button(action: openNotificationSettings) { Text(verbatim: "Open Notification Settings") }
            }
            if let version {
                Text(verbatim: "Version " + version).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { notifications.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifications.refresh()
        }
    }
}
