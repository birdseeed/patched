import Foundation
import Darwin

// macOS updates: show and nudge, never install. Patched only reads two of Apple's own sources and reports what
// they say. Nothing here downloads, installs or runs anything, and nothing here can ask for admin rights. The
// only thing the client ever does with a result is open System Settings > Software Update on a click.

/// A macOS version as plain numbers ("27.2.1" is [27, 2, 1]). Only digits and single dots are accepted, at most
/// four parts, each at most six digits. Comparison is numeric, part by part, with missing parts counting as 0.
/// Leading zeros are accepted and dropped: "027.2" is 27.2 and is shown as "27.2".
public struct MacOSVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let description: String

    public init?(_ text: String) {
        guard text.range(of: "^[0-9]{1,6}(\\.[0-9]{1,6}){0,3}\\z", options: .regularExpression) != nil else { return nil }
        let numbers = text.split(separator: ".").compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        parts = numbers; description = numbers.map(String.init).joined(separator: ".")
    }

    /// The running system's version, from `ProcessInfo` (no file is read).
    public init(_ os: OperatingSystemVersion) {
        let text = os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)"
                                        : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        parts = [os.majorVersion, os.minorVersion, os.patchVersion]; description = text
    }

    public var major: Int { parts[0] }

    /// The version with trailing zero parts dropped ("27.2.0" is "27.2", "28.0" is "28"), so equal versions share one
    /// text form. Used for identities such as Not now and the notification record.
    public var normalised: String {
        var trimmed = parts
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        return trimmed.map(String.init).joined(separator: ".")
    }

    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    public static func < (lhs: MacOSVersion, rhs: MacOSVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) where lhs.part(index) != rhs.part(index) {
            return lhs.part(index) < rhs.part(index)
        }
        return false
    }
    /// "27.2" and "27.2.0" are the same version.
    public static func == (lhs: MacOSVersion, rhs: MacOSVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// One macOS release that applies to this Mac.
public struct MacOSUpdate: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// A newer version of the running major (27.0.1 to 27.2.1): an update, shown with reminders.
        case minor
        /// A newer major (27 to 28): shown as "macOS 28 is available", informational only, never reminded about.
        case major
    }
    /// Where the answer came from.
    public enum Source: String, Equatable, Sendable {
        /// Apple's public version feed, gdmf.apple.com.
        case appleFeed = "apple_feed"
        /// What Software Update itself last found (`/Library/Preferences/com.apple.SoftwareUpdate.plist`).
        case softwareUpdate = "software_update"
    }
    public let kind: Kind
    public let version: String
    /// The build, for example "26B131", when the source names one.
    public let build: String?
    /// Apple's posting date, "YYYY-MM-DD", when known (the feed has it, the plist does not).
    public let postingDate: String?
    public let source: Source

    public init(kind: Kind, version: String, build: String? = nil, postingDate: String? = nil, source: Source) {
        self.kind = kind; self.version = version; self.build = build; self.postingDate = postingDate; self.source = source
    }

    /// The posting date as midnight UTC on that day.
    public var postingDay: Date? { postingDate.flatMap(MacOSFeed.day) }
    public var majorVersion: Int? { MacOSVersion(version)?.major }
}

/// What the macOS check found. `minor` and `major` are both nil when this Mac is up to date as far as the
/// source can tell.
public struct MacOSUpdateStatus: Equatable, Sendable {
    public let runningVersion: String
    public let minor: MacOSUpdate?
    public let major: MacOSUpdate?
    public let source: MacOSUpdate.Source
    /// When Software Update last checked successfully, from its plist, when readable.
    public let lastSoftwareUpdateCheck: Date?

    public init(runningVersion: String, minor: MacOSUpdate?, major: MacOSUpdate?, source: MacOSUpdate.Source,
                lastSoftwareUpdateCheck: Date? = nil) {
        self.runningVersion = runningVersion; self.minor = minor; self.major = major; self.source = source
        self.lastSoftwareUpdateCheck = lastSoftwareUpdateCheck
    }
}

public enum MacOSUpdateResult: Equatable, Sendable {
    case found(MacOSUpdateStatus)
    /// Neither source could be used (the feed failed and the plist is missing or unreadable). Says nothing.
    case unavailable
}

/// This Mac, as the check sees it: the running version and the device ID Apple's feed lists.
public struct MacOSHost: Equatable, Sendable {
    public let runningVersion: MacOSVersion
    /// `sysctl hw.target`, for example "J604AP" on Apple silicon. nil when it cannot be read: the feed is then
    /// not used, because without it no entry can be matched to this Mac.
    public let deviceID: String?
    public init(runningVersion: MacOSVersion, deviceID: String?) { self.runningVersion = runningVersion; self.deviceID = deviceID }

