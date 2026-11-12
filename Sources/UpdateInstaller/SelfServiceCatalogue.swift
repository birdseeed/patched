import Foundation
import UpdateSources

// Self Service: a catalogue of approved apps, delivered by MDM as the forced managed preference
// `SelfServiceCatalogue` for `im.patched.app`. A standard user may install these into ~/Applications. Each entry
// pins its developer's Team ID, which is the trust anchor for a fresh install (there is no installed app to compare
// with). Parsing is strict and works entry by entry, and touches no network.

/// Bounds on what a catalogue may contain. Anything beyond them is refused rather than truncated.
public enum SelfServiceLimits {
    public static let maxEntries = 500
    public static let nameBytes = 128
    public static let descriptionBytes = 512
    public static let categoryBytes = 64
    public static let urlBytes = 2048
    public static let bundleIDBytes = 255
}

/// One valid catalogue entry.
public struct SelfServiceEntry: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case sparkle(feed: URL)
        case homebrewCask(token: String)

        public var updateSource: UpdateSource {
            switch self {
            case .sparkle(let feed): return .sparkle(feed: feed)
            case .homebrewCask(let token): return .homebrewCask(token: token)
            }
        }
    }

    public let name: String
    public let description: String?
    public let category: String?
    /// The developer's Apple Team ID. A fresh install must be signed by this team.
    public let teamID: String
    /// When given, the installed app must have exactly this bundle ID.
    public let bundleID: String?
    public let source: Source
    /// Shown, never installed: the app expects /Applications, which needs admin rights.
    public let needsAdmin: Bool

    public init(name: String, description: String? = nil, category: String? = nil, teamID: String, bundleID: String? = nil,
                source: Source, needsAdmin: Bool = false) {
        self.name = name; self.description = description; self.category = category; self.teamID = teamID
        self.bundleID = bundleID; self.source = source; self.needsAdmin = needsAdmin
    }
}

/// One row of the catalogue as the organisation wrote it: a valid entry, or the reason it cannot be used.
public struct SelfServiceCatalogueItem: Sendable, Equatable, Identifiable {
    public enum Validity: Sendable, Equatable {
        case valid(SelfServiceEntry)
        /// Plain English, for the row.
        case invalid(reason: String)
    }
    /// Stable for the same entry at the same position, so a listed row can be matched again at install time.
    public let id: String
    /// Position in the managed array, from 0.
    public let index: Int
    /// The entry's name when it had a usable one, otherwise "Entry <n>".
    public let name: String
    public let validity: Validity

    public var entry: SelfServiceEntry? { if case .valid(let entry) = validity { return entry }; return nil }
}

/// What the managed preferences say about the catalogue.
public enum SelfServiceCatalogue: Sendable, Equatable {
    public static let preferenceKey = "SelfServiceCatalogue"

    /// No catalogue is forced on this Mac (a value the user set themselves does not count).
    case notManaged
    /// A catalogue is forced, but it is not an array of dictionaries, or it has too many entries. Nothing is offered.
    case invalid(reason: String)
    case items([SelfServiceCatalogueItem])

    public static let invalidCatalogueReason = String(localized: "Your organisation's Self Service catalogue could not be read. It must be a list of entries, with at most \(SelfServiceLimits.maxEntries).")

    public var items: [SelfServiceCatalogueItem] { if case .items(let items) = self { return items }; return [] }

    /// A catalogue is set and every entry in it is valid.
    public var isFullyValid: Bool {
        if case .items(let items) = self { return items.allSatisfy { $0.entry != nil } }
        return false
    }

