import Foundation

/// Maps the running macOS major version to Homebrew's release name (used to key cask `variations`).
enum MacOSName {
    static let byMajor: [Int: String] = [11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma",
                                         15: "sequoia", 26: "tahoe", 27: "golden_gate"]
    static func name(forMajor major: Int) -> String? {
        if let known = byMajor[major] { return known }
        // A release newer than this table: assume the newest known name rather than silently using the base cask.
        if let newest = byMajor.keys.max(), major > newest { return byMajor[newest] }
        return nil
    }
}

public enum HomebrewResolver {
    public static let apiBase = "https://formulae.brew.sh/api/cask/"

    public static func isValidToken(_ token: String) -> Bool {
        token.range(of: "^[a-z0-9][a-z0-9@+._-]{0,127}$", options: .regularExpression) != nil
    }

    public static func resolve(token: String, fetcher: any HTTPFetching, environment: HostEnvironment) async -> Result<UpdateOffer, RefusalReason> {
        guard isValidToken(token), let url = URL(string: apiBase + token + ".json") else {
            return .failure(.invalidSource("bad cask token \"\(token)\""))
        }
        let data: Data
        do { data = try await fetcher.fetch(url, maxBytes: FetchLimits.feedBytes) }
        catch let error as FetchError { return .failure(error.refusal) }
        catch { return .failure(.network(error.localizedDescription)) }
        return parse(data, token: token, environment: environment)
    }

    public static func parse(_ data: Data, token: String, environment: HostEnvironment) -> Result<UpdateOffer, RefusalReason> {
        guard data.count <= FetchLimits.feedBytes else { return .failure(.tooLarge) }
        guard var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.malformedFeed("cask JSON")) }
        let name = MacOSName.name(forMajor: environment.osMajor)
        let platform = name.map { environment.arch == .arm64 ? "arm64_\($0)" : $0 }
        if let platform, let variations = record["variations"] as? [String: [String: Any]], let variation = variations[platform] {
            for (key, value) in variation { record[key] = value }
        }
        if let supported = record["supported_platforms"] as? [String] {
            guard let platform, supported.contains(platform) else { return .failure(.noCompatibleItem) }
        }
        if let unsupported = record["unsupported_platforms"] as? [String], let platform, unsupported.contains(platform) { return .failure(.noCompatibleItem) }
        let depends = record["depends_on"] as? [String: Any]
        if let arches = depends?["arch"] as? [[String: Any]], !arches.contains(where: {
            ($0["type"] as? String) == (environment.arch == .arm64 ? "arm" : "intel") && ($0["bits"] as? Int) == 64
        }) { return .failure(.noCompatibleItem) }
        let version = record["version"] as? String, urlString = record["url"] as? String, sha = record["sha256"] as? String
        var minimum: String?
        if let requirements = depends?["macos"] as? [String: [String]] {
            for (op, versions) in requirements {
                var alternatives = false
                for required in versions {
                    let cmp = VersionComparator.compare(environment.osVersion, required)
                    let satisfied: Bool
                    switch op {
                    case ">=": satisfied = cmp != .orderedAscending; minimum = minimum ?? required
                    case ">": satisfied = cmp == .orderedDescending
                    case "<=": satisfied = cmp != .orderedDescending || environment.osVersion.hasPrefix(required + ".")
                    case "<": satisfied = cmp == .orderedAscending && !environment.osVersion.hasPrefix(required + ".")
                    case "==": satisfied = cmp == .orderedSame || environment.osVersion.hasPrefix(required + ".")
                    default: satisfied = true
                    }
                    if op == "==" { alternatives = alternatives || satisfied }
                    else if !satisfied { return .failure(.noCompatibleItem) }
                }
                if op == "==", !alternatives { return .failure(.noCompatibleItem) }
            }
        }

        guard let version, !version.isEmpty else { return .failure(.malformedFeed("cask has no version")) }
        if version == "latest" || version.rangeOfCharacter(from: .decimalDigits) == nil {
            return .failure(.unversioned("cask version is \"\(version)\""))
        }
        let parts = version.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let display = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let build = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        guard !display.isEmpty, display.rangeOfCharacter(from: .decimalDigits) != nil else {
            return .failure(.unversioned("cask version is \"\(version)\""))
        }
        guard let urlString, let downloadURL = URL(string: urlString) else { return .failure(.malformedFeed("cask has no URL")) }
        guard downloadURL.isHTTPS else { return .failure(.insecureDownload(urlString)) }

        var sha256: String?
        if let sha, sha != "no_check" {
            guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { return .failure(.malformedFeed("bad sha256")) }
            sha256 = sha.lowercased()
        }
        return .success(UpdateOffer(displayVersion: display, buildVersion: (build?.isEmpty ?? true) ? nil : build,
                                    downloadURL: downloadURL, sha256: sha256, minimumSystemVersion: minimum,
                                    format: ArtifactFormat.infer(from: downloadURL),
                                    source: .homebrewCask(token: token)))
    }
}

