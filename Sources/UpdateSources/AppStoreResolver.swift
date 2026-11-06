import Foundation

/// Bundle IDs are dotted ASCII identifiers; matched against the whole string.
enum BundleIDSyntax {
    private static let pattern = "[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+"
    static func isValid(_ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
}

/// Records found for the requested bundle IDs, and bundle IDs for which Apple gave conflicting listings.
public struct AppStoreLookup: Sendable, Equatable {
    public var records: [String: AppStoreRecord] = [:]
    public var conflicts: Set<String> = []
}

/// What Apple's public lookup API says about one Mac App Store app.
public struct AppStoreRecord: Sendable, Equatable {
    public let bundleID: String
    public let trackID: Int
    public let version: String
    public let trackViewURL: URL
    public let minimumOSVersion: String?
    /// False for an iPhone/iPad listing (kind "software"). Its version may follow the iOS numbering rather than
    /// the Mac app's, so it is never used to claim an update; it only confirms "up to date" on an exact match.
    public var isMacListing: Bool = true
}

/// Latest-version lookup through `https://itunes.apple.com/lookup`. Only bundle IDs of App Store apps are sent,
/// and only to Apple. Responses are parsed strictly and size-capped.
public enum AppStoreResolver {
    public static let lookupBase = "https://itunes.apple.com/lookup"
    public static let maxBatch = 50
    public static let fallbackCountry = "us"
    public static let maxResponseBytes = 8 * 1024 * 1024

    /// Two-letter lower-case storefront code from a locale's region; "us" when unknown.
    public static func country(for locale: Locale = .current) -> String {
        let code = locale.region?.identifier.lowercased() ?? ""
        guard code.range(of: "^[a-z]{2}$", options: .regularExpression) != nil else { return "us" }
        // The Isle of Man, Jersey and Guernsey have no storefront of their own; their Apple accounts use the UK store.
        return storefrontParents[code] ?? code
    }
    static let storefrontParents = ["im": "gb", "je": "gb", "gg": "gb"]

    /// Whole-string match: `$` would also accept a trailing line separator such as U+2028.
    static func isLookupSafe(_ bundleID: String) -> Bool {
        bundleID.utf8.count <= 155 && BundleIDSyntax.isValid(bundleID)
    }

    public static func lookupURL(bundleIDs: [String], country: String) -> URL? {
        let ids = bundleIDs.filter(isLookupSafe)
        guard !ids.isEmpty, country.range(of: "^[a-z]{2}$", options: .regularExpression) != nil else { return nil }
        var components = URLComponents(string: lookupBase)
        // Ordinary query items: Foundation does the encoding. Commas stay literal in a query, which the API's list needs.
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: ids.joined(separator: ",")),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "macSoftware"),
        ]
        return components?.url
    }

    /// Looks up bundle IDs (batched), returning records keyed by lower-cased bundle ID. An ID Apple does not list
    /// is simply absent. Any transport or parse failure fails the whole batch it was in.
    public static func lookup(bundleIDs: [String], country: String, fetcher: any HTTPFetching) async -> Result<AppStoreLookup, RefusalReason> {
        var found = AppStoreLookup()
        let unique = Array(Set(bundleIDs.filter(isLookupSafe))).sorted()
        var index = 0
        while index < unique.count {
            let batch = Array(unique[index..<min(index + maxBatch, unique.count)])
            index += maxBatch
            guard let url = lookupURL(bundleIDs: batch, country: country) else { return .failure(.invalidSource("App Store lookup URL")) }
            guard url.isHTTPS else { return .failure(.insecureFeed(url.absoluteString)) }
            var data: Data
            do { data = try await fetcher.fetch(url, maxBytes: maxResponseBytes) }
            catch FetchError.http(400) where country != fallbackCountry {
                // Not every locale region is an App Store storefront (for example en_IM): retry once with "us".
                guard let retry = lookupURL(bundleIDs: batch, country: fallbackCountry) else { return .failure(.invalidSource("App Store lookup URL")) }
                do { data = try await fetcher.fetch(retry, maxBytes: maxResponseBytes) }
                catch let error as FetchError { return .failure(error.refusal) }
                catch { return .failure(.network(error.localizedDescription)) }
            }
            catch let error as FetchError { return .failure(error.refusal) }
            catch { return .failure(.network(error.localizedDescription)) }
            switch parse(data, requested: batch) {
            case .failure(let reason): return .failure(reason)
            case .success(let part):
                found.records.merge(part.records) { first, _ in first }
                found.conflicts.formUnion(part.conflicts)
            }
        }
        return .success(found)
    }

    /// Strict parse. Results for bundle IDs that were not requested, non-Mac listings, and records with a missing or
    /// malformed field are ignored; a response that is not the documented envelope fails.
    public static func parse(_ data: Data, requested: [String]) -> Result<AppStoreLookup, RefusalReason> {
        guard data.count <= maxResponseBytes else { return .failure(.tooLarge) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [Any] else { return .failure(.malformedFeed("App Store lookup JSON")) }
        let wanted = Set(requested.map { $0.lowercased() })
        var lookup = AppStoreLookup()
        // Some Mac App Store apps are iPhone and iPad apps (or Mac Catalyst apps sold with them) and are listed as
        // kind "software" rather than "mac-software", WhatsApp for one. Their exact bundle ID was installed from the
        // Mac App Store, so that listing is the one it updates from. A "mac-software" listing still wins if both
        // exist. Patched only reports these and opens the App Store; it never installs them.
        let macIDs = Set(results.compactMap { item -> String? in
            guard let item = item as? [String: Any], item["kind"] as? String == "mac-software" else { return nil }
            return (item["bundleId"] as? String)?.lowercased()
        })
        for case let item as [String: Any] in results {
            let kind = item["kind"] as? String
            guard kind == "mac-software" || (kind == "software" && !macIDs.contains(((item["bundleId"] as? String) ?? "").lowercased())),
                  let bundleID = item["bundleId"] as? String, wanted.contains(bundleID.lowercased()),
                  let trackID = exactPositiveInteger(item["trackId"]),
                  let version = item["version"] as? String, !version.isEmpty, version.count <= 64,
                  version.rangeOfCharacter(from: .decimalDigits) != nil,
                  let viewString = item["trackViewUrl"] as? String, let view = URL(string: viewString), view.isHTTPS else { continue }
            let key = bundleID.lowercased()
            var record = AppStoreRecord(bundleID: bundleID, trackID: trackID, version: version, trackViewURL: view,
                                        minimumOSVersion: item["minimumOsVersion"] as? String)
            record.isMacListing = kind == "mac-software"
            // Identical duplicates are one listing; differing ones make the app's status order-dependent, so refuse it.
            if lookup.conflicts.contains(key) { continue }
            if let existing = lookup.records[key], existing != record {
                lookup.records[key] = nil; lookup.conflicts.insert(key); continue
            }
            lookup.records[key] = record
        }
        return .success(lookup)
    }

    /// A JSON integer that is positive and exactly representable; fractional, negative, boolean and huge values are not.
    static func exactPositiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber) else { return nil }
        let int = number.int64Value
        guard int > 0, int <= 9_007_199_254_740_991, NSNumber(value: int) == number else { return nil }
        return Int(int)
    }
}