    /// Plain lines for `patched catalogue list`, so an administrator can check a profile.
    public var listing: [String] {
        switch self {
        case .notManaged:
            return ["No Self Service catalogue is set on this Mac. Only a configuration profile can set one: a forced \(Self.preferenceKey) array for \(SystemManagedPreferences.applicationID)."]
        case .invalid(let reason):
            return [reason]
        case .items(let items):
            let invalid = items.filter { $0.entry == nil }.count
            var lines = ["Self Service catalogue: \(items.count) \(items.count == 1 ? "entry" : "entries"), \(invalid) invalid."]
            for item in items {
                switch item.validity {
                case .valid(let entry):
                    let source: String
                    switch entry.source {
                    case .sparkle(let feed): source = "Sparkle " + feed.absoluteString
                    case .homebrewCask(let token): source = "Homebrew " + token
                    }
                    let bundle = entry.bundleID.map { ", bundle ID \($0)" } ?? ""
                    let admin = entry.needsAdmin ? ", needs admin rights (shown, not installed)" : ""
                    lines.append("\(item.index + 1). \(entry.name): valid. Team ID \(entry.teamID)\(bundle), \(source)\(admin)")
                    if entry.bundleID == nil {
                        lines.append("   Warning: no BundleID, so any app signed and notarised by Team ID \(entry.teamID) can be installed for this entry. Add BundleID.")
                    }
                case .invalid(let reason):
                    lines.append("\(item.index + 1). \(item.name): invalid. \(reason)")
                }
            }
            return lines
        }
    }

    /// Reads the forced `SelfServiceCatalogue` key. Under the test tripwire the system reader reports nothing forced.
    public static func load(from managed: ManagedPreferences = ManagedPreferences()) -> SelfServiceCatalogue {
        switch managed.array(preferenceKey, parse: parse(array:)) {
        case .notManaged: return .notManaged
        case .invalid: return .invalid(reason: invalidCatalogueReason)
        case .value(let catalogue): return catalogue
        }
    }

    /// nil when the array as a whole is unusable (too many entries); otherwise one item per element.
    public static func parse(array: [Any]) -> SelfServiceCatalogue? {
        guard array.count <= SelfServiceLimits.maxEntries else { return nil }
        return .items(array.enumerated().map { index, element in item(element, index: index) })
    }

    static func item(_ element: Any, index: Int) -> SelfServiceCatalogueItem {
        let fallbackName = String(localized: "Entry \(index + 1)")
        guard let dictionary = element as? [String: Any], CFGetTypeID(element as CFTypeRef) == CFDictionaryGetTypeID() else {
            return SelfServiceCatalogueItem(id: "\(index):invalid", index: index, name: fallbackName,
                                            validity: .invalid(reason: String(localized: "This entry is not a dictionary.")))
        }
        // A usable name for the row even when something else is wrong.
        let shownName = (dictionary["Name"] as? String).flatMap { cleanText($0, limit: SelfServiceLimits.nameBytes) } ?? fallbackName
        switch entry(dictionary) {
        case .success(let entry):
            return SelfServiceCatalogueItem(id: "\(index):\(entry.teamID):\(entry.source.updateSource.locator)", index: index,
                                            name: entry.name, validity: .valid(entry))
        case .failure(let problem):
            return SelfServiceCatalogueItem(id: "\(index):invalid", index: index, name: shownName,
                                            validity: .invalid(reason: problem.reason))
        }
    }

    struct Problem: Error { let reason: String }

    static let knownKeys: Set<String> = ["Name", "Description", "Category", "TeamID", "BundleID", "SparkleFeedURL", "HomebrewCask", "NeedsAdmin"]

