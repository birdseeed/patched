import Foundation
import CryptoKit

/// Why the installer would refuse an offer on its Sparkle EdDSA rules, known before any download.
/// Mirrors `SparkleSignature.check` (key format, signature present, signature format); the signature itself is verified at install.
public enum EdSignatureBlock: String, Sendable, Equatable {
    case keyMalformed, signatureMissing, signatureMalformed
    /// Same strings as the installer's `InstallRefusal` codes.
    public var code: String { self == .signatureMissing ? "ed_signature_missing" : "ed_signature_invalid" }
    public var message: String {
        switch self {
        case .keyMalformed: return "This app's update signing key is malformed, so Patched can't verify its updates."
        case .signatureMissing: return "Update found, but it isn't signed the way this app requires. Add a catalogue entry for the app's Sparkle feed to enable updates."
        case .signatureMalformed: return "Update found, but its signature is malformed."
        }
    }
    /// Short form for the CLI summary.
    public var summary: String {
        switch self {
        case .keyMalformed: return "the app's SUPublicEDKey is malformed"
        case .signatureMissing: return "no EdDSA signature; add a catalogue entry for the app's Sparkle feed"
        case .signatureMalformed: return "the EdDSA signature is malformed"
        }
    }
    /// nil when `key` is nil (no requirement) or the offer's signature is acceptable in form.
    public static func evaluate(key: String?, signature: String?) -> EdSignatureBlock? {
        guard let key else { return nil }
        guard let keyBytes = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)), keyBytes.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)) != nil else { return .keyMalformed }
        guard let signature, !signature.isEmpty else { return .signatureMissing }
        guard let bytes = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == 64 else { return .signatureMalformed }
        return nil
    }
}

public struct AppCheckOutcome: Sendable, Equatable {
    public let app: InstalledApp
    public let teamID: String?
    public let source: UpdateSource?
    public let lowConfidence: Bool
    public let installable: Bool
    public let result: CheckResult
    /// Set only when `result` is `.noSource`.
    public let noSourceReason: NoSourceReason?
    /// The App Store listing found for this app when no source was kept (an iPhone/iPad listing whose version was not
    /// compared), so a click can still open that listing. nil otherwise.
    public let appStoreTrackID: Int?

    public init(app: InstalledApp, teamID: String?, source: UpdateSource?, lowConfidence: Bool, installable: Bool,
                result: CheckResult, noSourceReason: NoSourceReason? = nil, appStoreTrackID: Int? = nil) {
        self.appStoreTrackID = appStoreTrackID
        self.app = app; self.teamID = teamID; self.source = source; self.lowConfidence = lowConfidence
        self.installable = installable; self.result = result
        if case .noSource = result { self.noSourceReason = noSourceReason ?? .noPublicFeed } else { self.noSourceReason = nil }
    }

    /// The app is owned by the Mac App Store (it has a receipt), whichever source reported the update: counts as an available update, but Patched never installs it.
    public var isAppStoreUpdate: Bool {
        if case .updateAvailable = result, app.isAppStore { return true }
        return false
    }
    /// `macappstore://apps.apple.com/app/id<trackId>` for App Store rows (up to date or not).
    public var appStoreURL: URL? {
        if case .appStore(let trackID)? = source { return AppStoreLinks.appURL(trackID: trackID) }
        return appStoreTrackID.map(AppStoreLinks.appURL(trackID:))
    }
    /// Set when the installer would refuse this update on the app's pinned `SUPublicEDKey` (malformed key, or an
    /// offer whose signature is missing or malformed). Never set for App Store apps.
    public var edSignatureBlock: EdSignatureBlock? {
        guard case .updateAvailable(let offer) = result, !app.isAppStore else { return nil }
        return EdSignatureBlock.evaluate(key: app.sparklePublicEDKey, signature: offer.edSignature)
    }
    /// The reason an available update is not installed by Patched, when it is the App Store's job. Applies even when a
    /// catalogue entry names another source for a receipt-bearing app: that source is used for the version shown only.
    public var managedByAppStore: RefusalReason? { isAppStoreUpdate ? .appStoreManaged : nil }
}

extension Sequence where Element == AppCheckOutcome {
    /// Updates waiting in the App Store (not installable by Patched). For "N App Store updates" notifications.
    public var appStoreUpdates: [AppCheckOutcome] { filter(\.isAppStoreUpdate) }
}