    /// The real Mac: `ProcessInfo` and `sysctlbyname("hw.target")`. Reads no file and runs no command.
    public static func current() -> MacOSHost {
        MacOSHost(runningVersion: MacOSVersion(ProcessInfo.processInfo.operatingSystemVersion), deviceID: sysctlString("hw.target"))
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return MacOSFeed.isDeviceID(value) ? value : nil
    }
}

/// One entry of `PublicAssetSets.macOS` in Apple's feed, after strict parsing.
public struct MacOSFeedEntry: Equatable, Sendable {
    public let version: MacOSVersion
    public let build: String
    public let postingDate: String
    public let supportedDevices: Set<String>
}

/// `GET https://gdmf.apple.com/v2/pmv`, Apple's public list of OS versions. Untrusted metadata: only
/// `PublicAssetSets.macOS` is read, and in each entry only `ProductVersion`, `Build`, `PostingDate`,
/// `ExpirationDate` (optional; checked when present, otherwise unused) and `SupportedDevices`.
public enum MacOSFeed {
    public static let url = URL(string: "https://gdmf.apple.com/v2/pmv")!
    public static let host = "gdmf.apple.com"
    /// More entries than this, or more devices than this in one entry, and the feed is treated as malformed.
    static let maxEntries = 512
    static let maxDevices = 4096

    /// nil: the top level is not the expected shape (not JSON, not an object, no `PublicAssetSets.macOS` array,
    /// or over the size cap). An entry with a missing or wrongly typed field is dropped on its own.
    public static func parse(_ data: Data) -> [MacOSFeedEntry]? {
        guard data.count <= FetchLimits.macOSFeedBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = object["PublicAssetSets"] as? [String: Any],
              let list = sets["macOS"] as? [Any], list.count <= maxEntries else { return nil }
        return list.compactMap(entry)
    }

    static func entry(_ value: Any) -> MacOSFeedEntry? {
        guard let dict = value as? [String: Any],
              let versionText = dict["ProductVersion"] as? String, let version = MacOSVersion(versionText),
              let build = dict["Build"] as? String, isBuild(build),
              let posting = dict["PostingDate"] as? String, day(posting) != nil,
              let devices = dict["SupportedDevices"] as? [Any], devices.count <= maxDevices else { return nil }
        // Unused, and optional: a missing date keeps the entry, but one that is there must be a valid day.
        if let expiry = dict["ExpirationDate"] {
            guard let text = expiry as? String, day(text) != nil else { return nil }
        }
        var ids = Set<String>()
        for device in devices {
            guard let id = device as? String, isDeviceID(id) else { return nil }
            ids.insert(id)
        }
        return MacOSFeedEntry(version: version, build: build, postingDate: posting, supportedDevices: ids)
    }

    static func isBuild(_ text: String) -> Bool { text.range(of: "^[0-9A-Za-z]{1,20}\\z", options: .regularExpression) != nil }
    static func isDeviceID(_ text: String) -> Bool { text.range(of: "^[0-9A-Za-z,_-]{1,64}\\z", options: .regularExpression) != nil }

    /// "2026-11-09" as midnight UTC; nil for anything else, including impossible dates.
    static func day(_ text: String) -> Date? {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}\\z", options: .regularExpression) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = text.split(separator: "-").compactMap { Int($0) }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return date
    }

    /// From the entries that list `deviceID`: the newest version in the running major that is newer than the
    /// running one (`minor`), and the newest version in any higher major (`major`). When one version appears with
    /// several builds for this device, the first listed is kept.
    public static func select(_ entries: [MacOSFeedEntry], running: MacOSVersion, deviceID: String)
        -> (minor: MacOSUpdate?, major: MacOSUpdate?) {
        let mine = entries.filter { $0.supportedDevices.contains(deviceID) && $0.version > running }
        func newest(_ list: [MacOSFeedEntry]) -> MacOSFeedEntry? {
            list.reduce(nil) { best, next in best.map { next.version > $0.version ? next : $0 } ?? next }
        }
        func update(_ entry: MacOSFeedEntry?, _ kind: MacOSUpdate.Kind) -> MacOSUpdate? {
            entry.map { MacOSUpdate(kind: kind, version: $0.version.description, build: $0.build, postingDate: $0.postingDate, source: .appleFeed) }
        }
        return (update(newest(mine.filter { $0.version.major == running.major }), .minor),
                update(newest(mine.filter { $0.version.major > running.major }), .major))
    }
}

/// What `/Library/Preferences/com.apple.SoftwareUpdate.plist` says. It is world-readable and needs no network.
/// Only `RecommendedUpdates` (macOS entries only) and `LastSuccessfulDate` are read.
public struct SoftwareUpdatePlist: Equatable, Sendable {
    public struct Recommended: Equatable, Sendable {
        public let version: MacOSVersion
        public let build: String?
        public init(version: MacOSVersion, build: String?) { self.version = version; self.build = build }
    }
    public static let systemPath = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
    public static let maxBytes = 1024 * 1024

    public let recommended: [Recommended]
    public let lastSuccessfulDate: Date?

