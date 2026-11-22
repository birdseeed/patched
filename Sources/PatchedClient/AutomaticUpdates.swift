import Foundation
import Combine
import UpdateSources

// Automatic updates at a set time. Off by default. This is the one deliberate exception to "nothing installs
// until you choose Update". The setting, its managed (MDM) override and the once-a-day timing rule live here;
// what gets installed is decided by `AppUpdatesController.updateAll(automatic:)`, the same path as Update All.
// "Also update Patched itself" is a second opt-in under it, also off by default and only in effect while
// automatic updates are: the scheduled run then installs a Patched release this Mac has known about for at least
// 24 hours (`SelfUpdateSoak`), through the same signed self-update path as a confirmed click.

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

/// When this Mac first learnt of one Patched release: its version and the content GitHub announced for it
/// (`PatchedReleaseAssets.fingerprint`). Local only: no date from GitHub is ever used.
public struct SelfReleaseSighting: Equatable, Sendable {
    public let version: String
    /// nil: a release without a usable fingerprint, or a record stored before fingerprints. It never soaks.
    public let fingerprint: String?
    public let firstSeen: Date
    public init(version: String, fingerprint: String?, firstSeen: Date) {
        self.version = version; self.fingerprint = fingerprint; self.firstSeen = firstSeen
    }
}

/// A Patched release (version and content) the automatic self-update has already tried once. It is never tried
/// automatically again, whatever happened (a failure, or an install whose reopening failed); a click still can.
public struct SelfReleaseAttempt: Equatable, Sendable {
    public let version: String
    public let fingerprint: String
    public init(version: String, fingerprint: String) { self.version = version; self.fingerprint = fingerprint }
}

/// The waiting rule for installing Patched's own release without a click. Pure, so a fake clock can drive it.
public enum SelfUpdateSoak {
    /// How long this Mac must have known about a release before it is installed automatically. A bad release can
    /// be pulled in that time. A manual Update is offered at once, as before.
    public static let period: TimeInterval = 24 * 60 * 60

    /// The record after the release check reports `version` with `fingerprint` at `now`. The same version with the
    /// same fingerprint keeps its first sighting; any other version or content (a file replaced under the same name)
    /// starts the clock again, and so does a record without a fingerprint. A sighting in the future (a clock set back)
    /// is kept as it is, so it fails closed: it stays not soaked until real time passes its first sighting plus `period`.
    public static func observe(_ version: String, fingerprint: String?, now: Date, record: SelfReleaseSighting?) -> SelfReleaseSighting {
        guard let record, record.version == version, let known = record.fingerprint, known == fingerprint else {
            return SelfReleaseSighting(version: version, fingerprint: fingerprint, firstSeen: now)
        }
        return record
    }

    /// True once this exact version, with this exact fingerprint, was first seen at least `period` ago. A sighting in
    /// the future, or without a fingerprint, never counts.
    public static func isSoaked(_ version: String, fingerprint: String?, now: Date, record: SelfReleaseSighting?) -> Bool {
        guard let fingerprint, let record, record.version == version, record.fingerprint == fingerprint,
              record.firstSeen <= now else { return false }
        return now.timeIntervalSince(record.firstSeen) >= period
    }
}

/// What Patched remembers about automatic updates for this user.
@MainActor public protocol AutomaticUpdateStoring: AnyObject {
    var enabled: Bool { get set }
    var time: TimeOfDay { get set }
    /// The calendar day (see `AutomaticUpdateSchedule.dayKey`) an automatic run last started. Survives a relaunch.
    var lastRunDay: String? { get set }
    /// "Also update Patched itself". Off unless the user turns it on.
    var selfUpdatesEnabled: Bool { get set }
    /// The Patched release the release check last reported, and when this Mac first saw it. Cleared when a check
    /// finds no newer release, so a pulled release that comes back later waits the full 24 hours again.
    var selfReleaseSighting: SelfReleaseSighting? { get set }
    /// The release the automatic self-update last started installing. It is never tried automatically again; a new
    /// version or new content is a new release.
    var selfUpdateAttempt: SelfReleaseAttempt? { get set }
    /// Set by a confirmed (manual) self-update just before Patched reopens: the new copy may offer the setting once.
    var selfUpdateNotePending: Bool { get set }
    /// The one-time offer has been shown or answered, so it never appears again.
    var selfUpdateNoteDone: Bool { get set }
}