/// Chooses a source for each installed app, resolves the latest release and compares it with what is installed.
/// Source precedence: user catalogue, Mac App Store receipt, Sparkle `SUFeedURL`, Electron `app-update.yml`,
/// Homebrew cask match (by app filename, then by bundle ID).
public struct UpdateChecker: Sendable {
    private let fetcher: any HTTPFetching
    private let caskIndex: any CaskIndexProviding
    private let catalogue: UserCatalogue
    private let environment: HostEnvironment
    private let teamID: @Sendable (String) -> String?
    private let concurrency: Int
    private let storeCountry: String

    public init(fetcher: any HTTPFetching, caskIndex: any CaskIndexProviding, catalogue: UserCatalogue = .empty,
                environment: HostEnvironment = .current,
                teamID: @escaping @Sendable (String) -> String? = { CodeSigningIdentity.teamID(ofBundleAt: URL(fileURLWithPath: $0)) },
                concurrency: Int = FetchLimits.concurrency, storeCountry: String? = nil) {
        self.fetcher = fetcher; self.caskIndex = caskIndex; self.catalogue = catalogue
        self.environment = environment; self.teamID = teamID; self.concurrency = max(1, concurrency)
        self.storeCountry = storeCountry ?? AppStoreResolver.country()
    }

    private enum Decision { case source(UpdateSource, lowConfidence: Bool = false), none(NoSourceReason?), refused(RefusalReason) }

    private func catalogueOverrides(_ app: InstalledApp) -> Bool {
        if let id = app.bundleID, case .source? = catalogue.entries[id] { return true }
        return false
    }

    private func isIgnored(_ app: InstalledApp) -> Bool {
        if let id = app.bundleID, catalogue.entries[id] == .ignore { return true }
        return false
    }