// MARK: - Cask index

/// Collects the reasoning behind a source decision for `patched check --explain`.
final class ExplainTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}

/// How directly a cask's uninstall/zap stanzas tie it to a bundle ID.
public enum EvidenceStrength: Int, Sendable, Comparable, CustomStringConvertible {
    /// Appears in a zap path (a preferences file, a container), as a whole dotted token.
    case weak = 1
    /// Appears as a whole dotted token in another `uninstall` entry (pkgutil receipt and so on).
    case medium = 2
    /// Is exactly an `uninstall` quit target, signal target or launchctl label.
    case strong = 3
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { switch self { case .weak: return "weak"; case .medium: return "medium"; case .strong: return "strong" } }
}

/// What a cask says about itself, for tie-breaking.
struct CaskMeta: Equatable, Sendable {
    var names: [String] = []        // normalised display names
    var appNames: [String] = []     // normalised `app` artifact names, without ".app"
    var pkgNames: [String] = []     // normalised `pkg` artifact names, without ".pkg"
    var words: Set<String> = []     // identifying words from the token and names
    var normalisedToken = ""
    var appCount = 0
}

/// Filename matching is a fallback. Declared product identities must match exactly. When the filename finds nothing,
/// the bundle ID is matched against the bundle IDs the casks' uninstall and zap stanzas mention.
public struct CaskIndex: Sendable, Equatable {
    private let tokensByApp: [String: [String]]
    private let identities: [String: Set<String>]
    /// lower-cased bundle ID -> token -> strongest evidence.
    private let evidence: [String: [String: EvidenceStrength]]
    /// token -> lower-cased bundle IDs it mentions.
    private let idsByToken: [String: Set<String>]
    private let meta: [String: CaskMeta]

    public init(tokensByApp: [String: [String]]) {
        self.tokensByApp = tokensByApp; identities = [:]; evidence = [:]; idsByToken = [:]; meta = [:]
    }