/// In memory only: fixtures, and any run under the test tripwire.
@MainActor public final class MemoryAutomaticUpdateStore: AutomaticUpdateStoring {
    public var enabled = false
    public var time = TimeOfDay.default
    public var lastRunDay: String?
    public var selfUpdatesEnabled = false
    public var selfReleaseSighting: SelfReleaseSighting?
    public var selfUpdateAttempt: SelfReleaseAttempt?
    public var selfUpdateNotePending = false
    public var selfUpdateNoteDone = false
    public init() {}
}

/// UserDefaults-backed. Under the test tripwire it keeps everything in memory instead.
@MainActor public final class DefaultsAutomaticUpdateStore: AutomaticUpdateStoring {
    private static let enabledKey = "im.patched.automaticUpdatesEnabled"
    private static let timeKey = "im.patched.automaticUpdatesTime"
    private static let lastRunKey = "im.patched.automaticUpdatesLastRunDay"
    private static let selfEnabledKey = "im.patched.automaticSelfUpdatesEnabled"
    private static let sightingVersionKey = "im.patched.selfReleaseFirstSeenVersion"
    private static let sightingDateKey = "im.patched.selfReleaseFirstSeenAt"
    private static let sightingFingerprintKey = "im.patched.selfReleaseFirstSeenFingerprint"
    private static let attemptVersionKey = "im.patched.automaticSelfUpdateAttemptVersion"
    private static let attemptFingerprintKey = "im.patched.automaticSelfUpdateAttemptFingerprint"
    private static let notePendingKey = "im.patched.selfUpdateNotePending"
    private static let noteDoneKey = "im.patched.selfUpdateNoteDone"
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
    public var selfUpdatesEnabled: Bool {
        get { useMemory ? memory.selfUpdatesEnabled : UserDefaults.standard.bool(forKey: Self.selfEnabledKey) }
        set { if useMemory { memory.selfUpdatesEnabled = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.selfEnabledKey) } }
    }
    public var selfReleaseSighting: SelfReleaseSighting? {
        get {
            if useMemory { return memory.selfReleaseSighting }
            let defaults = UserDefaults.standard
            guard let version = defaults.string(forKey: Self.sightingVersionKey), !version.isEmpty,
                  let seconds = defaults.object(forKey: Self.sightingDateKey) as? Double, seconds.isFinite else { return nil }
            // No fingerprint stored (an older record): it reads as nil, which never soaks and is replaced at the next check.
            let fingerprint = defaults.string(forKey: Self.sightingFingerprintKey).flatMap { $0.isEmpty ? nil : $0 }
            return SelfReleaseSighting(version: version, fingerprint: fingerprint, firstSeen: Date(timeIntervalSince1970: seconds))
        }
        set {
            if useMemory { memory.selfReleaseSighting = newValue; return }
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(newValue.version, forKey: Self.sightingVersionKey)
                defaults.set(newValue.firstSeen.timeIntervalSince1970, forKey: Self.sightingDateKey)
                if let fingerprint = newValue.fingerprint { defaults.set(fingerprint, forKey: Self.sightingFingerprintKey) }
                else { defaults.removeObject(forKey: Self.sightingFingerprintKey) }
            } else {
                defaults.removeObject(forKey: Self.sightingVersionKey); defaults.removeObject(forKey: Self.sightingDateKey)
                defaults.removeObject(forKey: Self.sightingFingerprintKey)
            }
        }
    }
    public var selfUpdateAttempt: SelfReleaseAttempt? {
        get {
            if useMemory { return memory.selfUpdateAttempt }
            let defaults = UserDefaults.standard
            guard let version = defaults.string(forKey: Self.attemptVersionKey), !version.isEmpty,
                  let fingerprint = defaults.string(forKey: Self.attemptFingerprintKey), !fingerprint.isEmpty else { return nil }
            return SelfReleaseAttempt(version: version, fingerprint: fingerprint)
        }
        set {
            if useMemory { memory.selfUpdateAttempt = newValue; return }
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(newValue.version, forKey: Self.attemptVersionKey)
                defaults.set(newValue.fingerprint, forKey: Self.attemptFingerprintKey)
            } else {
                defaults.removeObject(forKey: Self.attemptVersionKey); defaults.removeObject(forKey: Self.attemptFingerprintKey)
            }
        }
    }
    public var selfUpdateNotePending: Bool {
        get { useMemory ? memory.selfUpdateNotePending : UserDefaults.standard.bool(forKey: Self.notePendingKey) }
        set { if useMemory { memory.selfUpdateNotePending = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.notePendingKey) } }
    }
    public var selfUpdateNoteDone: Bool {
        get { useMemory ? memory.selfUpdateNoteDone : UserDefaults.standard.bool(forKey: Self.noteDoneKey) }
        set { if useMemory { memory.selfUpdateNoteDone = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.noteDoneKey) } }
    }
}