    /// Results are in input order. Apps ignored by the catalogue are omitted, unless `includeIgnored` is set: then each
    /// comes back as a `.noSource` outcome with reason `.ignored`, still without any lookup or request.
    public func check(_ apps: [InstalledApp], includeIgnored: Bool = false) async -> [AppCheckOutcome] {
        let work = includeIgnored ? apps : apps.filter { !isIgnored($0) }
        let siblings = Set(work.compactMap(\.bundleID))
        // One batched lookup for every App Store app (bundle IDs go to Apple only).
        let storeIDs = work.filter { $0.isAppStore && !catalogueOverrides($0) && !isIgnored($0) }.compactMap(\.bundleID)
        let store: Result<AppStoreLookup, RefusalReason>? = storeIDs.isEmpty ? nil
            : await AppStoreResolver.lookup(bundleIDs: storeIDs, country: storeCountry, fetcher: fetcher)
        var results = [AppCheckOutcome?](repeating: nil, count: work.count)
        await withTaskGroup(of: (Int, AppCheckOutcome).self) { group in
            var next = 0
            func launch() {
                guard next < work.count else { return }
                let index = next, app = work[index]
                next += 1
                group.addTask { (index, await self.checkOne(app, siblings: siblings, store: store, trace: nil)) }
            }
            for _ in 0..<min(concurrency, work.count) { launch() }
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                launch()
            }
        }
        return results.compactMap { $0 }
    }

    public func checkOne(_ app: InstalledApp) async -> AppCheckOutcome {
        await checkOne(app, siblings: [], store: nil, trace: nil)
    }

    /// Checks one app and returns the reasoning as text lines: every source considered and why it was or was not chosen.
    public func explain(_ app: InstalledApp, installedBundleIDs: Set<String> = []) async -> (AppCheckOutcome, [String]) {
        let trace = ExplainTrace()
        let outcome = await checkOne(app, siblings: installedBundleIDs, store: nil, trace: trace)
        trace.add("result: \(Self.summary(outcome))")
        return (outcome, trace.lines)
    }

    static func summary(_ outcome: AppCheckOutcome) -> String {
        switch outcome.result {
        case .upToDate: return "up to date via \(outcome.source?.kind ?? "?")"
        case .updateAvailable(let offer): return "update available (\(offer.displayVersion)) via \(outcome.source?.kind ?? "?")" + (outcome.edSignatureBlock.map { ", not installable by Patched (\($0.summary))" } ?? (outcome.installable ? "" : ", not installable by Patched"))
        case .noSource: return "no source (\(outcome.noSourceReason?.text ?? ""))"
        case .refused(let reason): return "refused: \(reason.message)"
        }
    }

    private func checkOne(_ app: InstalledApp, siblings: Set<String>, store: Result<AppStoreLookup, RefusalReason>?,
                          trace: ExplainTrace?) async -> AppCheckOutcome {
        // The catalogue's ignore comes before any network request, including the App Store lookup.
        if let id = app.bundleID, catalogue.entries[id] == .ignore {
            trace?.add("catalogue: \(id) is ignored; nothing is looked up or fetched")
            return AppCheckOutcome(app: app, teamID: nil, source: nil, lowConfidence: false, installable: false,
                                   result: .noSource, noSourceReason: .ignored)
        }
        let team = teamID(app.path)
        func make(_ source: UpdateSource?, _ result: CheckResult, low: Bool = false, installable: Bool? = nil,
                  noSource: NoSourceReason? = nil, trackID: Int? = nil) -> AppCheckOutcome {
            // Receipt-bearing apps belong to the App Store, whatever a catalogue override selected.
            let canInstall = app.isAppStore ? false : (installable ?? { if case .updateAvailable = result { return !low }; return false }())
            return AppCheckOutcome(app: app, teamID: team, source: source, lowConfidence: low, installable: canInstall,
                                   result: result, noSourceReason: noSource, appStoreTrackID: trackID)
        }
        if app.isAppStore, !catalogueOverrides(app) {
            return await checkAppStore(app, store: store, trace: trace, make: make)
        }
        let decision = await decide(app, siblings: siblings, trace: trace)
        let lowConfidence: Bool
        if case .source(_, let low) = decision { lowConfidence = low } else { lowConfidence = false }
        switch decision {
        case .none(let reason): return make(nil, .noSource, noSource: reason)
        case .refused(let reason): return make(nil, .refused(reason))
        case .source(let source, _):
            let resolved: Result<UpdateOffer, RefusalReason>
            switch source {
            case .sparkle(let feed): resolved = await SparkleResolver.resolve(feed: feed, fetcher: fetcher, environment: environment, installedBuild: app.build, installedShortVersion: app.shortVersion)
            case .electron(let feed): resolved = await ElectronResolver.resolve(feed: feed, fetcher: fetcher, environment: environment)
            case .homebrewCask(let token): resolved = await HomebrewResolver.resolve(token: token, fetcher: fetcher, environment: environment)
            case .appStore(let trackID):
                // Only reachable through a hand-written catalogue source; it cannot name a track ID, so refuse.
                resolved = .failure(.invalidSource("App Store source id\(trackID) cannot be set by catalogue"))
            }
            switch resolved {
            case .failure(let reason): return make(source, .refused(reason), low: lowConfidence)
            case .success(let offer):
                switch Self.isNewer(offer, than: app) {
                case .failure(let reason): return make(source, .refused(reason), low: lowConfidence)
                case .success(true):
                    if !app.isAppStore, let block = EdSignatureBlock.evaluate(key: app.sparklePublicEDKey, signature: offer.edSignature) {
                        switch block {
                        case .keyMalformed: trace?.add("EdDSA: the app's SUPublicEDKey is malformed; not installable (\(block.code))")
                        case .signatureMissing: trace?.add("EdDSA: the app pins SUPublicEDKey but the \(source.kind) offer has no EdDSA signature; not installable (add a catalogue entry for the app's Sparkle feed)")
                        case .signatureMalformed: trace?.add("EdDSA: the \(source.kind) offer's EdDSA signature is not 64 base64 bytes; not installable (\(block.code))")
                        }
                        return make(source, .updateAvailable(offer), low: lowConfidence, installable: false)
                    }
                    return make(source, .updateAvailable(offer), low: lowConfidence)
                case .success(false): return make(source, .upToDate, low: lowConfidence)
                }
            }
        }
    }

    private func checkAppStore(_ app: InstalledApp, store: Result<AppStoreLookup, RefusalReason>?, trace: ExplainTrace?,
                               make: (UpdateSource?, CheckResult, Bool, Bool?, NoSourceReason?, Int?) -> AppCheckOutcome) async -> AppCheckOutcome {
        trace?.add("catalogue: no source entry for this app")
        trace?.add(app.isWrappedIOSApp
            ? "Mac App Store: wrapped iPhone/iPad app (Wrapper/iTunesMetadata.plist), so the App Store owns updates (Sparkle, Electron and Homebrew are not consulted)"
            : "Mac App Store: Contents/_MASReceipt present, so the App Store owns updates (Sparkle, Electron and Homebrew are not consulted)")
        guard let bundleID = app.bundleID else {
            trace?.add("App Store lookup skipped: the app has no bundle ID")
            return make(nil, .noSource, false, nil, .noPublicFeed, nil)
        }
        guard AppStoreResolver.isLookupSafe(bundleID) else {
            trace?.add("App Store lookup skipped: the bundle ID is not a plain dotted identifier")
            return make(nil, .refused(.invalidSource("bundle ID is not a plain dotted identifier")), false, nil, nil, nil)
        }
        let lookup: Result<AppStoreLookup, RefusalReason>
        if let store { lookup = store } else {
            lookup = await AppStoreResolver.lookup(bundleIDs: [bundleID], country: storeCountry, fetcher: fetcher)
        }
        switch lookup {
        case .failure(let reason):
            trace?.add("App Store lookup (\(storeCountry)) failed: \(reason.message)")
            return make(nil, .refused(reason), false, nil, nil, nil)
        case .success(let found):
            if found.conflicts.contains(bundleID.lowercased()) {
                trace?.add("App Store lookup (\(storeCountry)): conflicting listings for \(bundleID)")
                return make(nil, .refused(.lookupConflict(bundleID)), false, nil, nil, nil)
            }
            guard let record = found.records[bundleID.lowercased()] else {
                trace?.add("App Store lookup (\(storeCountry)): \(bundleID) is not listed")
                return make(nil, .noSource, false, nil, .appStoreNotListed, nil)
            }
            let source = UpdateSource.appStore(trackID: record.trackID)
            trace?.add("App Store lookup (\(storeCountry)): id\(record.trackID) version \(record.version)")
            let offer = UpdateOffer(displayVersion: record.version, downloadURL: record.trackViewURL,
                                    minimumSystemVersion: record.minimumOSVersion, format: .unknown, source: source)
            if !record.isMacListing && !app.isWrappedIOSApp {
                // An iPhone/iPad listing for a Mac app: only an exact version match shows the Mac app is current. Anything
                // else is left to the App Store rather than guessed from another platform's numbering. The listing's
                // track ID is kept, so a click can still open it.
                let installed = app.shortVersion ?? app.build
                if let installed, installed == record.version {
                    trace?.add("App Store lookup: iPhone/iPad listing matches the installed version")
                    return make(source, .upToDate, false, nil, nil, nil)
                }
                trace?.add("App Store lookup: iPhone/iPad listing version \(record.version) may not be the Mac version; not compared")
                return make(nil, .noSource, false, nil, .appStoreNotListed, record.trackID)
            }
            if !record.isMacListing {
                trace?.add("App Store lookup: wrapped iPhone/iPad app, so its installed version is the iOS version and is compared as usual")
            }
            switch Self.isNewer(offer, than: app) {
            case .failure(let reason): return make(source, .refused(reason), false, nil, nil, nil)
            case .success(true): return make(source, .updateAvailable(offer), false, false, nil, nil)
            case .success(false): return make(source, .upToDate, false, nil, nil, nil)
            }
        }
    }

    private func decide(_ app: InstalledApp, siblings: Set<String>, trace: ExplainTrace?) async -> Decision {
        if let id = app.bundleID, let entry = catalogue.entries[id] {
            if case .source(let source) = entry {
                trace?.add("catalogue: entry for \(id) -> \(source.kind) \(source.locator)")
                switch source {
                case .sparkle(let feed), .electron(let feed):
                    return feed.isHTTPS ? .source(source) : .refused(.insecureFeed(feed.absoluteString))
                case .homebrewCask, .appStore: return .source(source)
                }
            }
        } else { trace?.add("catalogue: no entry") }
        if let feed = app.sparkleFeed {
            trace?.add("Sparkle: SUFeedURL \(feed)")
            guard let url = URL(string: feed) else { return .refused(.malformedFeed("SUFeedURL is not a URL")) }
            return url.isHTTPS ? .source(.sparkle(feed: url)) : .refused(.insecureFeed(feed))
        }
        trace?.add("Sparkle: no SUFeedURL")
        if app.sparkleFeedRejected { return .refused(.insecureFeed("SUFeedURL is present but is not a plain https URL")) }
        if let config = app.electronConfig, let feed = ElectronResolver.feedURL(fromAppUpdateYML: config) {
            trace?.add("Electron: app-update.yml feed \(feed.absoluteString)")
            return .source(.electron(feed: feed))
        }
        trace?.add("Electron: no usable app-update.yml")
        let none = Decision.none(app.bundleID == NoSourceReason.patchedBundleID ? .thisApp : .noPublicFeed)
        switch await caskIndex.index() {
        case .success(let index):
            if let match = index.match(for: app, installedBundleIDs: siblings, trace: trace) {
                return .source(.homebrewCask(token: match.token), lowConfidence: match.lowConfidence)
            }
            return none
        case .failure(let reason):
            trace?.add("Homebrew: cask index unavailable (\(reason.message))")
            // The index being unreachable must not turn "no other source" into a hard failure for every app.
            return none
        }
    }

    /// Sparkle compares build numbers when both sides have them; everything else compares display versions.
    static func isNewer(_ offer: UpdateOffer, than app: InstalledApp) -> Result<Bool, RefusalReason> {
        SourceVersioning.isNewer(candidateShort: offer.displayVersion, candidateBuild: offer.buildVersion,
                                 installedShort: app.shortVersion, installedBuild: app.build, source: offer.source)
    }

}

