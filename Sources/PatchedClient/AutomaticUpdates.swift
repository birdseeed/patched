import Foundation
import Combine
import UpdateSources

// Automatic updates at a set time. Off by default. This is the one deliberate exception to "nothing installs
// until you choose Update". The setting, its managed (MDM) override and the once-a-day timing rule live here;
// what gets installed is decided by `AppUpdatesController.updateAll(automatic:)`, the same path as Update All.

/// A time of day, hour and minute, with a strict "HH:mm" text form for managed preferences.
public struct TimeOfDay: Equatable, Sendable {
    public let hour: Int
    public let minute: Int
    public static let `default` = TimeOfDay(hour: 2, minute: 0)!

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour; self.minute = minute
    }

    /// Exactly two digits, a colon and two digits: "02:00", "23:59". Nothing else is accepted.
    public init?(string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 5, bytes[2] == UInt8(ascii: ":") else { return nil }
        func digit(_ b: UInt8) -> Int? { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) ? Int(b - UInt8(ascii: "0")) : nil }
        guard let h1 = digit(bytes[0]), let h2 = digit(bytes[1]), let m1 = digit(bytes[3]), let m2 = digit(bytes[4]) else { return nil }
        self.init(hour: h1 * 10 + h2, minute: m1 * 10 + m2)
    }

    public var string: String { String(format: "%02d:%02d", hour, minute) }
}

/// When an automatic run is due. Pure, so a fake clock can drive it.
public enum AutomaticUpdateSchedule {
    /// How long after the chosen time a run may still start (a Mac that was asleep, or Patched not running).
    public static let window: TimeInterval = 6 * 60 * 60

    /// "2026-11-11" in the given calendar: one value per calendar day.
    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Due when now is at or after today's chosen time, no more than 6 hours after it and still today, and no run has been
    /// recorded for today. The window never reaches into the next day, so a run happens at most once a day.
    public static func isDue(now: Date, time: TimeOfDay, lastRunDay: String?, calendar: Calendar) -> Bool {
        guard lastRunDay != dayKey(now, calendar: calendar),
              let target = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now) else { return false }
        let late = now.timeIntervalSince(target)
        return late >= 0 && late <= window
    }
}

/// What Patched remembers about automatic updates for this user.
@MainActor public protocol AutomaticUpdateStoring: AnyObject {
    var enabled: Bool { get set }
    var time: TimeOfDay { get set }
    /// The calendar day (see `AutomaticUpdateSchedule.dayKey`) an automatic run last started. Survives a relaunch.
    var lastRunDay: String? { get set }
}

/// In memory only: fixtures, and any run under the test tripwire.
@MainActor public final class MemoryAutomaticUpdateStore: AutomaticUpdateStoring {
    public var enabled = false
    public var time = TimeOfDay.default
    public var lastRunDay: String?
    public init() {}
}

/// UserDefaults-backed. Under the test tripwire it keeps everything in memory instead.
@MainActor public final class DefaultsAutomaticUpdateStore: AutomaticUpdateStoring {
    private static let enabledKey = "im.patched.automaticUpdatesEnabled"
    private static let timeKey = "im.patched.automaticUpdatesTime"
    private static let lastRunKey = "im.patched.automaticUpdatesLastRunDay"
    private let memory = MemoryAutomaticUpdateStore()
    private var useMemory: Bool { RealStateTripwire.isActive }
    public init() {}
    public var enabled: Bool {
        get { useMemory ? memory.enabled : UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { if useMemory { memory.enabled = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) } }
    }
    public var time: TimeOfDay {
        get {
            if useMemory { return memory.time }
            return UserDefaults.standard.string(forKey: Self.timeKey).flatMap(TimeOfDay.init(string:)) ?? .default
        }
        set { if useMemory { memory.time = newValue } else { UserDefaults.standard.set(newValue.string, forKey: Self.timeKey) } }
    }
    public var lastRunDay: String? {
        get { useMemory ? memory.lastRunDay : UserDefaults.standard.string(forKey: Self.lastRunKey) }
        set { if useMemory { memory.lastRunDay = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.lastRunKey) } }
    }
}

/// The effective automatic-update setting: the user's own choice, overridden key by key by a managed value.
@MainActor public final class AutomaticUpdateSettings: ObservableObject {
    /// The managed-preference keys (for `im.patched.app`): a boolean and an "HH:mm" string.
    public static let enabledKey = "AutomaticUpdatesEnabled"
    public static let timeKey = "AutomaticUpdatesTime"
    public static let lockedNote = String(localized: "Set by your organisation")
    public static let invalidNote = String(localized: "Your organisation set a value Patched could not use. An invalid on or off value keeps automatic updates off. An invalid time is ignored.")

    @Published public private(set) var isEnabled = false
    @Published public private(set) var time = TimeOfDay.default
    @Published public private(set) var enabledLocked = false
    @Published public private(set) var timeLocked = false
    @Published public private(set) var managedValueIgnored = false

    private let store: any AutomaticUpdateStoring
    private let managed: ManagedPreferences

    public init(store: any AutomaticUpdateStoring, managed: ManagedPreferences) {
        self.store = store; self.managed = managed
        refresh()
    }

    public static func system() -> AutomaticUpdateSettings {
        AutomaticUpdateSettings(store: DefaultsAutomaticUpdateStore(), managed: ManagedPreferences())
    }

    /// Reads the stored choice and the managed preferences again.
    public func refresh() {
        var ignored = false
        switch managed.bool(Self.enabledKey) {
        case .value(let flag): isEnabled = flag; enabledLocked = true
        // Fails closed: an organisation that forced a value we cannot read meant to control this, so it is off and locked.
        case .invalid: isEnabled = false; enabledLocked = true; ignored = true
        case .notManaged: isEnabled = store.enabled; enabledLocked = false
        }
        switch managed.string(Self.timeKey, parse: TimeOfDay.init(string:)) {
        case .value(let value): time = value; timeLocked = true
        case .invalid: time = store.time; timeLocked = false; ignored = true
        case .notManaged: time = store.time; timeLocked = false
        }
        managedValueIgnored = ignored
    }

    /// A user change. Ignored while an organisation manages the key.
    public func setEnabled(_ on: Bool) {
        refresh()
        guard !enabledLocked else { return }
        store.enabled = on; refresh()
    }

    public func setTime(_ value: TimeOfDay) {
        refresh()
        guard !timeLocked else { return }
        store.time = value; refresh()
    }

    public var lastRunDay: String? {
        get { store.lastRunDay }
        set { store.lastRunDay = newValue }
    }
}

/// Nothing is managed. Used by fixtures so they never read this Mac's preferences.
public struct NoManagedPreferences: ManagedPreferenceReading {
    public init() {}
    public func isForced(_ key: String) -> Bool { false }
    public func forcedValue(forKey key: String) -> Any? { nil }
}