/// The effective automatic-update setting: the user's own choice, overridden key by key by a managed value.
@MainActor public final class AutomaticUpdateSettings: ObservableObject {
    /// The managed-preference keys (for `im.patched.app`): booleans and an "HH:mm" string.
    public static let enabledKey = "AutomaticUpdatesEnabled"
    public static let timeKey = "AutomaticUpdatesTime"
    public static let selfUpdatesKey = "AutomaticSelfUpdatesEnabled"
    public static let lockedNote = String(localized: "Set by your organisation")
    public static let invalidNote = String(localized: "Your organisation set a value Patched could not use. An invalid on or off value keeps that setting off. An invalid time is ignored.")
    /// Under "Also update Patched itself", in Settings and first-run setup.
    public static let selfUpdatesDetailText = String(localized: "Patched installs a new version of itself after that day's app updates, once this Mac has known about it for at least 24 hours, with the same checks as Update Patched. It then quits and reopens.")

    @Published public private(set) var isEnabled = false
    @Published public private(set) var time = TimeOfDay.default
    @Published public private(set) var enabledLocked = false
    @Published public private(set) var timeLocked = false
    @Published public private(set) var managedValueIgnored = false
    /// The user's (or organisation's) choice for "Also update Patched itself", whether or not automatic updates are on.
    @Published public private(set) var selfUpdatesChoice = false
    @Published public private(set) var selfUpdatesLocked = false
    /// The one-time offer on the Updates screen after a confirmed self-update (see `selfUpdateNoteEligible`).
    @Published public private(set) var showsSelfUpdateNote = false
    /// The offer stays on screen for the rest of this session once it has been shown, until it is answered.
    private var noteShownThisSession = false

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
        switch managed.bool(Self.selfUpdatesKey) {
        case .value(let flag): selfUpdatesChoice = flag; selfUpdatesLocked = true
        // Fails closed, as for automatic updates: off and locked.
        case .invalid: selfUpdatesChoice = false; selfUpdatesLocked = true; ignored = true
        case .notManaged: selfUpdatesChoice = store.selfUpdatesEnabled; selfUpdatesLocked = false
        }
        managedValueIgnored = ignored
        let offer = noteShownThisSession || (store.selfUpdateNotePending && !store.selfUpdateNoteDone)
        showsSelfUpdateNote = offer && selfUpdateNoteEligible
    }

    /// "Also update Patched itself" in effect: chosen, and automatic updates are on. Automatic updates turned off,
    /// by the user or by an organisation (including an invalid managed value), always turn this off too.
    public var selfUpdatesEnabled: Bool { isEnabled && selfUpdatesChoice }
    /// The box can be changed only while automatic updates are on and no organisation manages it.
    public var canChangeSelfUpdates: Bool { isEnabled && !selfUpdatesLocked }

    /// A user change to "Also update Patched itself". Ignored while managed, and it can only be turned on while
    /// automatic updates are on.
    public func setSelfUpdatesEnabled(_ on: Bool) {
        refresh()
        guard !selfUpdatesLocked, !on || isEnabled else { return }
        store.selfUpdatesEnabled = on; refresh()
    }

    /// The release check reported `version` with `fingerprint`: remember when this Mac first saw it. Always
    /// recorded, whatever the setting.
    public func noteSelfRelease(_ version: String, fingerprint: String?, now: Date) {
        let next = SelfUpdateSoak.observe(version, fingerprint: fingerprint, now: now, record: store.selfReleaseSighting)
        if next != store.selfReleaseSighting { store.selfReleaseSighting = next }
    }
    /// The release check found no newer release (it was pulled, or this Mac already runs it): forget the sighting, so
    /// a release that is published again later waits the full 24 hours from then.
    public func clearSelfReleaseSighting() {
        if store.selfReleaseSighting != nil { store.selfReleaseSighting = nil }
    }
    public var selfReleaseSighting: SelfReleaseSighting? { store.selfReleaseSighting }
    /// Whether `version` with `fingerprint` has been known here long enough to install without a click.
    public func selfReleaseSoaked(_ version: String, fingerprint: String?, now: Date) -> Bool {
        SelfUpdateSoak.isSoaked(version, fingerprint: fingerprint, now: now, record: store.selfReleaseSighting)
    }
    /// Whether the automatic self-update has already tried this exact release. A new version or fingerprint has not.
    public func selfUpdateAlreadyAttempted(_ version: String, fingerprint: String) -> Bool {
        store.selfUpdateAttempt == SelfReleaseAttempt(version: version, fingerprint: fingerprint)
    }
    /// The automatic self-update has started installing this release: it is never tried automatically again, so a
    /// failure, or an install whose reopening failed, does not repeat every day. A click can still install it.
    public func noteSelfUpdateAttempt(_ version: String, fingerprint: String) {
        store.selfUpdateAttempt = SelfReleaseAttempt(version: version, fingerprint: fingerprint)
    }

    // MARK: The one-time offer after a confirmed self-update

    /// Offered only while it would change something the user may change: "Also update Patched itself" is off and
    /// not managed, and automatic updates are not turned off by an organisation.
    public var selfUpdateNoteEligible: Bool {
        !selfUpdatesEnabled && !selfUpdatesLocked && !(enabledLocked && !isEnabled)
    }

    /// Called just before a confirmed self-update reopens Patched. Never again once the offer was shown or answered.
    public func markSelfUpdateNotePending() {
        guard !store.selfUpdateNoteDone else { return }
        store.selfUpdateNotePending = true
    }

    /// The offer is on screen: it is never shown again in a later session, whether or not it is answered.
    public func selfUpdateNoteShown() {
        guard showsSelfUpdateNote else { return }
        noteShownThisSession = true
        store.selfUpdateNoteDone = true; store.selfUpdateNotePending = false
    }

    /// The offer's words. When automatic updates are off, it says that Turn on switches them on too.
    public var selfUpdateNoteText: String {
        isEnabled ? String(localized: "Patched can update itself next time, along with your automatic updates.")
                  : String(localized: "Patched can update itself next time. This also turns on automatic updates, which install app updates once a day at \(time.string).")
    }
    public var selfUpdateNoteAcceptTitle: String {
        isEnabled ? String(localized: "Turn on") : String(localized: "Turn on automatic updates")
    }

    /// Turn on: automatic updates (if they are off and may be changed) and "Also update Patched itself", through the
    /// same setters as Settings, so a managed value still wins. Either answer ends the offer for good.
    public func acceptSelfUpdateNote() {
        refresh()
        guard showsSelfUpdateNote else { return }
        if !isEnabled { setEnabled(true) }
        setSelfUpdatesEnabled(true)
        endSelfUpdateNote()
    }

    /// Not now: nothing changes, and the offer never comes back.
    public func declineSelfUpdateNote() {
        refresh()
        guard showsSelfUpdateNote else { return }
        endSelfUpdateNote()
    }

    private func endSelfUpdateNote() {
        noteShownThisSession = false
        store.selfUpdateNoteDone = true; store.selfUpdateNotePending = false
        refresh()
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
