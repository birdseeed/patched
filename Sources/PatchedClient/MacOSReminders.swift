import Foundation
import Combine
import UpdateSources

// macOS nudges, version one. One notification per macOS update (never for a new major), and, only when the user
// turns it on, a reminder every 1, 3 or 7 days while the same update is still outstanding. Never more than once a
// day, and never while an install, roll back or recovery is running. The notification only opens Updates; the
// row's Open Software Update is still a separate click. The scheduler decides when (`settleMacOSUpdate`).

/// What Patched remembers about macOS notifications for this user.
@MainActor public protocol MacOSReminderStoring: AnyObject {
    /// Remind every this many days; nil (the default) means no reminders, only the first notification.
    var reminderDays: Int? { get set }
    /// The notice (`MacOSUpdateNotice.key`) last announced, and when.
    var notifiedKey: String? { get set }
    var notifiedAt: Date? { get set }
}

@MainActor public final class MemoryMacOSReminderStore: MacOSReminderStoring {
    public var reminderDays: Int?
    public var notifiedKey: String?
    public var notifiedAt: Date?
    public init(reminderDays: Int? = nil) { self.reminderDays = reminderDays }
}

/// UserDefaults-backed, beside Patched's other per-user state. Under the test tripwire it keeps everything in memory.
@MainActor public final class DefaultsMacOSReminderStore: MacOSReminderStoring {
    private static let daysKey = "im.patched.macOSReminderDays"
    private static let notifiedKeyKey = "im.patched.macOSNotifiedUpdate"
    private static let notifiedAtKey = "im.patched.macOSNotifiedAt"
    private let memory = MemoryMacOSReminderStore()
    private var useMemory: Bool { RealStateTripwire.isActive }
    public init() {}
    public var reminderDays: Int? {
        get {
            if useMemory { return memory.reminderDays }
            let value = UserDefaults.standard.integer(forKey: Self.daysKey)
            return value > 0 ? value : nil
        }
        set { if useMemory { memory.reminderDays = newValue } else { UserDefaults.standard.set(newValue ?? 0, forKey: Self.daysKey) } }
    }
    public var notifiedKey: String? {
        get { useMemory ? memory.notifiedKey : UserDefaults.standard.string(forKey: Self.notifiedKeyKey) }
        set { if useMemory { memory.notifiedKey = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.notifiedKeyKey) } }
    }
    public var notifiedAt: Date? {
        get {
            if useMemory { return memory.notifiedAt }
            let value = UserDefaults.standard.double(forKey: Self.notifiedAtKey)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set { if useMemory { memory.notifiedAt = newValue } else { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.notifiedAtKey) } }
    }
}

/// The "Remind me about macOS updates" setting, for Settings and the scheduler.
@MainActor public final class MacOSReminderSettings: ObservableObject {
    /// The choices Settings offers. Anything else stored counts as off.
    public static let choices = [1, 3, 7]
    @Published public private(set) var reminderDays: Int?
    let store: any MacOSReminderStoring

    public init(store: any MacOSReminderStoring) {
        self.store = store
        refresh()
    }

    public static func system() -> MacOSReminderSettings { MacOSReminderSettings(store: DefaultsMacOSReminderStore()) }

    public func refresh() { reminderDays = store.reminderDays.flatMap { Self.choices.contains($0) ? $0 : nil } }

    /// nil turns reminders off. A value that is not one of `choices` also turns them off.
    public func setReminderDays(_ days: Int?) {
        store.reminderDays = days.flatMap { Self.choices.contains($0) ? $0 : nil }
        refresh()
    }

    public static func choiceTitle(_ days: Int?) -> String {
        switch days {
        case nil: return String(localized: "Off")
        case 1?: return String(localized: "Every day")
        case let days?: return String(localized: "Every \(days) days")
        }
    }

    public static let detailText = String(localized: "Patched tells you once when a macOS update is available. With a reminder, it tells you again every few days until it is installed, at most once a day and never while it is updating an app. New major versions of macOS are never reminded about. Patched never installs macOS: the notification opens Updates, and Open Software Update takes you to System Settings.")
}

/// The notification wording.
extension MacOSUpdateNotice {
    public func notificationTitle(reminder: Bool) -> String {
        reminder ? String(localized: "Reminder: macOS \(update.version) is available") : String(localized: "macOS \(update.version) is available")
    }
    public static let notificationBody = String(localized: "Open Patched, then Open Software Update to install it in System Settings. Patched never installs macOS itself.")
}
