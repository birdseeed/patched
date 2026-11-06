import Foundation

/// Port of Sparkle's `SUStandardVersionComparator`: versions are split into runs of
/// digits, separators (whitespace/punctuation) and other characters; digit runs compare
/// numerically, a trailing alphabetic run ("b1") sorts below the bare version.
public enum VersionComparator {
    private enum Kind { case number, string, period, punctuation, whitespace, dash
        var separator: Bool { self == .period || self == .punctuation || self == .whitespace }
    }
    private static func kind(_ s: String) -> Kind {
        let c = (s as NSString).character(at: 0)
        if c == 46 { return .period }; if c == 45 { return .dash }
        if (CharacterSet.decimalDigits as NSCharacterSet).characterIsMember(c) { return .number }
        if (CharacterSet.whitespacesAndNewlines as NSCharacterSet).characterIsMember(c) { return .whitespace }
        if (CharacterSet.punctuationCharacters as NSCharacterSet).characterIsMember(c) { return .punctuation }
        return .string
    }
    private static func split(_ value: String) -> [String] {
        let s = value as NSString
        guard s.length > 0 else { return [] }
        var run = s.substring(to: 1), old = kind(run), result: [String] = []
        for i in 1..<s.length {
            let character = s.substring(with: NSRange(location: i, length: 1)), next = kind(character)
            if next == .dash { break }
            if old != next || old.separator { result.append(run); run = character } else { run += character }
            old = next
        }
        result.append(run); return result
    }
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        var a = split(lhs), b = split(rhs)
        func prefix(_ parts: [String]) -> Int { parts.prefix { kind($0) == .number || kind($0) == .period }.count }
        let ac = prefix(a), bc = prefix(b)
        if ac < bc { for i in ac..<bc { a.insert(kind(b[i]) == .period ? "." : "0", at: i) } }
        if bc < ac { for i in bc..<ac { b.insert(kind(a[i]) == .period ? "." : "0", at: i) } }
        let n = min(a.count, b.count)
        for i in 0..<n {
            let ka = kind(a[i]), kb = kind(b[i])
            if ka == kb || (ka.separator && kb.separator) {
                if ka == .number {
                    let x = (a[i] as NSString).longLongValue, y = (b[i] as NSString).longLongValue
                    if x != y { return x < y ? .orderedAscending : .orderedDescending }
                } else if ka == .string {
                    let result = (a[i] as NSString).compare(b[i]); if result != .orderedSame { return result }
                }
            } else {
                if kb == .string { return .orderedDescending }
                if ka == .string { return .orderedAscending }
                return ka == .number ? .orderedDescending : .orderedAscending
            }
        }
        if a.count == b.count { return .orderedSame }
        let longerA = a.count > b.count
        let stringExtra = kind((longerA ? a : b)[n]) == .string
        return longerA != stringExtra ? .orderedDescending : .orderedAscending
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    /// Strips a cosmetic "v", "Version " or "Build " prefix ("Build 4215" -> "4215") before comparing
    /// display versions that come from different publishers. Sparkle build numbers are compared as-is.
    public static func stripDecoration(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "^(?:version|build|ver\\.?|v)\\s*(?=[0-9])", options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        return String(trimmed[range.upperBound...])
    }
}