    static func normalise(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
    private static let genericWords: Set<String> = ["app", "apps", "desktop", "mac", "macos", "helper", "agent", "client", "standard",
                                                    "software", "cask", "free", "pro", "plus", "lite", "beta", "user", "tool", "tools"]
    /// Lower-case words of at least four letters, split on punctuation and camelCase.
    static func words(_ text: String) -> Set<String> {
        var spaced = ""
        var previousLower = false
        for ch in text {
            if ch.isUppercase && previousLower { spaced.append(" ") }
            spaced.append(ch)
            previousLower = ch.isLowercase || ch.isNumber
        }
        let parts = spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(parts.filter { $0.count >= 4 && !genericWords.contains($0) })
    }

    private static let patternCharacters = CharacterSet(charactersIn: "[]?*\\{}()|+^$")
    private static let idPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+){2,}")
    private static let fileSuffixes: Set<String> = ["plist", "savedstate", "binarycookies", "sfl", "sfl2", "sfl3", "lockfile"]
    /// Dotted tokens (at least three components) found in `text`, plus the variants without a trailing file suffix or a
    /// leading Apple team ID. A token followed by `*` is a glob prefix, not an identity, and is skipped.
    static func dottedTokens(in text: String) -> [String] {
        let ns = text as NSString
        var found: [String] = []
        for match in idPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = match.range.location + match.range.length
            let rest = ns.substring(from: end)
            if rest.hasPrefix("*") || rest.hasPrefix(".*") { continue }
            var token = ns.substring(with: match.range)
            var variants = [token]
            var parts = token.split(separator: ".").map(String.init)
            if parts.count > 3, fileSuffixes.contains(parts.last!.lowercased()) { parts.removeLast(); token = parts.joined(separator: "."); variants.append(token) }
            if parts.count > 3, parts[0].range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
                variants.append(parts.dropFirst().joined(separator: "."))
            }
            found += variants
        }
        return found
    }

    public init(decoding data: Data) throws {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CatalogueError(message: "invalid index") }
        var map: [String: [String]] = [:], ids: [String: Set<String>] = [:]
        var evidence: [String: [String: EvidenceStrength]] = [:], idsByToken: [String: Set<String>] = [:], metas: [String: CaskMeta] = [:]
        func strings(_ value: Any) -> [String] {
            if let s = value as? String { return [s] }
            if let a = value as? [Any] { return a.flatMap(strings) }
            if let d = value as? [String: Any], let t = d["target"] { return strings(t) }
            return []
        }
        func bundleID(_ value: String) -> Bool { BundleIDSyntax.isValid(value) }
        for entry in entries {
            guard let token = entry["token"] as? String, entry["deprecated"] as? Bool != true, entry["disabled"] as? Bool != true else { continue }
            var declared: Set<String> = []
            var info = CaskMeta()
            info.normalisedToken = Self.normalise(token)
            let names = strings(entry["name"] ?? [])
            info.names = names.map(Self.normalise)
            info.words = Self.words(token.replacingOccurrences(of: "-", with: " ")).union(names.flatMap { Self.words($0) })
            func note(_ id: String, _ strength: EvidenceStrength) {
                let key = id.lowercased()
                if (evidence[key]?[token] ?? .weak) < strength || evidence[key]?[token] == nil { evidence[key, default: [:]][token] = strength }
                idsByToken[token, default: []].insert(key)
            }
            for artifact in entry["artifacts"] as? [[String: Any]] ?? [] {
                for app in strings(artifact["app"] ?? []) {
                    map[(app as NSString).lastPathComponent, default: []].append(token)
                    info.appCount += 1
                    info.appNames.append(Self.normalise(((app as NSString).lastPathComponent as NSString).deletingPathExtension))
                }
                for pkg in (artifact["pkg"] as? [Any] ?? []).prefix(1) {
                    for name in strings(pkg) { info.pkgNames.append(Self.normalise((name as NSString).deletingPathExtension)) }
                }
                for kind in ["uninstall", "zap"] {
                    for rules in artifact[kind] as? [[String: Any]] ?? [] {
                        for key in ["quit", "launchctl", "pkgutil"] {
                            for value in strings(rules[key] ?? []) {
                                if bundleID(value) || key == "pkgutil" && value.contains(".") { declared.insert(value) }
                            }
                        }
                        if let signals = rules["signal"] as? [Any] {
                            // Real casks write `["TERM", "id"]`; older ones a list of such pairs.
                            for value in signals.flatMap(strings) where bundleID(value) { declared.insert(value) }
                        }
                        for path in strings(rules["trash"] ?? []) where path.contains("/Preferences/") && path.hasSuffix(".plist") {
                            let value = String((path as NSString).lastPathComponent.dropLast(6))
                            if bundleID(value) { declared.insert(value) }
                        }
                        // Evidence for bundle-ID matching.
                        for (key, value) in rules {
                            let exactKey = kind == "uninstall" && ["quit", "launchctl", "signal"].contains(key)
                            for text in strings(value) {
                                // A glob or regex is a pattern, not an identity: never extract a prefix from one.
                                if text.rangeOfCharacter(from: Self.patternCharacters) != nil { continue }
                                if exactKey, bundleID(text) { note(text, .strong) }
                                for id in Self.dottedTokens(in: text) { note(id, kind == "uninstall" ? .medium : .weak) }
                            }
                        }
                    }
                }
            }
            ids[token] = declared
            metas[token] = info
        }
        tokensByApp = map; identities = ids; self.evidence = evidence; self.idsByToken = idsByToken; meta = metas
    }
    public func token(forAppNamed name: String) -> String? {
        guard let tokens = tokensByApp[name] else { return nil }
        let unique = Set(tokens)
        if unique.count == 1 { return unique.first }
        let stable = unique.filter { !$0.contains("@") }
        guard stable.count == 1, let base = stable.first, unique.allSatisfy({ $0 == base || $0.hasPrefix(base + "@") }) else { return nil }
        return base
    }
    public func match(forAppNamed name: String, bundleID: String?) -> (token: String, lowConfidence: Bool)? {
        guard let token = token(forAppNamed: name) else { return nil }
        let ids = identities[token] ?? []
        if !ids.isEmpty { guard let bundleID, ids.contains(bundleID) else { return nil } }
        return (token, ids.isEmpty)
    }

    /// One cask that mentions an app's bundle ID, with the reasons it ranks where it does.
    public struct BundleCandidate: Sendable, Equatable {
        public let token: String
        public let strength: EvidenceStrength
        /// The cask name, an `app` artifact or the `pkg` matches the installed app's name.
        public let nameMatch: Bool
        /// The cask's token or names share an identifying word with the app or its bundle ID.
        public let affinity: Bool
        /// Stricter than `affinity`: the cask is bound to the installed app by name (its token or name is the app's name,
        /// its token is contained in the app name or bundle ID, or every identifying word of the app's name is the cask's).
        public let nameAffinity: Bool
        /// 0 for a single-app cask; 1 for each of: mentions several installed apps' bundle IDs, has many app artifacts.
        public let suitePenalty: Int
        fileprivate var key: [Int] { [affinity ? 1 : 0, strength.rawValue, nameMatch ? 1 : 0, -suitePenalty] }
    }

    /// Candidates for a bundle ID, best first.
    public func bundleCandidates(appName: String, bundleID: String, installedBundleIDs: Set<String>) -> [BundleCandidate] {
        let id = bundleID.lowercased()
        let appStem = Self.normalise((appName as NSString).deletingPathExtension)
        let haystack = Self.normalise(bundleID)
        let appWords = Self.words((appName as NSString).deletingPathExtension).union(Self.words(bundleID))
        let installed = Set(installedBundleIDs.map { $0.lowercased() })
        let list = (evidence[id] ?? [:]).map { token, strength -> BundleCandidate in
            let info = meta[token] ?? CaskMeta()
            let nameMatch = !appStem.isEmpty && (info.names.contains(appStem) || info.appNames.contains(appStem)
                || info.pkgNames.contains(where: { $0 == appStem || appStem.count >= 6 && $0.hasPrefix(appStem) }))
            let token5 = info.normalisedToken
            let affinity = nameMatch || !info.words.isDisjoint(with: appWords)
                || token5.count >= 5 && (appStem.contains(token5) || haystack.contains(token5))
            let appNameWords = Self.words((appName as NSString).deletingPathExtension)
            let nameAffinity = nameMatch || token5.count >= 5 && (appStem.contains(token5) || haystack.contains(token5))
                || !appNameWords.isEmpty && appNameWords.isSubset(of: info.words)
            let siblings = installed.filter { idsByToken[token]?.contains($0) == true }.count
            let penalty = (siblings > 1 ? 1 : 0) + (info.appCount > 3 ? 1 : 0)
            return BundleCandidate(token: token, strength: strength, nameMatch: nameMatch, affinity: affinity, nameAffinity: nameAffinity, suitePenalty: penalty)
        }
        return list.sorted { $0.key != $1.key ? $0.key.lexicographicallyPrecedes($1.key) == false : $0.token < $1.token }
    }

    /// The single best cask for a bundle ID, or nil when nothing mentions it or the top two cannot be told apart.
    public func bundleMatch(appName: String, bundleID: String, installedBundleIDs: Set<String> = []) -> (token: String, strength: EvidenceStrength)? {
        let ranked = bundleCandidates(appName: appName, bundleID: bundleID, installedBundleIDs: installedBundleIDs)
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].key == best.key { return nil }
        return (best.token, best.strength)
    }

    /// Filename match first (it confirms against declared identities), then bundle-ID evidence.
    /// Weak-only bundle matches are low confidence: shown, but not installable without a catalogue entry.
    public func match(for app: InstalledApp, installedBundleIDs: Set<String> = []) -> (token: String, lowConfidence: Bool)? {
        match(for: app, installedBundleIDs: installedBundleIDs, trace: nil)
    }
    func match(for app: InstalledApp, installedBundleIDs: Set<String>, trace: ExplainTrace?) -> (token: String, lowConfidence: Bool)? {
        if let found = match(forAppNamed: app.bundleFileName, bundleID: app.bundleID) {
            trace?.add("Homebrew: app filename \(app.bundleFileName) -> cask \(found.token)" + (found.lowConfidence ? " (no declared identity to confirm it: low confidence)" : " (confirmed by a declared bundle ID)"))
            return found
        }
        if let token = token(forAppNamed: app.bundleFileName) {
            trace?.add("Homebrew: app filename \(app.bundleFileName) -> cask \(token), rejected: bundle ID \(app.bundleID ?? "none") is not one the cask declares")
        } else if tokensByApp[app.bundleFileName] != nil {
            trace?.add("Homebrew: app filename \(app.bundleFileName) is claimed by several casks; not guessing")
        } else {
            trace?.add("Homebrew: no cask installs an app named \(app.bundleFileName)")
        }
        guard let bundleID = app.bundleID else { trace?.add("Homebrew: no bundle ID to match"); return nil }
        let ranked = bundleCandidates(appName: app.bundleFileName, bundleID: bundleID, installedBundleIDs: installedBundleIDs)
        guard !ranked.isEmpty else { trace?.add("Homebrew: no cask mentions bundle ID \(bundleID)"); return nil }
        for candidate in ranked {
            trace?.add("Homebrew: candidate \(candidate.token): \(candidate.strength) evidence, affinity=\(candidate.affinity), name match=\(candidate.nameMatch), suite penalty=\(candidate.suitePenalty)")
        }
        guard let best = bundleMatch(appName: app.bundleFileName, bundleID: bundleID, installedBundleIDs: installedBundleIDs) else {
            trace?.add("Homebrew: the top candidates tie; no match")
            return nil
        }
        // A bundle-ID match is a suggestion, not authority: it is installable only when the cask is also bound to the app
        // by name and the evidence is at least medium.
        let chosen = ranked.first { $0.token == best.token }
        let trusted = chosen?.nameAffinity == true && best.strength >= .medium
        trace?.add("Homebrew: chose \(best.token) by bundle ID (\(best.strength), name affinity=\(chosen?.nameAffinity == true))"
                   + (trusted ? "" : "; not confirmed by name and strong/medium evidence, so low confidence"))
        return (best.token, !trusted)
    }
}