    /// Strict: every key must be known and every value of the right type and form. A misspelt key (say `BundleId`)
    /// would otherwise silently drop a check, so it makes the entry invalid.
    static func entry(_ d: [String: Any]) -> Result<SelfServiceEntry, Problem> {
        func fail(_ reason: String) -> Result<SelfServiceEntry, Problem> { .failure(Problem(reason: reason)) }
        if let unknown = d.keys.filter({ !knownKeys.contains($0) }).sorted().first {
            // The key name is the organisation's text: shown only when it is plain, short and on one line.
            let shown = cleanText(unknown, limit: 64) ?? String(localized: "(a name that cannot be shown)")
            return fail(String(localized: "This entry has a key Patched does not know: \(shown). Check its spelling."))
        }
        /// Present and a string (nil value: absent; .some(nil): present but not a string).
        func string(_ key: String) -> String?? {
            guard let raw = d[key] else { return .none }
            guard CFGetTypeID(raw as CFTypeRef) == CFStringGetTypeID(), let text = raw as? String else { return .some(nil) }
            return .some(text)
        }

        guard case .some(let rawName) = string("Name") else { return fail(String(localized: "This entry has no Name.")) }
        guard let rawName, let name = cleanText(rawName, limit: SelfServiceLimits.nameBytes) else {
            return fail(String(localized: "The Name must be text of 1 to \(SelfServiceLimits.nameBytes) characters, on one line."))
        }

        var description: String?
        if case .some(let raw) = string("Description") {
            guard let raw, let text = cleanText(raw, limit: SelfServiceLimits.descriptionBytes) else {
                return fail(String(localized: "The Description must be text of at most \(SelfServiceLimits.descriptionBytes) characters, on one line."))
            }
            description = text
        }
        var category: String?
        if case .some(let raw) = string("Category") {
            guard let raw, let text = cleanText(raw, limit: SelfServiceLimits.categoryBytes) else {
                return fail(String(localized: "The Category must be text of at most \(SelfServiceLimits.categoryBytes) characters, on one line."))
            }
            category = text
        }

        guard case .some(let rawTeam) = string("TeamID") else { return fail(String(localized: "This entry has no TeamID.")) }
        guard let team = rawTeam, TeamIdentifier.isValid(team) else {
            return fail(String(localized: "The TeamID is not a valid Apple Team ID (ten capital letters or digits)."))
        }

        var bundleID: String?
        if case .some(let raw) = string("BundleID") {
            guard let raw, raw.utf8.count <= SelfServiceLimits.bundleIDBytes, BundleFacts.isSafeBundleID(raw), raw.contains(".") else {
                return fail(String(localized: "The BundleID is not a valid bundle identifier."))
            }
            bundleID = raw
        }

        let feed = string("SparkleFeedURL"), cask = string("HomebrewCask")
        let source: SelfServiceEntry.Source
        switch (feed, cask) {
        case (.some, .some):
            return fail(String(localized: "This entry has both a SparkleFeedURL and a HomebrewCask. Give exactly one."))
        case (.none, .none):
            return fail(String(localized: "This entry has no source. Give a SparkleFeedURL or a HomebrewCask."))
        case (.some(let raw), .none):
            guard let raw, let url = sparkleFeed(raw) else {
                return fail(String(localized: "The SparkleFeedURL must be a plain https address with no user name or password in it."))
            }
            source = .sparkle(feed: url)
        case (.none, .some(let raw)):
            guard let raw, HomebrewResolver.isValidToken(raw) else {
                return fail(String(localized: "The HomebrewCask is not a valid Homebrew cask name."))
            }
            source = .homebrewCask(token: raw)
        }

        var needsAdmin = false
        if let raw = d["NeedsAdmin"] {
            guard CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID(), let flag = raw as? Bool else {
                return fail(String(localized: "NeedsAdmin must be true or false."))
            }
            needsAdmin = flag
        }
        return .success(SelfServiceEntry(name: name, description: description, category: category, teamID: team,
                                         bundleID: bundleID, source: source, needsAdmin: needsAdmin))
    }

    /// Trimmed, non-empty, within `limit` UTF-8 bytes, and free of control characters (so one line).
    static func cleanText(_ raw: String, limit: Int) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= limit,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            return nil
        }
        return text
    }

    /// https only, with a host, no credentials, no whitespace or control characters, within the length limit.
    static func sparkleFeed(_ raw: String) -> URL? {
        guard raw.utf8.count <= SelfServiceLimits.urlBytes,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, !raw.contains("@") else { return nil }
        return url
    }
}

/// Finds the newest version of a catalogue entry. Runs only when the user chooses Install: listing never calls it.
/// Uses the same Sparkle and Homebrew resolvers as update checks, with no installed version to compare against.
public enum SelfServiceResolver {
    public static func resolve(_ entry: SelfServiceEntry, fetcher: any HTTPFetching,
                               environment: HostEnvironment = .current) async -> Result<UpdateOffer, RefusalReason> {
        switch entry.source {
        case .sparkle(let feed): return await SparkleResolver.resolve(feed: feed, fetcher: fetcher, environment: environment)
        case .homebrewCask(let token): return await HomebrewResolver.resolve(token: token, fetcher: fetcher, environment: environment)
        }
    }
}