/// Strict SemVer 2 precedence for Electron, with Sparkle compatibility for other publisher versions.
enum ElectronVersionComparator {
    private struct Version {
        let core: [String]
        let prerelease: [String]
        init?(_ value: String) {
            let pattern = "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?$"
            guard let match = value.range(of: pattern, options: .regularExpression),
                  match == value.startIndex..<value.endIndex else { return nil }
            let precedence = value.split(separator: "+", maxSplits: 1)[0]
            let pieces = precedence.split(separator: "-", maxSplits: 1)
            core = pieces[0].split(separator: ".").map(String.init)
            prerelease = pieces.count == 2 ? pieces[1].split(separator: ".").map(String.init) : []
            guard prerelease.allSatisfy({ !$0.allSatisfy(\.isNumber) || $0.count == 1 || !$0.hasPrefix("0") }) else { return nil }
        }
    }
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let a = Version(lhs), let b = Version(rhs) else { return VersionComparator.compare(lhs, rhs) }
        func numeric(_ x: String, _ y: String) -> ComparisonResult {
            if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        for (x, y) in zip(a.core, b.core) { let c = numeric(x, y); if c != .orderedSame { return c } }
        if a.prerelease.isEmpty || b.prerelease.isEmpty {
            if a.prerelease.isEmpty == b.prerelease.isEmpty { return .orderedSame }
            return a.prerelease.isEmpty ? .orderedDescending : .orderedAscending
        }
        for (x, y) in zip(a.prerelease, b.prerelease) {
            let xn = x.allSatisfy(\.isNumber), yn = y.allSatisfy(\.isNumber)
            let c: ComparisonResult
            if xn && yn { c = numeric(x, y) }
            else if xn != yn { c = xn ? .orderedAscending : .orderedDescending }
            else { c = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
            if c != .orderedSame { return c }
        }
        return a.prerelease.count == b.prerelease.count ? .orderedSame : (a.prerelease.count < b.prerelease.count ? .orderedAscending : .orderedDescending)
    }
}

/// The one place that decides how versions compare for each update source. Phase 1 (is an update
/// available?) and the installer (does the download match the offer, and is it strictly newer?) both use it,
/// so they can never disagree: Electron uses SemVer precedence (prereleases sort below the release),
/// Sparkle and Homebrew use Sparkle's comparator on display versions with cosmetic prefixes stripped.
public enum SourceVersioning {
    public static func compareDisplay(_ lhs: String, _ rhs: String, source: UpdateSource) -> ComparisonResult {
        if case .electron = source { return ElectronVersionComparator.compare(lhs, rhs) }
        return VersionComparator.compare(VersionComparator.stripDecoration(lhs), VersionComparator.stripDecoration(rhs))
    }

    /// Some apps (Opera and other Chromium builds) put only major.minor in CFBundleShortVersionString and the
    /// full version in CFBundleVersion: short "139.0", build "139.0.6053.38", while the Homebrew cask publishes
    /// "139.0.6053.38". For Homebrew casks only, judged against the offered version, a bundle's build stands in
    /// for its short version when offer, short and build are all-numeric dotted, the short is a component
    /// prefix of both, and either the build equals the offer, or the offer has at least two more components
    /// than the short and the build has at least as many as the offer. Installed and downloaded bundles go
    /// through the same rule, so detection, matching and the downgrade guard agree. Everything else (App Store,
    /// Electron, Sparkle, build counters, offers one component longer than the short) keeps the short version.
    public static func bundleVersion(short: String?, build: String?, against offered: String, source: UpdateSource) -> String? {
        guard case .homebrewCask = source, let short, let build else { return short }
        guard let s = numericParts(short), let b = numericParts(build), let o = numericParts(offered),
              b.count > s.count, Array(b.prefix(s.count)) == s, o.count >= s.count, Array(o.prefix(s.count)) == s else { return short }
        if b == o { return build }
        guard o.count >= s.count + 2, b.count >= o.count else { return short }
        return build
    }

    /// Canonical all-numeric dotted version: the same decoration stripping the display comparator uses
    /// ("v139.0" -> "139.0"), then leading zeroes removed from each component ("139.00" -> "139.0"), any length.
    /// nil for anything else, so every prefix and equality check agrees with display comparison.
    static func numericParts(_ version: String) -> [Substring]? {
        let stripped = VersionComparator.stripDecoration(version)
        var out: [Substring] = []
        for part in stripped.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let trimmed = part.drop(while: { $0 == "0" })
            out.append(trimmed.isEmpty ? Substring("0") : trimmed)
        }
        return out
    }

