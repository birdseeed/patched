import Foundation
import SwiftUI
import UpdateSources

// The pinned macOS row. Patched shows the macOS update and opens System Settings › Software Update on a click;
// it never downloads, installs or asks for admin rights for macOS. The row is not an `AppUpdateRow` and has no
// `AppCheckOutcome`, so Update All, automatic updates and the command line's `update`, which act only on those,
// cannot reach it. Its only actions are Open Software Update and Not now.

/// Looks up the macOS update once per check. nil on the controller: no lookup (fixtures and tests).
public typealias MacOSUpdateCheck = @Sendable () async -> MacOSUpdateResult

public enum SoftwareUpdateLinks {
    /// System Settings › General › Software Update.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
    /// System Settings itself, when the pane's URL does not open.
    public static let systemSettingsBundleID = "com.apple.systempreferences"
}

/// What the macOS row (and its menu item) shows: the minor update when there is one, otherwise a newer major.
public struct MacOSUpdateNotice: Equatable, Sendable {
    public static let rowID = "im.patched.macos"
    public let update: MacOSUpdate
    public let runningVersion: String
    /// A newer major is also available alongside the minor update this notice is about.
    public let alsoMajor: MacOSUpdate?

    public init?(_ status: MacOSUpdateStatus) {
        guard let update = status.minor ?? status.major else { return nil }
        self.init(update: update, runningVersion: status.runningVersion, alsoMajor: status.minor == nil ? nil : status.major)
    }

    public init(update: MacOSUpdate, runningVersion: String, alsoMajor: MacOSUpdate? = nil) {
        self.update = update; self.runningVersion = runningVersion; self.alsoMajor = alsoMajor
    }

    /// What the row shows unless Not now hid it: the minor update first; with the minor hidden, the major on its own
    /// (in its quieter style); nil when both are hidden or there is nothing.
    public static func shown(_ status: MacOSUpdateStatus, hiddenKeys: [String]) -> MacOSUpdateNotice? {
        let primary = MacOSUpdateNotice(status)
        let majorAlone = status.minor == nil ? nil : status.major.map { MacOSUpdateNotice(update: $0, runningVersion: status.runningVersion) }
        return [primary, majorAlone].compactMap { $0 }.first { !hiddenKeys.contains($0.key) }
    }

    public var isMajor: Bool { update.kind == .major }
    /// Identity for "Not now" and for "have I told the user about this": the kind and the version.
    public var key: String { Self.key(update) }
    /// Built from the normalised version, so "27.2" and "27.2.0" are one key.
    static func key(_ update: MacOSUpdate) -> String {
        "im.patched.macos\u{1F}" + update.kind.rawValue + "\u{1F}" + (MacOSVersion(update.version)?.normalised ?? update.version)
    }

    /// "macOS 28 is available" for a major; "27.0.1 → 27.2.1" for an update.
    public var title: String {
        if isMajor { return String(localized: "macOS \(update.majorVersion.map(String.init) ?? update.version) is available") }
        return String(localized: "macOS \(update.version)")
    }
    public var versionChange: String { runningVersion + " → " + update.version }
    public var statusText: String {
        isMajor ? String(localized: "A new version of macOS. Upgrading is your choice; Patched won't remind you about it.")
                : String(localized: "Update available. Install it in Software Update.")
    }
    /// "Released 9 Nov 2026" when the posting date is known.
    public func postedText(locale: Locale = .current) -> String? {
        guard let day = update.postingDay else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateStyle = .medium; formatter.timeStyle = .none
        return String(localized: "Released \(formatter.string(from: day))")
    }
    public var alsoMajorText: String? {
        alsoMajor.map { String(localized: "macOS \($0.majorVersion.map(String.init) ?? $0.version) is also available.") }
    }
    /// The menu line: "macOS  27.0.1 → 27.2.1 — Software Update", or "macOS 28 is available".
    public var menuTitle: String {
        isMajor ? title : String(localized: "macOS  \(versionChange) — Software Update")
    }
}

extension MacOSUpdateNotice {
    /// The command line's `check` line about macOS. Plain text; `update` never acts on it.
    public static func commandLineLine(_ result: MacOSUpdateResult) -> String {
        guard case .found(let status) = result else { return "macOS: couldn't check (Apple's feed and Software Update's record were both unavailable)." }
        let from = status.source == .softwareUpdate ? " (from Software Update)" : ""
        var parts: [String] = []
        if let minor = status.minor {
            let build = minor.build.map { " (\($0))" } ?? ""
            let posted = minor.postingDate.map { ", released \($0)" } ?? ""
            parts.append("macOS \(status.runningVersion): UPDATE AVAILABLE \(minor.version)\(build)\(posted)\(from). Install it in System Settings > General > Software Update.")
        } else {
            parts.append("macOS \(status.runningVersion): up to date\(from).")
        }
        if let major = status.major {
            parts.append("macOS \(major.majorVersion.map(String.init) ?? major.version) is available (\(major.version)).")
        }
        return parts.joined(separator: " ")
    }
}

/// Which macOS notices "Not now" hid, per user: the minor and the major can each be hidden. The newest few are kept.
@MainActor public protocol MacOSUpdateHiding: AnyObject {
    var hiddenKeys: [String] { get set }
}

extension MacOSUpdateHiding {
    static var limit: Int { 8 }
    /// Adds one key, keeping only the newest `limit`.
    func hide(_ key: String) {
        hiddenKeys = Array((hiddenKeys.filter { $0 != key } + [key]).suffix(Self.limit))
    }
}

@MainActor public final class MemoryMacOSUpdateHiding: MacOSUpdateHiding {
    public var hiddenKeys: [String]
    public init(hiddenKeys: [String] = []) { self.hiddenKeys = hiddenKeys }
}

/// UserDefaults-backed, beside Patched's other per-user state. Under the test tripwire it keeps it in memory.
@MainActor public final class DefaultsMacOSUpdateHiding: MacOSUpdateHiding {
    static let key = "im.patched.macOSHiddenUpdates"
    private let memory = MemoryMacOSUpdateHiding()
    private var useMemory: Bool { RealStateTripwire.isActive }
    public init() {}
    public var hiddenKeys: [String] {
        get { useMemory ? memory.hiddenKeys : (UserDefaults.standard.stringArray(forKey: Self.key) ?? []) }
        set { if useMemory { memory.hiddenKeys = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.key) } }
    }
}
