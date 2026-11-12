import Foundation

/// Reads preferences an organisation has forced on this Mac (a configuration profile or `defaults` managed
/// domain for Patched's own bundle ID). Only a forced value counts as managed: a value the user set for
/// themselves is never reported here. Behind a seam so checks can fake it and never read real state.
public protocol ManagedPreferenceReading {
    /// Whether an organisation forces this key.
    func isForced(_ key: String) -> Bool
    /// The forced value, or nil when the key is not forced.
    func forcedValue(forKey key: String) -> Any?
}

/// The real managed preferences for `im.patched.app`, through `CFPreferences`. Under the test tripwire it
/// reports nothing is managed, so a check never depends on the Mac it runs on.
public struct SystemManagedPreferences: ManagedPreferenceReading {
    public static let applicationID = "im.patched.app"
    private let applicationID: String
    public init(applicationID: String = SystemManagedPreferences.applicationID) { self.applicationID = applicationID }

    public func isForced(_ key: String) -> Bool {
        if RealStateTripwire.isActive { return false }
        return CFPreferencesAppValueIsForced(key as CFString, applicationID as CFString)
    }

    public func forcedValue(forKey key: String) -> Any? {
        guard isForced(key) else { return nil }
        return CFPreferencesCopyAppValue(key as CFString, applicationID as CFString)
    }
}

/// What the managed preferences say about one key.
public enum ManagedSetting<Value: Equatable & Sendable>: Equatable, Sendable {
    /// Not managed: the user's own setting applies.
    case notManaged
    /// Managed, but with a value of the wrong type or form. It is ignored, so the user's own setting applies.
    case invalid
    /// Managed with a valid value, which the user cannot change.
    case value(Value)
}

/// Typed, strict reads of managed preferences. A small reusable type: the automatic-updates setting uses it
/// now, and an organisation-supplied app catalogue can use it later.
public struct ManagedPreferences {
    private let reader: any ManagedPreferenceReading
    public init(reader: any ManagedPreferenceReading = SystemManagedPreferences()) { self.reader = reader }

    /// A managed true or false. Only a real boolean is valid; numbers and strings are not.
    public func bool(_ key: String) -> ManagedSetting<Bool> {
        guard reader.isForced(key) else { return .notManaged }
        guard let raw = reader.forcedValue(forKey: key), CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID(),
              let flag = raw as? Bool else { return .invalid }
        return .value(flag)
    }

    /// A managed string that `parse` accepts. Anything else is invalid.
    public func string<Value: Equatable & Sendable>(_ key: String, parse: (String) -> Value?) -> ManagedSetting<Value> {
        guard reader.isForced(key) else { return .notManaged }
        guard let text = reader.forcedValue(forKey: key) as? String, let value = parse(text) else { return .invalid }
        return .value(value)
    }

    /// A managed array that `parse` accepts. Anything that is not an array (a dictionary, a string, a number) is
    /// invalid, and so is an array `parse` rejects. The Self Service catalogue uses it.
    public func array<Value: Equatable & Sendable>(_ key: String, parse: ([Any]) -> Value?) -> ManagedSetting<Value> {
        guard reader.isForced(key) else { return .notManaged }
        guard let raw = reader.forcedValue(forKey: key), CFGetTypeID(raw as CFTypeRef) == CFArrayGetTypeID(),
              let items = raw as? [Any], let value = parse(items) else { return .invalid }
        return .value(value)
    }
}