    /// Exact ordering of canonical numeric versions: digit strings by length then lexicographically, missing
    /// trailing components count as zero. No integer conversion, so nothing saturates. nil if either is not
    /// a canonical all-numeric dotted version.
    public static func numericCompare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let x = numericParts(a), let y = numericParts(b) else { return nil }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : "0", r = i < y.count ? y[i] : "0"
            if l.count != r.count { return l.count < r.count ? .orderedAscending : .orderedDescending }
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Is the candidate strictly newer than the installed version? Sparkle compares build numbers when both
    /// sides have them; everything else compares display versions (see `bundleVersion` for Homebrew casks).
    /// `offered` is the version the feed advertised; Phase 1 passes nothing because the candidate is the offer.
    public static func isNewer(candidateShort: String, candidateBuild: String?, installedShort: String?,
                               installedBuild: String?, source: UpdateSource, offered: String? = nil) -> Result<Bool, RefusalReason> {
        if case .sparkle = source, let latestBuild = candidateBuild, let installedBuild {
            return .success(VersionComparator.isNewer(latestBuild, than: installedBuild))
        }
        let isSparkle: Bool
        if case .sparkle = source { isSparkle = true } else { isSparkle = false }
        let reference = offered ?? candidateShort
        guard let installed = bundleVersion(short: installedShort, build: installedBuild, against: reference, source: source)
                ?? (isSparkle ? installedBuild : nil) else {
            return .failure(.missingInstalledVersion)
        }
        let candidate = offered == nil ? candidateShort
            : (bundleVersion(short: candidateShort, build: candidateBuild, against: reference, source: source) ?? candidateShort)
        return .success(compareDisplay(candidate, installed, source: source) == .orderedDescending)
    }

    /// True when `version` is all-numeric dotted and strictly extends all-numeric dotted `base`.
    public static func fullOrRefined(_ version: String, of base: String) -> Bool {
        guard let v = numericParts(version), let b = numericParts(base) else { return false }
        return v.count > b.count && Array(v.prefix(b.count)) == b
    }

    /// True when both are all-numeric dotted versions with the same numeric components ("139.00" == "139.0").
    public static func sameNumeric(_ a: String, _ b: String) -> Bool {
        guard let x = numericParts(a), let y = numericParts(b) else { return false }
        return x == y
    }

    /// Does a downloaded bundle's version equal what the offer promised?
    public static func matchesOffer(_ offer: UpdateOffer, short: String?, build: String?) -> Bool {
        let version = bundleVersion(short: short, build: build, against: offer.displayVersion, source: offer.source)
        let promoted = version != nil && version != short
        let shortMatches = promoted
            ? numericCompare(version!, offer.displayVersion) == .orderedSame
            : (version.map { compareDisplay($0, offer.displayVersion, source: offer.source) == .orderedSame } ?? false)
        let buildIsDisplay = offer.buildVersion != nil && offer.buildVersion == offer.displayVersion
        let buildMatchesDisplay = buildIsDisplay && (build.map { compareDisplay($0, offer.displayVersion, source: offer.source) == .orderedSame } ?? false)
        // A promoted build must match the offer exactly; the looser display fallback never overrides that.
        guard promoted ? shortMatches : (shortMatches || buildMatchesDisplay) else { return false }
        // Homebrew split versions ("2.0,2.0.10" -> display 2.0, build 2.0.10): when the cask's build and the
        // bundle's build are both full versions extending the display version, they must be equal.
        if case .homebrewCask = offer.source, let offered = offer.buildVersion,
           fullOrRefined(offered, of: offer.displayVersion), let build, fullOrRefined(build, of: offer.displayVersion),
           numericCompare(build, offered) != .orderedSame {
            return false
        }
        if case .sparkle = offer.source, let offered = offer.buildVersion {
            guard let build, VersionComparator.compare(build, offered) == .orderedSame else { return false }
        }
        return true
    }
}
