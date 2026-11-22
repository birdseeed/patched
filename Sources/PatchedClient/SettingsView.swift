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
    public static let automaticDetailText = String(localized: "Once a day at this time, or at the first check after it (within 6 hours, and not past midnight), Patched installs updates for apps you can replace without admin rights, after the same checks as Update All. It skips open apps, installer packages, App Store apps, hidden apps and apps that need admin rights. It updates Patched itself only when \"Also update Patched itself\" is on. You can roll back any app update.")
    @ObservedObject private var automaticUpdates: AutomaticUpdateSettings
    @ObservedObject private var openAtLogin: OpenAtLoginController
    @ObservedObject private var notifications: NotificationStatusController
    @ObservedObject private var macOSReminders: MacOSReminderSettings
    private let openNotificationSettings: () -> Void
    private let version: String?
    /// "Uninstall Patched…": asks in an alert, then removes Patched's files and the app. Nil hides the section.
    private let startUninstall: (() -> Void)?

    public init(openAtLogin: OpenAtLoginController, notifications: NotificationStatusController,
                automaticUpdates: AutomaticUpdateSettings,
                macOSReminders: MacOSReminderSettings = MacOSReminderSettings(store: MemoryMacOSReminderStore()),
                version: String?, openNotificationSettings: @escaping () -> Void,
                startUninstall: (() -> Void)? = nil) {
        self.automaticUpdates = automaticUpdates
        self.macOSReminders = macOSReminders
        self.openAtLogin = openAtLogin
        self.notifications = notifications
        self.version = version
        self.openNotificationSettings = openNotificationSettings
        self.startUninstall = startUninstall
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
                // Shows what is in effect: off whenever automatic updates are off.
                Toggle(isOn: Binding(get: { automaticUpdates.selfUpdatesEnabled }, set: { automaticUpdates.setSelfUpdatesEnabled($0) })) {
                    Text("Also update Patched itself")
                }
                .disabled(!automaticUpdates.canChangeSelfUpdates)
                DatePicker(selection: timeBinding, displayedComponents: .hourAndMinute) { Text("Time") }
                    .disabled(automaticUpdates.timeLocked || !automaticUpdates.isEnabled)
                if automaticUpdates.enabledLocked || automaticUpdates.timeLocked || automaticUpdates.selfUpdatesLocked {
                    Text(verbatim: AutomaticUpdateSettings.lockedNote).foregroundStyle(.secondary)
                }
                if automaticUpdates.managedValueIgnored {
                    Text(verbatim: AutomaticUpdateSettings.invalidNote).foregroundStyle(.secondary)
                }
                Text(verbatim: Self.automaticDetailText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: AutomaticUpdateSettings.selfUpdatesDetailText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(header: Text("macOS updates")) {
                Picker(selection: Binding(get: { macOSReminders.reminderDays ?? 0 },
                                          set: { macOSReminders.setReminderDays($0 == 0 ? nil : $0) })) {
                    Text(verbatim: MacOSReminderSettings.choiceTitle(nil)).tag(0)
                    ForEach(MacOSReminderSettings.choices, id: \.self) { days in
                        Text(verbatim: MacOSReminderSettings.choiceTitle(days)).tag(days)
                    }
                } label: { Text("Remind me about macOS updates") }
                Text(verbatim: MacOSReminderSettings.detailText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(header: Text("Notifications")) {
                Text(verbatim: notifications.statusText).fixedSize(horizontal: false, vertical: true)
                Button(action: openNotificationSettings) { Text("Open Notification Settings") }
            }
            if version != nil || startUninstall != nil {
                Section {
                    if let version {
                        LabeledContent { Text(verbatim: version).textSelection(.enabled) } label: { Text("Version") }
                    }
                    if let startUninstall {
                        // Lives here rather than the menu bar menu, away from everyday commands.
                        Button(action: startUninstall) { Text("Uninstall Patched…") }
                            .disabled(!runsFromAppBundle)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { openAtLogin.refresh(); notifications.refresh(); automaticUpdates.refresh(); macOSReminders.refresh() }
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
                     automaticUpdates: session.automaticUpdates, macOSReminders: session.macOSReminders,
                     version: NativeClientSession.appVersion, openNotificationSettings: { session.openNotificationSettings() },
                     startUninstall: { Task { await UninstallFlow.system().run() } })
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}