/// One row of `patched check` output, with a stable JSON shape (all keys always present).
public struct CheckReportRow: Encodable, Sendable, Equatable {
    public let name, path: String
    public let bundleID, installedVersion, installedBuild, teamID: String?
    public let sourceKind, sourceLocator: String?
    public let status: String            // up_to_date | update_available | no_source | refused
    public let reason, reasonDetail: String?
    public let latestVersion, latestBuild, downloadURL, format, sha256, sha512, edSignature, minimumSystemVersion, minimumKernelVersion: String?
    public let length: Int?
    public let lowConfidence: Bool
    public let installable: Bool
    /// Why there is no source (`no_public_feed`, `this_app`, `app_store_not_listed`); null unless status is `no_source`.
    public let noSourceReason: String?
    /// `macappstore://apps.apple.com/app/id<trackId>` for App Store apps; null otherwise.
    public let appStoreURL: String?

    public init(_ outcome: AppCheckOutcome) {
        lowConfidence = outcome.lowConfidence; installable = outcome.installable
        noSourceReason = outcome.noSourceReason?.rawValue; appStoreURL = outcome.appStoreURL?.absoluteString
        let app = outcome.app
        name = app.name; path = app.path; bundleID = app.bundleID
        installedVersion = app.shortVersion; installedBuild = app.build; teamID = outcome.teamID
        sourceKind = outcome.source?.kind; sourceLocator = outcome.source?.locator
        var offer: UpdateOffer?
        switch outcome.result {
        case .upToDate: status = "up_to_date"; reason = nil; reasonDetail = nil
        case .updateAvailable(let o):
            status = "update_available"; offer = o
            // An App Store update is real but not Patched's to install: say so with a stable code.
            reason = outcome.managedByAppStore?.code ?? outcome.edSignatureBlock?.code
            reasonDetail = outcome.managedByAppStore?.message ?? outcome.edSignatureBlock?.message
        case .noSource: status = "no_source"; reason = nil; reasonDetail = nil
        case .refused(let r): status = "refused"; reason = r.code; reasonDetail = r.message
        }
        latestVersion = offer?.displayVersion; latestBuild = offer?.buildVersion
        downloadURL = offer?.downloadURL.absoluteString; format = offer?.format.rawValue
        sha256 = offer?.sha256; sha512 = offer?.sha512; edSignature = offer?.edSignature
        minimumSystemVersion = offer?.minimumSystemVersion; minimumKernelVersion = offer?.minimumKernelVersion; length = offer?.length
    }