    /// nil when the file is missing, not a regular file, too large or not a dictionary plist.
    public static func read(at path: String) -> SoftwareUpdatePlist? {
        guard let data = boundedRead(path) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> SoftwareUpdatePlist? {
        guard data.count <= maxBytes,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any] else { return nil }
        var found: [Recommended] = []
        for case let item as [String: Any] in (dict["RecommendedUpdates"] as? [Any] ?? []).prefix(256) {
            let key = (item["Product Key"] as? String) ?? (item["Identifier"] as? String) ?? ""
            // Only macOS itself: Command Line Tools, Safari and other packages are left out.
            let isMSU = (item["MobileSoftwareUpdate"] as? Bool) == true || (item["MobileSoftwareUpdate"] as? Int) == 1
            guard isMSU || key.hasPrefix("MSU_UPDATE_"),
                  let text = item["Display Version"] as? String, let version = MacOSVersion(text) else { continue }
            found.append(Recommended(version: version, build: build(fromKey: key)))
        }
        return SoftwareUpdatePlist(recommended: found, lastSuccessfulDate: dict["LastSuccessfulDate"] as? Date)
    }

    /// "MSU_UPDATE_26B131_patch_27.2.1_minor" gives "26B131".
    static func build(fromKey key: String) -> String? {
        guard key.hasPrefix("MSU_UPDATE_") else { return nil }
        let rest = key.dropFirst("MSU_UPDATE_".count)
        guard let candidate = rest.split(separator: "_").first.map(String.init), MacOSFeed.isBuild(candidate) else { return nil }
        return candidate
    }

    /// Newer than running: the newest in the running major, and the newest in a higher major.
    public func select(running: MacOSVersion) -> (minor: MacOSUpdate?, major: MacOSUpdate?) {
        let newer = recommended.filter { $0.version > running }
        func newest(_ list: [Recommended]) -> Recommended? {
            list.reduce(nil) { best, next in best.map { next.version > $0.version ? next : $0 } ?? next }
        }
        func update(_ item: Recommended?, _ kind: MacOSUpdate.Kind) -> MacOSUpdate? {
            item.map { MacOSUpdate(kind: kind, version: $0.version.description, build: $0.build, source: .softwareUpdate) }
        }
        return (update(newest(newer.filter { $0.version.major == running.major }), .minor),
                update(newest(newer.filter { $0.version.major > running.major }), .major))
    }

    /// One descriptor; the file itself must not be a symlink (`O_NOFOLLOW`) and must be a regular file of at most `maxBytes`. The file is root-owned, so the
    /// owner check `BoundedFile` makes does not apply here.
    static func boundedRead(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maxBytes else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maxBytes - data.count + 1))
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            guard count <= maxBytes - data.count else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

/// The macOS check: one anonymous GET of Apple's feed, plus the Software Update plist. The feed's answer is
/// preferred. The plist's is shown alone when the feed cannot be reached or parsed, lists this Mac in no entry,
/// or this Mac's device ID is unknown. With neither, the result is `unavailable`.
public enum MacOSUpdateChecker {
    public static func check(host: MacOSHost, fetcher: any HTTPFetching, plistPath: String = SoftwareUpdatePlist.systemPath,
                             patchedVersion: String) async -> MacOSUpdateResult {
        var entries: [MacOSFeedEntry]?
        if host.deviceID != nil {
            if let data = try? await fetcher.fetch(MacOSFeed.url, maxBytes: FetchLimits.macOSFeedBytes, accept: "application/json",
                                                   userAgent: PatchedReleaseChecker.userAgent(version: patchedVersion),
                                                   allowedRedirectHosts: [MacOSFeed.host]) {
                entries = MacOSFeed.parse(data)
            }
        }
        return combine(feed: entries, plist: SoftwareUpdatePlist.read(at: plistPath), host: host)
    }

    /// Pure: what the two sources say, combined. `feed` is nil when the feed was not fetched or did not parse.
    public static func combine(feed: [MacOSFeedEntry]?, plist: SoftwareUpdatePlist?, host: MacOSHost) -> MacOSUpdateResult {
        let running = host.runningVersion
        // A feed that lists this Mac nowhere (not even for the version it runs) cannot speak for it.
        if let feed, let device = host.deviceID, feed.contains(where: { $0.supportedDevices.contains(device) }) {
            let (minor, major) = MacOSFeed.select(feed, running: running, deviceID: device)
            return .found(MacOSUpdateStatus(runningVersion: running.description, minor: minor, major: major, source: .appleFeed,
                                            lastSoftwareUpdateCheck: plist?.lastSuccessfulDate))
        }
        guard let plist else { return .unavailable }
        let (minor, major) = plist.select(running: running)
        return .found(MacOSUpdateStatus(runningVersion: running.description, minor: minor, major: major, source: .softwareUpdate,
                                        lastSoftwareUpdateCheck: plist.lastSuccessfulDate))
    }
}
