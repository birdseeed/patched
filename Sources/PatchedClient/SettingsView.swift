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
        case .allowed: return String(localized: "Notifications are on. Patched tells you when updates are available.")
        case .denied: return String(localized: "Notifications are off, so Patched cannot tell you about updates. You can turn them on in System Settings.")
        case .notDetermined: return String(localized: "Patched asks for permission the first time it has an update to tell you about.")
        case .unknown: return String(localized: "Notification status is unavailable.")
        }
    }
}

/// The Settings window: Open at login, how checking works, notifications and the version, as a grouped form.
public struct SettingsView: View {
    public static let scheduleText = String(localized: "Patched checks for updates when it opens and every 3 hours. It never installs anything on its own.")
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
        Form {
            Section(header: Text("Open at login")) {
                OpenAtLoginView(controller: openAtLogin)
            }
            Section(header: Text("Checking for updates")) {
                Text(verbatim: Self.scheduleText).fixedSize(horizontal: false, vertical: true)
            }
            Section(header: Text("Notifications")) {
                Text(verbatim: notifications.statusText).fixedSize(horizontal: false, vertical: true)
                Button(action: openNotificationSettings) { Text("Open Notification Settings") }
            }
            if let version {
                Section {
                    LabeledContent { Text(verbatim: version).textSelection(.enabled) } label: { Text("Version") }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { openAtLogin.refresh(); notifications.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            openAtLogin.refresh(); notifications.refresh()
        }
    }
}

/// The Settings scene's content over the shared session. Showing it reads the login-item and notification
/// status only; it starts no check.
public struct NativeClientSettingsView: View {
    @ObservedObject private var session: NativeClientSession
    public init(session: NativeClientSession) { self.session = session }

    public var body: some View {
        SettingsView(openAtLogin: session.openAtLogin, notifications: session.notificationStatus,
                     version: NativeClientSession.appVersion, openNotificationSettings: { session.openNotificationSettings() })
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}