    enum CodingKeys: String, CodingKey {
        case name, path, bundleID, installedVersion, installedBuild, teamID, sourceKind, sourceLocator, status
        case reason, reasonDetail, latestVersion, latestBuild, downloadURL, format, sha256, sha512, edSignature
        case minimumSystemVersion, minimumKernelVersion, length, lowConfidence, installable, noSourceReason, appStoreURL
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lowConfidence, forKey: .lowConfidence)
        try c.encode(installable, forKey: .installable)
        try c.encode(noSourceReason, forKey: .noSourceReason); try c.encode(appStoreURL, forKey: .appStoreURL)
        try c.encode(minimumKernelVersion, forKey: .minimumKernelVersion)
        try c.encode(name, forKey: .name); try c.encode(path, forKey: .path)
        try c.encode(bundleID, forKey: .bundleID); try c.encode(installedVersion, forKey: .installedVersion)
        try c.encode(installedBuild, forKey: .installedBuild); try c.encode(teamID, forKey: .teamID)
        try c.encode(sourceKind, forKey: .sourceKind); try c.encode(sourceLocator, forKey: .sourceLocator)
        try c.encode(status, forKey: .status); try c.encode(reason, forKey: .reason)
        try c.encode(reasonDetail, forKey: .reasonDetail); try c.encode(latestVersion, forKey: .latestVersion)
        try c.encode(latestBuild, forKey: .latestBuild); try c.encode(downloadURL, forKey: .downloadURL)
        try c.encode(format, forKey: .format); try c.encode(sha256, forKey: .sha256)
        try c.encode(sha512, forKey: .sha512); try c.encode(edSignature, forKey: .edSignature)
        try c.encode(minimumSystemVersion, forKey: .minimumSystemVersion); try c.encode(length, forKey: .length)
    }

    public static func json(_ outcomes: [AppCheckOutcome]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(outcomes.map(CheckReportRow.init))
    }
}