public protocol CaskIndexProviding: Sendable {
    func index() async -> Result<CaskIndex, RefusalReason>
}

/// Downloads `cask.json`, keeps it under the cache directory for 24 hours, and builds a `CaskIndex`.
public actor CaskIndexProvider: CaskIndexProviding {
    public static let url = URL(string: "https://formulae.brew.sh/api/cask.json")!
    public static let ttl: TimeInterval = 24 * 60 * 60
    private let fetcher: any HTTPFetching
    private let cacheFile: URL
    private let now: @Sendable () -> Date
    private var memo: Result<CaskIndex, RefusalReason>?

    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Patched/Updater", isDirectory: true)
    }

    public init(fetcher: any HTTPFetching, cacheDirectory: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        // Under the real-state tripwire the default cache is not used: no cache file means no real read or write.
        let directory: URL
        if let cacheDirectory { directory = cacheDirectory }
        else if RealStateTripwire.isActive {
            try? RealStateTripwire.check("default cask index cache")
            directory = URL(fileURLWithPath: "/dev/null/patched-forbidden-cache", isDirectory: true)
        } else { directory = CaskIndexProvider.defaultCacheDirectory }
        self.cacheFile = directory.appendingPathComponent("cask-index.json")
        self.now = now
    }

    public func index() async -> Result<CaskIndex, RefusalReason> {
        if let memo { return memo }
        let result = await load()
        memo = result
        return result
    }

    private func cached() -> (data: Data, fresh: Bool)? {
        guard let file = try? BoundedFile.read(cacheFile, maxBytes: FetchLimits.caskIndexBytes), !file.data.isEmpty else { return nil }
        return (file.data, now().timeIntervalSince(file.modified) < Self.ttl)
    }

    private func load() async -> Result<CaskIndex, RefusalReason> {
        let cache = cached()
        if let cache, cache.fresh, let index = try? CaskIndex(decoding: cache.data) { return .success(index) }
        do {
            let data = try await fetcher.fetch(Self.url, maxBytes: FetchLimits.caskIndexBytes)
            let index: CaskIndex
            do { index = try CaskIndex(decoding: data) } catch { return .failure(.malformedFeed("cask index")) }
            store(data)
            return .success(index)
        } catch {
            // Offline or blocked: a stale cache is still better than no Homebrew matching at all.
            if let cache, let index = try? CaskIndex(decoding: cache.data) { return .success(index) }
            return .failure((error as? FetchError)?.refusal ?? .network(error.localizedDescription))
        }
    }

    private func store(_ data: Data) {
        let directory = cacheFile.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: cacheFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
    }
}
