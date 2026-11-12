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
    public static let scheduleText = String(localized: "Patched checks for updates when it opens and every 3 hours. It only installs updates on its own if you turn on automatic updates below.")
    public static let automaticDetailText = String(localized: "Once a day at this time, or at the first check after it (within 6 hours, and not past midnight), Patched installs updates for apps you can replace without admin rights, after the same checks as Update All. It skips open apps, Patched itself, installer packages, App Store apps, hidden apps and apps that need admin rights. You can roll back any update.")
    @ObservedObject private var automaticUpdates: AutomaticUpdateSettings
    @ObservedObject private var openAtLogin: OpenAtLoginController
    @ObservedObject private var notifications: NotificationStatusController
    private let openNotificationSettings: () -> Void
    private let version: String?

    public init(openAtLogin: OpenAtLoginController, notifications: NotificationStatusController,
                automaticUpdates: AutomaticUpdateSettings,
                version: String?, openNotificationSettings: @escaping () -> Void) {
        self.automaticUpdates = automaticUpdates
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
            Section(header: Text("Automatic updates")) {
                Toggle(isOn: Binding(get: { automaticUpdates.isEnabled }, set: { automaticUpdates.setEnabled($0) })) {
                    Text("Install updates automatically")
                }
                .disabled(automaticUpdates.enabledLocked)
                DatePicker(selection: timeBinding, displayedComponents: .hourAndMinute) { Text("Time") }
                    .disabled(automaticUpdates.timeLocked || !automaticUpdates.isEnabled)
                if automaticUpdates.enabledLocked || automaticUpdates.timeLocked {
                    Text(verbatim: AutomaticUpdateSettings.lockedNote).foregroundStyle(.secondary)
                }
                if automaticUpdates.managedValueIgnored {
                    Text(verbatim: AutomaticUpdateSettings.invalidNote).foregroundStyle(.secondary)
                }
                Text(verbatim: Self.automaticDetailText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        .onAppear { openAtLogin.refresh(); notifications.refresh(); automaticUpdates.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            openAtLogin.refresh(); notifications.refresh(); automaticUpdates.refresh()
        }
    }

    /// The picker works in dates; the setting is an hour and minute.
    private var timeBinding: Binding<Date> {
        Binding(get: {
            let time = automaticUpdates.time
            return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            if let time = TimeOfDay(hour: parts.hour ?? 2, minute: parts.minute ?? 0) { automaticUpdates.setTime(time) }
        })
    }
}

/// The Settings scene's content over the shared session. Showing it reads the login-item and notification
/// status only; it starts no check.
public struct NativeClientSettingsView: View {
    @ObservedObject private var session: NativeClientSession
    public init(session: NativeClientSession) { self.session = session }

    public var body: some View {
        SettingsView(openAtLogin: session.openAtLogin, notifications: session.notificationStatus,
                     automaticUpdates: session.automaticUpdates,
                     version: NativeClientSession.appVersion, openNotificationSettings: { session.openNotificationSettings() })
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}
