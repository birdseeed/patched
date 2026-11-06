import Foundation
@_spi(Testing) import UpdateSources

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) throws {
    if !(try condition()) { throw CheckFailure(description: "\(message) (main.swift:\(line))") }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", line: Int = #line) throws {
    if a != b { throw CheckFailure(description: "\(message) expected \(b), got \(a) (line \(line))") }
}

nonisolated(unsafe) var cases: [(String, () async throws -> Void)] = []
func check(_ name: String, _ action: @escaping () async throws -> Void) { cases.append((name, action)) }

// MARK: Helpers

let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/UpdateSources")
func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtureRoot.appendingPathComponent(name)) }

let testTemporaryDirectory = fixtureRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/update-sources-checks-tmp", isDirectory: true)
try FileManager.default.createDirectory(at: testTemporaryDirectory, withIntermediateDirectories: true)

let arm = HostEnvironment(arch: .arm64, osVersion: "15.1")
let intel = HostEnvironment(arch: .x86_64, osVersion: "15.1")
let feed = URL(string: "https://updates.example.test/appcast.xml")!

final class FakeFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: Result<Data, FetchError>]
    private var requested: [String] = []
    private var caps: [Int] = []
    init(_ responses: [String: Result<Data, FetchError>] = [:]) { self.responses = responses }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return requested }
    /// The `maxBytes` of each request, in order.
    var maxBytesSeen: [Int] { lock.lock(); defer { lock.unlock() }; return caps }
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        let r = lock.withLock { () -> Result<Data, FetchError>? in requested.append(url.absoluteString); caps.append(maxBytes); return responses[url.absoluteString] }
        guard let r else { throw FetchError.http(404) }
        return try r.get()
    }
}

func sparkleOffer(_ result: Result<UpdateOffer, RefusalReason>) throws -> UpdateOffer {
    switch result { case .success(let o): return o; case .failure(let r): throw CheckFailure(description: "refused: \(r.message)") }
}
func refusal(_ result: Result<UpdateOffer, RefusalReason>) throws -> RefusalReason {
    switch result { case .success(let o): throw CheckFailure(description: "expected refusal, got \(o)"); case .failure(let r): return r }
}

// MARK: Version comparator

check("version comparator table") {
    let table: [(String, String, ComparisonResult)] = [
        ("1.0", "1.0", .orderedSame), ("1.0", "1.0.1", .orderedAscending), ("1.0.1", "1.0", .orderedDescending),
        ("1.0b1", "1.0", .orderedAscending), ("1.0", "1.0b1", .orderedDescending),
        ("1.0rc1", "1.0rc2", .orderedAscending), ("1.0a", "1.0b", .orderedAscending),
        ("1.0 beta", "1.0", .orderedDescending), ("1.0.0-beta", "1.0.0", .orderedSame),
        ("1.0.0", "1.0", .orderedSame), ("1.0", "1.0.0.0", .orderedSame), ("007", "7", .orderedSame),
        ("1.9", "1.10", .orderedAscending), ("2", "10", .orderedAscending), ("10.0.1", "9.9.9", .orderedDescending),
        ("1.2.3", "1.2.3.4", .orderedAscending), ("1.1", "1.0.5", .orderedDescending),
        ("26.1029.70936", "26.1027.61615", .orderedDescending), ("1.0-1", "1.0-2", .orderedSame),
        ("1", "a", .orderedDescending), ("100000000000000000000", "99999999999999999999", .orderedSame),
        ("4215", "4216", .orderedAscending), ("", "", .orderedSame), ("1.0", "", .orderedDescending),
    ]
    for (a, b, expected) in table {
        try expectEqual(VersionComparator.compare(a, b), expected, "compare(\(a), \(b))")
        let flipped: ComparisonResult = expected == .orderedAscending ? .orderedDescending : expected == .orderedDescending ? .orderedAscending : .orderedSame
        try expectEqual(VersionComparator.compare(b, a), flipped, "compare(\(b), \(a)) (reverse)")
    }
}

check("version decoration is stripped for display-version comparison") {
    try expectEqual(VersionComparator.stripDecoration("Build 4215"), "4215")
    try expectEqual(VersionComparator.stripDecoration("v1.2.3"), "1.2.3")
    try expectEqual(VersionComparator.stripDecoration("Version 3"), "3")
    try expectEqual(VersionComparator.stripDecoration("1.0b1"), "1.0b1")
    try expectEqual(VersionComparator.stripDecoration("beta"), "beta")
    let checker = try await makeChecker(try fakeWorld())
    // cask-nocheck-comma.json is version 1.2.3; "Build"-style installed strings must not look older than a bare number.
    try expectEqual(await checker.checkOne(app("Example", short: "v1.2.3", build: "1")).result, .upToDate)
}

// MARK: Sparkle

check("sparkle realistic appcast picks highest compatible full update") {
    let offer = try sparkleOffer(SparkleResolver.parse(try fixture("appcast-realistic.xml"), feed: feed, environment: arm))
    try expectEqual(offer.displayVersion, "2.5"); try expectEqual(offer.buildVersion, "250")
    try expectEqual(offer.downloadURL.absoluteString, "https://updates.example.test/Example-2.5.dmg")
    try expectEqual(offer.edSignature, "ED2500SIG=="); try expectEqual(offer.length, 2500)
    try expectEqual(offer.format, .dmg); try expectEqual(offer.source, .sparkle(feed: feed))
}
check("sparkle skips beta channel, deltas, other OS and too-new minimumSystemVersion") {
    // Drop the 2.5 item's winner status by lowering the host OS below its requirement does not apply (12.0); instead
    // verify each skipped item individually through the OS gate and the absence of builds 300/400/500/999.
    let data = try fixture("appcast-realistic.xml")
    let offer = try sparkleOffer(SparkleResolver.parse(data, feed: feed, environment: arm))
    try expect(!["300", "400", "500", "999"].contains(offer.buildVersion ?? ""), "picked a skipped item")
    let old = HostEnvironment(arch: .arm64, osVersion: "11.0")   // 2.0/2.5 need 12.0 / none; 2.2 has none
    let oldOffer = try sparkleOffer(SparkleResolver.parse(data, feed: feed, environment: old))
    try expectEqual(oldOffer.buildVersion, "250", "2.5 has no minimum so it stays selectable on 11.0")
    let future = HostEnvironment(arch: .arm64, osVersion: "99.1")
    try expectEqual(try sparkleOffer(SparkleResolver.parse(data, feed: feed, environment: future)).buildVersion, "400",
                    "build 400 becomes eligible on macOS 99.1, proving the minimum gate is what excluded it")
}
check("sparkle element-form versions and relative enclosure URLs") {
    let offer = try sparkleOffer(SparkleResolver.parse(try fixture("appcast-element-form.xml"), feed: feed, environment: arm))
    try expectEqual(offer.buildVersion, "12"); try expectEqual(offer.displayVersion, "1.2")
    try expectEqual(offer.edSignature, "ELEMENTSIG=="); try expectEqual(offer.minimumSystemVersion, "11.0")
    try expectEqual(offer.downloadURL.absoluteString, "https://updates.example.test/Newer-1.2.zip")
    try expectEqual(offer.format, .zip)
}
check("sparkle XXE: external entity is not expanded or fetched") {
    let dir = testTemporaryDirectory.appendingPathComponent("uscheck-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let canary = dir.appendingPathComponent("canary.txt")
    try "CANARY-SECRET-9f31".write(to: canary, atomically: true, encoding: .utf8)
    let xml = """
    <?xml version="1.0"?>
    <!DOCTYPE rss [<!ENTITY xxe SYSTEM "\(canary.absoluteString)">]>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>&xxe;</sparkle:version><sparkle:shortVersionString>&xxe;</sparkle:shortVersionString>
    <enclosure url="https://updates.example.test/x.zip" length="1" type="application/zip"/></item></channel></rss>
    """
    let xxeResult = SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm)
    // An entity-free DOCTYPE is still harmless and must keep parsing.
    let plain = """
    <?xml version="1.0"?><!DOCTYPE rss><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <enclosure url="https://updates.example.test/x.zip" sparkle:version="7" length="1" type="application/zip"/></item></channel></rss>
    """
    try expectEqual(try sparkleOffer(SparkleResolver.parse(Data(plain.utf8), feed: feed, environment: arm)).buildVersion, "7")
    switch xxeResult {
    case .success(let offer):
        try expect(!offer.displayVersion.contains("CANARY") && !(offer.buildVersion ?? "").contains("CANARY"), "entity expanded: \(offer)")
    case .failure(let reason):
        try expectEqual(reason.code, "malformed_feed", "entity declarations must be refused as malformed")
        try expect(reason.message.contains("entity"), "unexpected refusal: \(reason.message)")
        try expect(!reason.message.contains("CANARY"), "entity expanded in error")
        try expect(!reason.message.contains("external entity"), "parser asked to resolve an external entity: \(reason.message)")
    }
}
check("sparkle malformed XML is refused") {
    let reason = try refusal(SparkleResolver.parse(try fixture("appcast-malformed.xml"), feed: feed, environment: arm))
    try expectEqual(reason.code, "malformed_feed")
    try expectEqual(try refusal(SparkleResolver.parse(Data("not xml at all".utf8), feed: feed, environment: arm)).code, "malformed_feed")
    try expectEqual(try refusal(SparkleResolver.parse(Data("<html><body/></html>".utf8), feed: feed, environment: arm)).code, "malformed_feed")
}
check("sparkle http download URL is not offered") {
    let reason = try refusal(SparkleResolver.parse(try fixture("appcast-insecure-download.xml"), feed: feed, environment: arm))
    try expectEqual(reason.code, "insecure_download")
}
check("sparkle oversized feed is refused") {
    let big = FakeFetcher([feed.absoluteString: .failure(.tooLarge)])
    try expectEqual(try refusal(await SparkleResolver.resolve(feed: feed, fetcher: big, environment: arm)), .tooLarge)
    let huge = FakeFetcher([feed.absoluteString: .success(Data(count: FetchLimits.feedBytes + 1))])
    try expectEqual(try refusal(await SparkleResolver.resolve(feed: feed, fetcher: huge, environment: arm)), .tooLarge)
}
check("sparkle http feed refused without fetching") {
    let fetcher = FakeFetcher()
    let reason = try refusal(await SparkleResolver.resolve(feed: URL(string: "http://updates.example.test/a.xml")!, fetcher: fetcher, environment: arm))
    try expectEqual(reason.code, "insecure_feed"); try expect(fetcher.requests.isEmpty, "fetched an http URL")
    let e = try refusal(await ElectronResolver.resolve(feed: URL(string: "http://x.test/latest-mac.yml")!, fetcher: fetcher, environment: arm))
    try expectEqual(e.code, "insecure_feed"); try expect(fetcher.requests.isEmpty, "fetched an http URL")
}
check("fetcher refuses http and redirects away from https") {
    do { _ = try await URLSessionFetcher().fetch(URL(string: "http://example.invalid/a")!, maxBytes: 10); throw CheckFailure(description: "fetched http") }
    catch let error as FetchError { try expectEqual(error.refusal.code, "insecure_feed") }
    try expect(HTTPSRedirectPolicy.decide(URLRequest(url: URL(string: "http://evil.test/x")!)) == nil, "http redirect allowed")
    try expect(HTTPSRedirectPolicy.decide(URLRequest(url: URL(string: "ftp://evil.test/x")!)) == nil, "ftp redirect allowed")
    try expect(HTTPSRedirectPolicy.decide(URLRequest(url: URL(string: "https://ok.test/x")!)) != nil, "https redirect refused")
    try expectEqual(FetchError.insecureRedirect("http://evil.test").refusal.code, "insecure_redirect")
}

// MARK: Electron

check("latest-mac.yml files list: arm64 host prefers arm64 zip, resolves relative URL") {
    let feed = URL(string: "https://updates.example.test/app/latest-mac.yml")!
    let offer = try sparkleOffer(ElectronResolver.parse(try fixture("latest-mac-files.yml"), feed: feed, environment: arm))
    try expectEqual(offer.displayVersion, "3.1.4")
    try expectEqual(offer.downloadURL.absoluteString, "https://updates.example.test/app/Example-3.1.4-arm64-mac.zip")
    try expectEqual(offer.sha512, "ARMSHA512=="); try expectEqual(offer.length, 222); try expectEqual(offer.format, .zip)
    try expectEqual(offer.source, .electron(feed: feed))
}
check("latest-mac.yml files list: intel host takes the unmarked zip, never arm64") {
    let feed = URL(string: "https://updates.example.test/app/latest-mac.yml")!
    let offer = try sparkleOffer(ElectronResolver.parse(try fixture("latest-mac-files.yml"), feed: feed, environment: intel))
    try expectEqual(offer.downloadURL.lastPathComponent, "Example-3.1.4-mac.zip"); try expectEqual(offer.sha512, "X64SHA512==")
    let onlyIntel = try sparkleOffer(ElectronResolver.parse(try fixture("latest-mac-intel-only.yml"), feed: feed, environment: intel))
    try expectEqual(onlyIntel.downloadURL.lastPathComponent, "App-0.9.0-x64.zip")
    try expectEqual(try refusal(ElectronResolver.parse(try fixture("latest-mac-intel-only.yml"), feed: feed, environment: arm)).code, "no_compatible_item")
}
check("latest-mac.yml legacy path/sha512 form and spaces in file name") {
    let feed = URL(string: "https://updates.example.test/latest-mac.yml")!
    let offer = try sparkleOffer(ElectronResolver.parse(try fixture("latest-mac-legacy.yml"), feed: feed, environment: arm))
    try expectEqual(offer.displayVersion, "1.0.7"); try expectEqual(offer.sha512, "LEGACYSHA==")
    try expectEqual(offer.downloadURL.absoluteString, "https://updates.example.test/Legacy%20App-1.0.7-mac.zip")
}
check("latest-mac.yml dmg fallback with absolute URL; malformed refused") {
    let feed = URL(string: "https://updates.example.test/latest-mac.yml")!
    let offer = try sparkleOffer(ElectronResolver.parse(try fixture("latest-mac-dmg-only.yml"), feed: feed, environment: arm))
    try expectEqual(offer.format, .dmg); try expectEqual(offer.downloadURL.host, "cdn.example.test")
    try expectEqual(try refusal(ElectronResolver.parse(Data("files: []\n".utf8), feed: feed, environment: arm)).code, "malformed_feed")
}
check("app-update.yml: generic, github, unsupported provider") {
    try expectEqual(ElectronResolver.feedURL(fromAppUpdateYML: try fixture("app-update-generic.yml"))?.absoluteString,
                    "https://updates.example.test/app/latest-mac.yml")
    try expectEqual(ElectronResolver.feedURL(fromAppUpdateYML: try fixture("app-update-github.yml"))?.absoluteString,
                    "https://github.com/example-org/example-app/releases/latest/download/latest-mac.yml")
    try expect(ElectronResolver.feedURL(fromAppUpdateYML: try fixture("app-update-s3.yml")) == nil, "s3 should be unsupported")
    try expect(ElectronResolver.feedURL(fromAppUpdateYML: Data("provider: github\nowner: ../x\nrepo: y\n".utf8)) == nil, "unsafe owner accepted")
}

// MARK: Homebrew

check("cask: arm64 host uses base overrides from arm64_<os> variation; intel uses <os> variation") {
    let data = try fixture("cask-variations.json")
    let a = try sparkleOffer(HomebrewResolver.parse(data, token: "example", environment: arm))   // 15.1 = sequoia
    try expectEqual(a.downloadURL.absoluteString, "https://dl.example.test/arm64-sequoia/Example-2.0.0.zip")
    try expectEqual(a.displayVersion, "1.9.0"); try expectEqual(a.format, .zip)
    try expectEqual(a.sha256, String(repeating: "c", count: 64)); try expectEqual(a.minimumSystemVersion, "12")
    let i = try sparkleOffer(HomebrewResolver.parse(data, token: "example", environment: intel))
    try expectEqual(i.downloadURL.absoluteString, "https://dl.example.test/intel/Example-2.0.0.dmg"); try expectEqual(i.displayVersion, "2.0.0")
    let tahoe = try sparkleOffer(HomebrewResolver.parse(data, token: "example", environment: HostEnvironment(arch: .arm64, osVersion: "26.0")))
    try expectEqual(tahoe.downloadURL.lastPathComponent, "Example-2.0.0.dmg"); try expectEqual(tahoe.downloadURL.pathComponents[1], "arm64")
    let bigSur = try sparkleOffer(HomebrewResolver.parse(data, token: "example", environment: HostEnvironment(arch: .arm64, osVersion: "12.0")))
    try expectEqual(bigSur.displayVersion, "2.0.0", "monterey has no arm64 variation so the base applies")
    let newer = try sparkleOffer(HomebrewResolver.parse(data, token: "example", environment: HostEnvironment(arch: .arm64, osVersion: "40.0")))
    try expect(newer.downloadURL.absoluteString.contains("/arm64/"), "unknown future OS should use arm64 base")
}
check("cask: no_check sha256 is nil, comma version splits") {
    let o = try sparkleOffer(HomebrewResolver.parse(try fixture("cask-nocheck-comma.json"), token: "comma", environment: arm))
    try expect(o.sha256 == nil, "no_check should be nil"); try expectEqual(o.displayVersion, "1.2.3"); try expectEqual(o.buildVersion, "4567")
    try expectEqual(o.format, .pkg); try expectEqual(o.source, .homebrewCask(token: "comma"))
}
check("cask: latest is unversioned; unmet depends_on.macos is refused; bad token is rejected") {
    try expectEqual(try refusal(HomebrewResolver.parse(try fixture("cask-latest.json"), token: "floating", environment: arm)).code, "unversioned")
    try expectEqual(try refusal(HomebrewResolver.parse(try fixture("cask-needs-newer-macos.json"), token: "modern", environment: arm)).code, "no_compatible_item")
    let bad = try refusal(await HomebrewResolver.resolve(token: "../etc/passwd", fetcher: FakeFetcher(), environment: arm))
    try expectEqual(bad.code, "invalid_source")
    try expectEqual(try refusal(HomebrewResolver.parse(Data("{".utf8), token: "x", environment: arm)).code, "malformed_feed")
}
check("cask index: exact match, ambiguous no match, stable beats @beta, deprecated skipped") {
    let index = try CaskIndex(decoding: try fixture("cask-index.json"))
    try expectEqual(index.token(forAppNamed: "Example.app"), "example")
    try expect(index.token(forAppNamed: "Twin.app") == nil, "ambiguous matched")
    try expectEqual(index.token(forAppNamed: "Stable.app"), "stable")
    try expect(index.token(forAppNamed: "Old Thing.app") == nil, "deprecated matched")
    try expect(index.token(forAppNamed: "example.app") == nil, "match is not exact (case)")
    try expect(index.token(forAppNamed: "tool") == nil, "non-app artifact matched")
    try expectEqual(index.token(forAppNamed: "Nested.app"), "nested")
}
check("cask index cache: fetched once, reused for 24h, refreshed after") {
    let dir = testTemporaryDirectory.appendingPathComponent("uscache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let fetcher = FakeFetcher([CaskIndexProvider.url.absoluteString: .success(try fixture("cask-index.json"))])
    let t0 = Date()
    let first = CaskIndexProvider(fetcher: fetcher, cacheDirectory: dir, now: { t0 })
    guard case .success(let idx) = await first.index() else { throw CheckFailure(description: "no index") }
    try expectEqual(idx.token(forAppNamed: "Example.app"), "example")
    let second = CaskIndexProvider(fetcher: fetcher, cacheDirectory: dir, now: { t0.addingTimeInterval(3600) })
    _ = await second.index()
    try expectEqual(fetcher.requests.count, 1, "fresh cache should avoid a fetch")
    let third = CaskIndexProvider(fetcher: fetcher, cacheDirectory: dir, now: { t0.addingTimeInterval(25 * 3600) })
    _ = await third.index()
    try expectEqual(fetcher.requests.count, 2, "stale cache should refetch")
    let offline = CaskIndexProvider(fetcher: FakeFetcher(), cacheDirectory: dir, now: { t0.addingTimeInterval(50 * 3600) })
    guard case .success = await offline.index() else { throw CheckFailure(description: "stale cache should be used offline") }
    let mode = (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("cask-index.json").path))[.posixPermissions] as? Int
    try expectEqual(mode, 0o600)
}

// MARK: Catalogue

check("catalogue decodes valid file") {
    let c = try UserCatalogue.decode(try fixture("catalogue-valid.json"))
    try expectEqual(c.entries["com.example.sparkle"], .source(.sparkle(feed: URL(string: "https://updates.example.test/appcast.xml")!)))
    try expectEqual(c.entries["com.example.electron"], .source(.electron(feed: URL(string: "https://updates.example.test/latest-mac.yml")!)))
    try expectEqual(c.entries["com.example.brew"], .source(.homebrewCask(token: "example")))
    try expectEqual(c.entries["com.example.skip"], .ignore)
}
check("catalogue is strict: unknown keys, bad version, both/neither, bad token, duplicates") {
    for (name, needle) in [("catalogue-unknown-key.json", "colour"), ("catalogue-unknown-top-key.json", "extra"),
                           ("catalogue-bad-version.json", "version"), ("catalogue-both.json", "exactly one"),
                           ("catalogue-bad-token.json", "token")] {
        do { _ = try UserCatalogue.decode(try fixture(name)); throw CheckFailure(description: "\(name) was accepted") }
        catch let error as CatalogueError { try expect(error.message.contains(needle), "\(name): message \"\(error.message)\" lacks \"\(needle)\"") }
    }
    let dup = #"{"version":1,"apps":[{"bundleID":"a","ignore":true},{"bundleID":"a","ignore":true}]}"#
    do { _ = try UserCatalogue.decode(Data(dup.utf8)); throw CheckFailure(description: "duplicate accepted") } catch is CatalogueError {}
    do { _ = try UserCatalogue.decode(Data("[]".utf8)); throw CheckFailure(description: "array accepted") } catch is CatalogueError {}
    try expect(try UserCatalogue.load(from: fixtureRoot.appendingPathComponent("does-not-exist.json")) == .empty, "missing file should be empty")
}

// MARK: Checker (precedence, comparison, report)

let sparkleFeedURL = "https://updates.example.test/appcast.xml"
let electronConfig = Data("provider: generic\nurl: https://updates.example.test/app\n".utf8)
func makeChecker(_ fetcher: FakeFetcher, catalogue: UserCatalogue = .empty, index: String? = "cask-index.json", country: String = "gb") async throws -> UpdateChecker {
    let indexFetcher = FakeFetcher(index.map { [CaskIndexProvider.url.absoluteString: .success((try? fixture($0)) ?? Data())] } ?? [:])
    let dir = testTemporaryDirectory.appendingPathComponent("uschk-\(UUID().uuidString)")
    return UpdateChecker(fetcher: fetcher, caskIndex: CaskIndexProvider(fetcher: indexFetcher, cacheDirectory: dir),
                         catalogue: catalogue, environment: arm, teamID: { _ in "TEAM123456" }, storeCountry: country)
}
func app(_ name: String = "Example", id: String? = "com.example.app", short: String? = "1.0", build: String? = "100",
         sparkle: String? = nil, rejected: Bool = false, electron: Data? = nil, mas: Bool = false, wrapped: Bool = false) -> InstalledApp {
    InstalledApp(name: name, path: "/Applications/\(name).app", bundleID: id, shortVersion: short, build: build,
                 sparkleFeed: sparkle, sparkleFeedRejected: rejected, electronConfig: electron, isAppStore: mas, isWrappedIOSApp: wrapped)
}
func fakeWorld() throws -> FakeFetcher {
    FakeFetcher([
        sparkleFeedURL: .success(try fixture("appcast-realistic.xml")),
        "https://updates.example.test/app/latest-mac.yml": .success(try fixture("latest-mac-files.yml")),
        "https://formulae.brew.sh/api/cask/example.json": .success(try fixture("cask-nocheck-comma.json")),
    ])
}

check("checker precedence: catalogue > Sparkle > Electron > Homebrew") {
    let world = try fakeWorld()
    let all = app(sparkle: sparkleFeedURL, electron: electronConfig)
    let plain = try await makeChecker(world)
    try expectEqual(await plain.checkOne(all).source, .sparkle(feed: URL(string: sparkleFeedURL)!))
    try expectEqual(await plain.checkOne(app(electron: electronConfig)).source?.kind, "electron")
    try expectEqual(await plain.checkOne(app("Example")).source, .homebrewCask(token: "example"))   // Example.app in the index
    let none = await plain.checkOne(app("Unknown Thing"))
    try expectEqual(none.result, .noSource); try expect(none.source == nil, "source should be nil")
    let cat = UserCatalogue(entries: ["com.example.app": .source(.homebrewCask(token: "example"))])
    try expectEqual(await (try await makeChecker(world, catalogue: cat)).checkOne(all).source, .homebrewCask(token: "example"))
    try expectEqual(try await makeChecker(world).checkOne(app("Unsupported", electron: Data("provider: s3\nbucket: b\n".utf8))).result, .noSource)
}
check("checker: ignored apps are skipped; App Store apps get no source; input order kept") {
    let world = try fakeWorld()
    let cat = UserCatalogue(entries: ["com.example.skip": .ignore])
    let checker = try await makeChecker(world, catalogue: cat)
    let out = await checker.check([app("Zed", id: "com.example.z"), app("Skip", id: "com.example.skip"), app("Example", id: "com.example.m", mas: true), app("Alpha", id: "com.example.a")])
    try expectEqual(out.map(\.app.name), ["Zed", "Example", "Alpha"])
    // No App Store lookup answer for it: refused as a network problem, never a Sparkle/Homebrew guess.
    try expect(out[1].source == nil && out[1].result.refusalCode == "network", "App Store app got \(out[1].result)")
    try expectEqual(out[0].teamID, "TEAM123456")
}
check("checker: Sparkle compares build numbers; up to date when equal or newer") {
    let world = try fakeWorld()
    let checker = try await makeChecker(world)
    let behind = await checker.checkOne(app(short: "2.4", build: "240", sparkle: sparkleFeedURL))
    guard case .updateAvailable(let offer) = behind.result else { throw CheckFailure(description: "expected update, got \(behind.result)") }
    try expectEqual(offer.displayVersion, "2.5")
    // Display version looks older ("2.0") but the build number is current: Sparkle semantics say up to date.
    try expectEqual(await checker.checkOne(app(short: "2.0", build: "250", sparkle: sparkleFeedURL)).result, .upToDate)
    try expectEqual(await checker.checkOne(app(short: "9.0", build: "900", sparkle: sparkleFeedURL)).result, .upToDate)
    // No build number: fall back to short version strings.
    try expectEqual(await checker.checkOne(app(short: "2.5", build: nil, sparkle: sparkleFeedURL)).result, .upToDate)
    guard case .updateAvailable = await checker.checkOne(app(short: "2.0", build: nil, sparkle: sparkleFeedURL)).result else { throw CheckFailure(description: "fallback failed") }
    try expectEqual(await checker.checkOne(app(short: nil, build: nil, sparkle: sparkleFeedURL)).result, .refused(.missingInstalledVersion))
}
check("checker: Electron and Homebrew compare against the short version") {
    let world = try fakeWorld()
    let checker = try await makeChecker(world)
    guard case .updateAvailable(let e) = await checker.checkOne(app(short: "3.1.3", build: "1", electron: electronConfig)).result else { throw CheckFailure(description: "electron update expected") }
    try expectEqual(e.displayVersion, "3.1.4")
    try expectEqual(await checker.checkOne(app(short: "3.1.4", build: "1", electron: electronConfig)).result, .upToDate)
    try expectEqual(await checker.checkOne(app("Example", short: "1.2.3", build: "9999")).result, .upToDate)   // cask 1.2.3,4567
    guard case .updateAvailable = await checker.checkOne(app("Example", short: "1.2.2", build: "9999")).result else { throw CheckFailure(description: "cask update expected") }
}
check("checker: refusals are typed (http SUFeedURL, rejected feed, network, malformed)") {
    let world = try fakeWorld()
    let checker = try await makeChecker(world)
    try expectEqual(await checker.checkOne(app(sparkle: "http://updates.example.test/appcast.xml")).result.refusalCode, "insecure_feed")
    try expectEqual(await checker.checkOne(app(rejected: true)).result.refusalCode, "insecure_feed")
    try expectEqual(await checker.checkOne(app(sparkle: "https://nowhere.example.test/a.xml")).result.refusalCode, "network")
    let bad = FakeFetcher([sparkleFeedURL: .success(Data("<oops".utf8))])
    try expectEqual(await (try await makeChecker(bad)).checkOne(app(sparkle: sparkleFeedURL)).result.refusalCode, "malformed_feed")
    try expect(world.requests.allSatisfy { $0.hasPrefix("https://") }, "non-https request")
}
check("checker: cask index failure leaves apps as noSource, not an error") {
    let checker = try await makeChecker(try fakeWorld(), index: nil)
    try expectEqual(await checker.checkOne(app("Example")).result, .noSource)
}
check("checker limits concurrency") {
    final class Counting: HTTPFetching, @unchecked Sendable {
        let lock = NSLock(); var active = 0; var peak = 0; let data: Data
        init(_ data: Data) { self.data = data }
        func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
            lock.withLock { active += 1; peak = max(peak, active) }
            try await Task.sleep(nanoseconds: 20_000_000)
            lock.withLock { active -= 1 }
            return data
        }
    }
    let fetcher = Counting(try fixture("appcast-realistic.xml"))
    let dir = testTemporaryDirectory.appendingPathComponent("usconc-\(UUID().uuidString)")
    let checker = UpdateChecker(fetcher: fetcher, caskIndex: CaskIndexProvider(fetcher: FakeFetcher(), cacheDirectory: dir),
                                environment: arm, teamID: { _ in nil }, concurrency: 3)
    let apps = (0..<20).map { app("A\($0)", id: "id\($0)", sparkle: sparkleFeedURL) }
    let out = await checker.check(apps)
    try expectEqual(out.count, 20); try expect(fetcher.peak <= 3 && fetcher.peak > 1, "peak concurrency \(fetcher.peak)")
    try expectEqual(FetchLimits.concurrency, 6)
}
check("JSON report has a stable shape") {
    let checker = try await makeChecker(try fakeWorld())
    let out = [await checker.checkOne(app(short: "2.4", build: "240", sparkle: sparkleFeedURL)), await checker.checkOne(app("Unknown"))]
    let json = try JSONSerialization.jsonObject(with: try CheckReportRow.json(out)) as? [[String: Any]]
    try expectEqual(json?.count, 2)
    let keys = Set(json![0].keys)
    try expectEqual(keys, Set(json![1].keys), "every row has every key")
    for key in ["noSourceReason", "appStoreURL", "name", "path", "bundleID", "installedVersion", "teamID", "sourceKind", "status", "reason", "latestVersion", "downloadURL", "format", "sha256", "sha512", "edSignature", "length", "minimumKernelVersion", "installable"] {
        try expect(keys.contains(key), "missing key \(key)")
    }
    try expectEqual(json![0]["status"] as? String, "update_available"); try expectEqual(json![0]["latestVersion"] as? String, "2.5")
    try expectEqual(json![1]["status"] as? String, "no_source"); try expect(json![1]["latestVersion"] is NSNull, "null expected")
}

extension CheckResult {
    var refusalCode: String? { if case .refused(let r) = self { return r.code } else { return nil } }
}


// Review regressions use bounded fixture transformations, never expansion bombs.
check("R1 UTF16 plain XML refused") {
    let xml = String(data: try fixture("appcast-element-form.xml"), encoding: .utf8)!
    try expectEqual(try refusal(SparkleResolver.parse(xml.data(using: .utf16)!, feed: feed, environment: arm)).code, "malformed_feed")
}
check("R1 captured attributes capped") {
    var xml = String(data: try fixture("appcast-element-form.xml"), encoding: .utf8)!
    xml = xml.replacingOccurrences(of: "Older-1.zip", with: String(repeating: "x", count: 4097) + ".zip")
    _ = try sparkleOffer(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm))
}
check("R2 catalogue symlink refused") {
    let dir = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try fixture("catalogue-valid.json").write(to: dir.appendingPathComponent("target"))
    let link = dir.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("target"))
    do { _ = try UserCatalogue.load(from: link); throw CheckFailure(description: "symlink accepted") } catch let error as CatalogueError { try expectEqual(error.message, "catalogue.json must be a regular file, not a symlink") }
}
check("R3 unrelated stable collision refused") {
    let index = try CaskIndex(decoding: fixture("review-index.json"))
    try expect(index.token(forAppNamed: "Collision.app") == nil, "unrelated collision matched")
}
check("R4 numeric prefixes balanced before prerelease") {
    try expectEqual(VersionComparator.compare("1.0.0b1", "1.0"), .orderedAscending)
    try expectEqual(VersionComparator.compare("1.0.0b1", "1.0b2"), .orderedAscending)
}
check("R5 architecture enforced") {
    let data = Data(#"{"version":"2","url":"https://x.test/a.zip","depends_on":{"arch":[{"type":"arm","bits":64}]}}"#.utf8)
    try expectEqual(try refusal(HomebrewResolver.parse(data, token: "x", environment: intel)).code, "no_compatible_item")
}
check("R6 null checksum clears inherited digest") {
    var root = try JSONSerialization.jsonObject(with: fixture("review-cask.json")) as! [String: Any]
    root.removeValue(forKey: "depends_on")
    let offer = try sparkleOffer(HomebrewResolver.parse(JSONSerialization.data(withJSONObject: root), token: "x", environment: intel))
    try expect(offer.sha256 == nil, "inherited digest")
}
check("R7 macos equality alternatives") {
    _ = try sparkleOffer(HomebrewResolver.parse(try fixture("review-cask.json"), token: "x", environment: arm))
}
check("R9 architecture before format and directory markers") {
    let data = try fixture("review-electron.yml")
    try expectEqual(try sparkleOffer(ElectronResolver.parse(data, feed: feed, environment: arm)).downloadURL.path, "/arm64/App.dmg")
    try expectEqual(try sparkleOffer(ElectronResolver.parse(data, feed: feed, environment: intel)).downloadURL.path, "/x64/App.zip")
}
check("R10 generic query path and artifact propagation") {
    let config = Data("provider: generic\nurl: https://x.test/app?token=abc\n".utf8)
    try expectEqual(ElectronResolver.feedURL(fromAppUpdateYML: config)?.absoluteString, "https://x.test/app/latest-mac.yml?token=abc")
    let offer = try sparkleOffer(ElectronResolver.parse(try fixture("latest-mac-legacy.yml"), feed: URL(string: "https://x.test/app/latest-mac.yml?token=abc")!, environment: arm))
    try expectEqual(URLComponents(url: offer.downloadURL, resolvingAgainstBaseURL: false)?.query, "token=abc")
}


check("R1 UTF8 BOM accepted") {
    _ = try sparkleOffer(SparkleResolver.parse(Data([0xef,0xbb,0xbf]) + fixture("appcast-element-form.xml"), feed: feed, environment: arm))
}
check("R1 UTF16 entity expansion refused") {
    let xml = #"<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE rss [<!ENTITY a "abc"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://x.test/&c;.zip" sparkle:version="2"/></item></channel></rss>"#
    try expectEqual(try refusal(SparkleResolver.parse(xml.data(using: .utf16)!, feed: feed, environment: arm)).code, "malformed_feed")
}
check("R1 nonUTF8 declaration refused") {
    let xml = String(data: try fixture("appcast-element-form.xml"), encoding: .utf8)!.replacingOccurrences(of: "utf-8", with: "ISO-8859-1")
    _ = try refusal(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm))
}
for declaration in ["<!ELEMENT rss ANY>", "<!ATTLIST rss x CDATA #IMPLIED>", "<!NOTATION gif SYSTEM 'image/gif'>", "<!ENTITY a 'x'>", "<!ENTITY a SYSTEM 'https://x.test/a'>", "<!NOTATION gif SYSTEM 'image/gif'><!ENTITY a SYSTEM 'https://x.test/a' NDATA gif>"] {
    check("R1 declaration refused: \(declaration)") {
        let xml = "<!DOCTYPE rss [\(declaration)]>" + String(data: try fixture("review-appcast.xml"), encoding: .utf8)!.replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: "")
        _ = try refusal(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm))
    }
}
check("R1 2500 items accepted and retention stops at 2000") {
    let item = #"<item><enclosure url="https://x.test/a.zip" sparkle:version="2"/></item>"#
    let xml = #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>"# + String(repeating: item, count: 2000) + item.replacingOccurrences(of: "version=\"2\"", with: "version=\"999\"") + String(repeating: item, count: 499) + "</channel></rss>"
    try expectEqual(try sparkleOffer(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm)).displayVersion, "2")
}
check("R1 aggregate cap") {
    let item = "<item><enclosure url=\"https://x.test/a.zip\" sparkle:version=\"2\" x=\"" + String(repeating: "a", count: 5000) + "\"/></item>"
    let xml = #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>"# + String(repeating: item, count: 400) + "</channel></rss>"
    _ = try sparkleOffer(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm))
}
check("R1 captured text capped") {
    let xml = String(data: try fixture("appcast-element-form.xml"), encoding: .utf8)!.replacingOccurrences(of: "<sparkle:version>9", with: "<sparkle:version>" + String(repeating: "1", count: 4097))
    _ = try sparkleOffer(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm))
}
check("R2 cache symlink refused") {
    let dir = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try fixture("cask-index.json").write(to: dir.appendingPathComponent("target"))
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("cask-index.json"), withDestinationURL: dir.appendingPathComponent("target"))
    if case .success = await CaskIndexProvider(fetcher: FakeFetcher(), cacheDirectory: dir).index() { throw CheckFailure(description: "cache symlink accepted") }
}
check("R2 symlink to oversized catalogue refused") {
    let url = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    var data = try fixture("catalogue-valid.json"); data.append(Data(repeating: 32, count: UserCatalogue.maxBytes))
    let target = url.appendingPathExtension("target")
    defer { try? FileManager.default.removeItem(at: target) }
    try data.write(to: target)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    do { _ = try UserCatalogue.load(from: url); throw CheckFailure(description: "oversized accepted") } catch let error as CatalogueError { try expectEqual(error.message, "catalogue.json must be a regular file, not a symlink") }
}
check("R2 symlink to oversized cache refused") {
    let dir = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("cask-index.json")
    var data = try fixture("cask-index.json")
    data.append(Data(repeating: 32, count: FetchLimits.caskIndexBytes + 1 - data.count))
    let target = dir.appendingPathComponent("target")
    try data.write(to: target)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    if case .success = await CaskIndexProvider(fetcher: FakeFetcher(), cacheDirectory: dir).index() { throw CheckFailure(description: "oversized cache accepted") }
}
check("R3 declared identity enforced") {
    let index = try CaskIndex(decoding: fixture("review-index.json"))
    try expect(index.match(forAppNamed: "Real.app", bundleID: "com.impostor.app") == nil, "mismatched identity accepted")
    try expectEqual(index.match(forAppNamed: "Real.app", bundleID: "com.real.app")?.lowConfidence, false)
    try expectEqual(index.match(forAppNamed: "Collision.app", bundleID: nil)?.token, nil)
    let unknown = CaskIndex(tokensByApp: ["Unknown.app": ["unknown"]])
    try expectEqual(unknown.match(forAppNamed: "Unknown.app", bundleID: nil)?.lowConfidence, true)
}
check("R5 unsupported platforms enforced") {
    var root = try JSONSerialization.jsonObject(with: fixture("review-cask.json")) as! [String: Any]
    root["unsupported_platforms"] = ["sequoia"]
    _ = try refusal(HomebrewResolver.parse(JSONSerialization.data(withJSONObject: root), token: "x", environment: intel))
}
check("R5 supported platforms enforced") {
    var root = try JSONSerialization.jsonObject(with: fixture("review-cask.json")) as! [String: Any]
    root["supported_platforms"] = ["arm64_sequoia"]
    _ = try refusal(HomebrewResolver.parse(JSONSerialization.data(withJSONObject: root), token: "x", environment: intel))
}
check("R8 kernel minimum enforced") {
    _ = try refusal(ElectronResolver.parse(try fixture("review-electron.yml"), feed: feed, environment: HostEnvironment(arch: .arm64, osVersion: "15", kernelVersion: "23.0.0")))
}
check("R8 kernel minimum exposed") {
    let o = try sparkleOffer(ElectronResolver.parse(try fixture("review-electron.yml"), feed: feed, environment: HostEnvironment(arch: .arm64, osVersion: "14", kernelVersion: "24.0.0")))
    try expect(o.minimumSystemVersion == nil, "Darwin minimum labelled macOS")
    try expectEqual(o.minimumKernelVersion, "24.0.0")
}
check("R10 cross origin query not leaked") {
    let o = try sparkleOffer(ElectronResolver.parse(try fixture("latest-mac-dmg-only.yml"), feed: URL(string: "https://x.test/latest-mac.yml?token=secret")!, environment: arm))
    try expect(URLComponents(url: o.downloadURL, resolvingAgainstBaseURL: false)?.query == nil, "cross origin token leak")
}
check("R11 installed build minimum enforced") {
    let o = try sparkleOffer(SparkleResolver.parse(try fixture("review-appcast.xml"), feed: feed, environment: arm, installedBuild: "100"))
    try expectEqual(o.buildVersion, "150")
}
check("R11 installed short minimum enforced") {
    let o = try sparkleOffer(SparkleResolver.parse(try fixture("review-appcast.xml"), feed: feed, environment: arm, installedShortVersion: "100"))
    try expectEqual(o.buildVersion, "150")
}


check("R9 Intel directory markers") {
    let text = String(data: try fixture("review-electron.yml"), encoding: .utf8)!.replacingOccurrences(of: "arm64/App.dmg", with: "arm64/App.zip")
    try expectEqual(try sparkleOffer(ElectronResolver.parse(Data(text.utf8), feed: feed, environment: intel)).downloadURL.path, "/x64/App.zip")
}
check("R10 relative same origin query") {
    let o = try sparkleOffer(ElectronResolver.parse(try fixture("latest-mac-legacy.yml"), feed: URL(string: "https://x.test/app/latest-mac.yml?token=abc")!, environment: arm))
    try expectEqual(URLComponents(url: o.downloadURL, resolvingAgainstBaseURL: false)?.query, "token=abc")
}
check("R4 balanced prereleases compare suffixes") {
    try expectEqual(VersionComparator.compare("1.0.0b1", "1.0b2"), .orderedAscending)
}
check("R3 pkgutil pattern remains declared") {
    let data = Data(#"[{"token":"p","artifacts":[{"app":["P.app"]},{"uninstall":[{"pkgutil":"com.vendor.*"}]}]}]"#.utf8)
    let i = try CaskIndex(decoding: data)
    try expect(i.match(forAppNamed: "P.app", bundleID: "com.impostor.app") == nil, "pattern downgraded to filename identity")
}

check("R7 equality alternatives both accepted and independent constraints combined") {
    let data = try fixture("review-cask.json")
    _ = try sparkleOffer(HomebrewResolver.parse(data, token: "x", environment: HostEnvironment(arch: .arm64, osVersion: "14.2")))
    _ = try refusal(HomebrewResolver.parse(data, token: "x", environment: HostEnvironment(arch: .arm64, osVersion: "13.2")))
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    root["depends_on"] = ["macos": [">=": ["14"], "<": ["15"]]]
    _ = try refusal(HomebrewResolver.parse(JSONSerialization.data(withJSONObject: root), token: "x", environment: arm))
}
check("R6 explicit null and absent JSON semantics") {
    var root = try JSONSerialization.jsonObject(with: fixture("review-cask.json")) as! [String: Any]
    root["variations"] = ["sequoia": ["url": NSNull()]]
    _ = try refusal(HomebrewResolver.parse(JSONSerialization.data(withJSONObject: root), token: "x", environment: intel))
    root["variations"] = ["sequoia": ["version": NSNull()]]
    _ = try refusal(HomebrewResolver.parse(JSONSerialization.data(withJSONObject: root), token: "x", environment: intel))
    root["depends_on"] = ["macos": [">=": ["99"]]]
    root["variations"] = ["sequoia": ["depends_on": NSNull()]]
    _ = try sparkleOffer(HomebrewResolver.parse(JSONSerialization.data(withJSONObject: root), token: "x", environment: intel))
}
check("R3 identity stanza forms") {
    for artifact in [#"{"uninstall":[{"launchctl":"com.real.app"}]}"#, #"{"uninstall":[{"signal":[["TERM","com.real.app"]]}]}"#, #"{"uninstall":[{"pkgutil":"com.real.app"}]}"#, #"{"zap":[{"trash":["~/Library/Preferences/com.real.app.plist"]}]}"#] {
        let json = "[{\"token\":\"real\",\"artifacts\":[{\"app\":[\"Real.app\"]}," + artifact + "]}]"
        let index = try CaskIndex(decoding: Data(json.utf8))
        try expect(index.match(forAppNamed: "Real.app", bundleID: "com.wrong.app") == nil, "identity not enforced")
        try expectEqual(index.match(forAppNamed: "Real.app", bundleID: "com.real.app")?.lowConfidence, false)
    }
}
check("R3 low confidence exposed in outcome and JSON") {
    let outcome = await (try await makeChecker(fakeWorld())).checkOne(app("Example"))
    try expect(outcome.lowConfidence, "confidence missing")
    try expectEqual(outcome.installable, false)
    let json = try JSONSerialization.jsonObject(with: CheckReportRow.json([outcome])) as! [[String: Any]]
    try expectEqual(json[0]["lowConfidence"] as? Bool, true)
    try expectEqual(json[0]["installable"] as? Bool, false)
    let explicit = UserCatalogue(entries: ["com.example.app": .source(.homebrewCask(token:"example"))])
    let enabled = await (try await makeChecker(fakeWorld(), catalogue: explicit)).checkOne(app("Example"))
    try expectEqual(enabled.installable, true)
    let enabledJSON = try JSONSerialization.jsonObject(with: CheckReportRow.json([enabled])) as! [[String: Any]]
    try expectEqual(enabledJSON[0]["installable"] as? Bool, true)
}
check("R11 eligible critical release and informational skip") {
    var xml = String(data: try fixture("review-appcast.xml"), encoding: .utf8)!
    xml = xml.replacingOccurrences(of: "<sparkle:minimumUpdateVersion>", with: "<sparkle:criticalUpdate/><sparkle:minimumUpdateVersion>")
    xml = xml.replacingOccurrences(of: "</channel>", with: "<item><sparkle:version>900</sparkle:version><sparkle:informationalUpdate/></item></channel>")
    try expectEqual(try sparkleOffer(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm, installedBuild: "200")).buildVersion, "300")
    try expectEqual(try sparkleOffer(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm, installedBuild: "100")).buildVersion, "150")
    try expectEqual(VersionComparator.compare("1.0a", "1.0"), .orderedAscending)
}
check("R10 percent encoded base path preserved") {
    let config = Data("provider: generic\nurl: https://x.test/signed%2Ftenant\n".utf8)
    try expectEqual(ElectronResolver.feedURL(fromAppUpdateYML: config)?.absoluteString, "https://x.test/signed%2Ftenant/latest-mac.yml")
}
check("R10 percent encoded base path with query preserved") {
    let config = Data("provider: generic\nurl: https://x.test/signed%2Ftenant?token=abc\n".utf8)
    try expectEqual(ElectronResolver.feedURL(fromAppUpdateYML: config)?.absoluteString, "https://x.test/signed%2Ftenant/latest-mac.yml?token=abc")
}


check("R12 Homebrew URLs do not declare architecture") {
    for url in ["https://x.test/App-x86_64.zip", "https://x.test/App-arm64-x86_64.zip"] {
        let data = try JSONSerialization.data(withJSONObject: ["version":"2", "url":url])
        for env in [arm, intel] { _ = try sparkleOffer(HomebrewResolver.parse(data, token: "x", environment: env)) }
    }
}
check("R12 XML compatible encoding aliases") {
    let body = #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://x.test/a.zip" sparkle:version="2"/></item></channel></rss>"#
    for encoding in ["UTF-8", "utf8", "US-ASCII", "aScIi"] {
        _ = try sparkleOffer(SparkleResolver.parse(Data(("<?xml version=\"1.0\" encoding=\"\(encoding)\"?>" + body).utf8), feed: feed, environment: arm))
    }
    _ = try refusal(SparkleResolver.parse(Data([0xff]) + Data(body.utf8), feed: feed, environment: arm))
}
check("R12 XHTML descriptions do not consume retention") {
    let item = "<item><description><div xmlns=\"http://www.w3.org/1999/xhtml\" class=\"" + String(repeating: "a", count: 5000) + "\">" + String(repeating: "long ", count: 500) + "</div></description><enclosure url=\"https://x.test/a.zip\" sparkle:version=\"2\"/></item>"
    let xml = #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>"# + String(repeating: item, count: 400) + "</channel></rss>"
    _ = try sparkleOffer(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm))
}
check("R12 Electron architecture token boundaries and inherited base") {
    let base = URL(string: "https://x.example/arm64-mirror/latest-mac.yml")!
    let text = "version: 2\nfiles:\n  - url: App-1.0-x64.zip\n  - url: App-1.0-arm64.zip\n"
    for (env, suffix) in [(arm, "arm64.zip"), (intel, "x64.zip")] {
        let o = try sparkleOffer(ElectronResolver.parse(Data(text.utf8), feed: base, environment: env))
        try expect(o.downloadURL.path.hasSuffix(suffix), "inherited directory changed artifact arch")
    }
    for raw in ["https://arm64.example/App.zip?arch=arm64", "https://x.test/charminarm64.zip", "https://x.test/intelligent.zip"] {
        _ = try sparkleOffer(ElectronResolver.parse(Data("version: 2\npath: \(raw)\n".utf8), feed: feed, environment: intel))
    }
    _ = try refusal(ElectronResolver.parse(Data("version: 2\npath: https://x.test/App intel.zip\n".utf8), feed: feed, environment: arm))
}
check("R12 Electron intel substring is not architecture") {
    _ = try sparkleOffer(ElectronResolver.parse(Data("version: 2\npath: https://x.test/intelligent.zip\n".utf8), feed: feed, environment: arm))
}
check("R12 Electron semver beta ordering") {
    for (candidate, installed, update) in [("1.2.3-beta5","1.2.3-beta4",true), ("1.2.3","1.2.3-beta5",true), ("1.2.3-beta.5","1.2.3-beta.4",true), ("1.2.3-100000000000000000000","1.2.3-99999999999999999999",true), ("1.2","1.2b",true), ("1.2.3-01","1.2.3-2",false), ("v1.2.3-beta.5","v1.2.3-beta.4",false), ("1.2.3","1.2.3-beta.5",true), ("1.2.3-beta.4","1.2.3-beta.5",false), ("1.2.3+new","1.2.3+old",false), ("1.2.3-beta.10","1.2.3-beta.9",true), ("1.2.3-beta.a","1.2.3-beta.9",true)] {
        let f = FakeFetcher([feed.absoluteString:.success(Data("version: \(candidate)\npath: App.zip\n".utf8))])
        let c = UpdateChecker(fetcher: f, caskIndex: CaskIndexProvider(fetcher: f, cacheDirectory: testTemporaryDirectory.appendingPathComponent(UUID().uuidString)), catalogue: UserCatalogue(entries:["com.example.app":.source(.electron(feed:feed))]), environment:arm, teamID:{_ in nil})
        let o = await c.checkOne(app(short:installed))
        if update { if case .updateAvailable = o.result {} else { throw CheckFailure(description:"semver update missing \(candidate) > \(installed)") } }
        else { try expectEqual(o.result, .upToDate) }
    }
}
check("R12 Homebrew suffix retains Sparkle semantics") {
    let f = FakeFetcher(["https://formulae.brew.sh/api/cask/example.json":.success(Data(#"{"version":"8.38.4-1","url":"https://x.test/a.zip"}"#.utf8))])
    let c = try await makeChecker(f)
    try expectEqual(await c.checkOne(app(short:"8.38.4")).result, .upToDate)
}

for constraint in ["<sparkle:minimumUpdateVersion>200</sparkle:minimumUpdateVersion>", "<sparkle:channel>beta</sparkle:channel>"] {
    check("R12 aggregate overflow drops item with constraint: \(constraint)") {
        let item = "<item><enclosure url=\"https://x.test/a.zip\" sparkle:version=\"2\" sparkle:edSignature=\"" + String(repeating: "a", count: 4096) + "\"/></item>"
        let final = "<item><enclosure url=\"https://x.test/a.zip\" sparkle:version=\"300\" sparkle:edSignature=\"" + String(repeating: "a", count: 2834) + "\"/>" + constraint + "</item>"
        let xml = #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>"# + String(repeating: item, count: 254) + final + "</channel></rss>"
        let offer = try sparkleOffer(SparkleResolver.parse(Data(xml.utf8), feed: feed, environment: arm, installedBuild: "100"))
        try expectEqual(offer.buildVersion, "2", "overflow must not discard eligibility constraints")
    }
}

// MARK: Homebrew bundle-ID matching

let bundleIndex = try CaskIndex(decoding: try fixture("cask-index-bundle.json"))
func bundleMatch(_ name: String, _ id: String, installed: Set<String> = []) -> (token: String, strength: EvidenceStrength)? {
    bundleIndex.bundleMatch(appName: name + ".app", bundleID: id, installedBundleIDs: installed)
}
func hbMatch(_ name: String, _ id: String, installed: Set<String> = []) -> (token: String, lowConfidence: Bool)? {
    bundleIndex.match(for: app(name, id: id), installedBundleIDs: installed)
}

check("bundle ID: Teams pkg (medium) beats the suite on a name tie-break; Toolbox signal and UniFi quit are strong") {
    let teams = try bundleIndex.bundleCandidates(appName: "Microsoft Teams.app", bundleID: "com.microsoft.teams2", installedBundleIDs: [])
    try expectEqual(teams.map(\.token), ["microsoft-teams", "microsoft-office-businesspro"])
    try expect(teams.allSatisfy { $0.strength == .medium }, "both are pkgutil evidence")
    try expectEqual(bundleMatch("Microsoft Teams", "com.microsoft.teams2")?.token, "microsoft-teams")
    try expectEqual(hbMatch("Microsoft Teams", "com.microsoft.teams2")?.lowConfidence, false)
    try expect(bundleMatch("Teams Thing", "com.microsoft.teams2") == nil, "without a name match the two medium casks tie")
    let toolbox = hbMatch("Parallels Toolbox", "com.parallels.toolbox")
    try expectEqual(toolbox?.token, "parallels-toolbox"); try expectEqual(bundleMatch("Parallels Toolbox", "com.parallels.toolbox")?.strength, .strong)
    let unifi = hbMatch("UniFi Endpoint", "com.ui.uid.standard-desktop")
    try expectEqual(unifi?.token, "unifi-identity-endpoint"); try expectEqual(unifi?.lowConfidence, false)
}
check("bundle ID: weak (zap-only) evidence is low confidence; glob prefixes and file suffixes are handled") {
    let mb = hbMatch("Malwarebytes", "com.malwarebytes.mbam.frontend.application")
    try expectEqual(mb?.token, "malwarebytes"); try expectEqual(mb?.lowConfidence, true)
    try expectEqual(bundleMatch("Malwarebytes", "com.malwarebytes.mbam.frontend.application")?.strength, .weak)
    // "com.malwarebytes.mbam.frontend.*" is a glob prefix, not the identity "com.malwarebytes.mbam.frontend".
    try expect(bundleMatch("Malwarebytes", "com.malwarebytes.mbam.frontend") == nil, "glob prefix registered as identity")
    // A team ID prefix on a zap path does not hide the bundle ID.
    try expectEqual(bundleMatch("DisplayLinkShared", "com.displaylink.DisplayLinkShared")?.token, "displaylink")
    try expect(bundleMatch("Anything", "com.nobody.knows") == nil, "unmentioned bundle ID matched")
}
check("bundle ID: DisplayLink beats Elgato's strong quit target through name affinity") {
    let ranked = bundleIndex.bundleCandidates(appName: "DisplayLinkUserAgent.app", bundleID: "com.displaylink.DisplayLinkUserAgent", installedBundleIDs: [])
    try expectEqual(ranked.map(\.token), ["displaylink", "elgato-camera-hub"])
    try expectEqual(ranked[0].strength, .weak); try expectEqual(ranked[1].strength, .strong)
    try expect(ranked[0].affinity && !ranked[1].affinity, "affinity decides")
    let m = hbMatch("DisplayLinkUserAgent", "com.displaylink.DisplayLinkUserAgent")
    try expectEqual(m?.token, "displaylink"); try expectEqual(m?.lowConfidence, true)
}
check("bundle ID: strength ranks; suite is penalised; ambiguity gives no match; deprecated and disabled are skipped") {
    try expectEqual(bundleMatch("Rank", "com.acme.rank")?.token, "rank-strong")
    try expectEqual(bundleMatch("Widget", "com.acme.widget")?.token, "single-tool", "single-app cask beats the suite")
    try expectEqual(bundleMatch("Widget", "com.acme.widget", installed: ["com.acme.widget", "com.acme.gadget"])?.token, "single-tool")
    try expectEqual(bundleIndex.bundleCandidates(appName: "Gadget.app", bundleID: "com.acme.gadget", installedBundleIDs: ["com.acme.gadget", "com.acme.widget"]).first?.suitePenalty, 2)
    try expect(bundleMatch("Twin", "com.acme.twin") == nil, "two equal casks must not match")
    try expect(bundleMatch("Retired", "com.acme.retired") == nil, "deprecated cask matched")
    try expect(bundleMatch("Gone", "com.acme.gone") == nil, "disabled cask matched")
}
check("bundle ID: filename match wins and keeps its identity check; bundle ID is only the fallback") {
    try expectEqual(hbMatch("Declared", "com.acme.declared")?.token, "declared-app")
    try expectEqual(hbMatch("Declared", "com.acme.declared")?.lowConfidence, false)
    // Same filename, a bundle ID the cask does not declare: rejected, and nothing else mentions it.
    try expect(hbMatch("Declared", "com.other.declared") == nil, "identity mismatch accepted")
}
check("checker: Homebrew bundle-ID match makes a weak-only source not installable; explain shows the reasoning") {
    let world = FakeFetcher(["https://formulae.brew.sh/api/cask/malwarebytes.json": .success(Data(#"{"version":"5.0","url":"https://dl.example.test/m.pkg","sha256":"no_check"}"#.utf8))])
    let checker = try await makeChecker(world, index: "cask-index-bundle.json")
    let weak = await checker.checkOne(app("Malwarebytes", id: "com.malwarebytes.mbam.frontend.application", short: "4.0"))
    try expectEqual(weak.source, .homebrewCask(token: "malwarebytes"))
    try expect(weak.lowConfidence && !weak.installable, "weak-only must not be installable")
    let (_, lines) = await checker.explain(app("Malwarebytes", id: "com.malwarebytes.mbam.frontend.application", short: "4.0"))
    let text = lines.joined(separator: "\n")
    try expect(text.contains("candidate malwarebytes") && text.contains("weak") && text.contains("low confidence") && text.contains("result:"), text)
    let (_, none) = await checker.explain(app("Nobody", id: "com.nobody.knows"))
    try expect(none.joined(separator: "\n").contains("no cask mentions bundle ID"), none.joined(separator: "\n"))
}

// MARK: App Store

func lookupKey(_ ids: [String], _ cc: String = "gb") -> String { AppStoreResolver.lookupURL(bundleIDs: ids, country: cc)!.absoluteString }
func storeJSON(_ id: String, _ track: Int, _ version: String, kind: String = "mac-software") -> String {
    #"{"kind":"\#(kind)","bundleId":"\#(id)","trackId":\#(track),"version":"\#(version)","trackViewUrl":"https://apps.apple.com/gb/app/x/id\#(track)?mt=12"}"#
}
func storeResponse(_ items: [String]) -> Data { Data(#"{"resultCount":\#(items.count),"results":[\#(items.joined(separator: ","))]}"#.utf8) }

check("App Store lookup URL: https, comma-separated batch, macSoftware, country validated") {
    let url = AppStoreResolver.lookupURL(bundleIDs: ["com.acme.a", "com.acme.b"], country: "gb")!
    try expectEqual(url.absoluteString, "https://itunes.apple.com/lookup?bundleId=com.acme.a,com.acme.b&country=gb&entity=macSoftware")
    try expect(AppStoreResolver.lookupURL(bundleIDs: ["com.acme.a"], country: "GBR") == nil, "bad country accepted")
    try expect(AppStoreResolver.lookupURL(bundleIDs: ["a&country=us"], country: "gb") == nil, "unsafe bundle ID accepted")
    try expectEqual(AppStoreResolver.country(for: Locale(identifier: "en_GB")), "gb")
    try expectEqual(AppStoreResolver.country(for: Locale(identifier: "en")), "us")
    for region in ["en_IM", "en_JE", "en_GG"] {
        try expectEqual(AppStoreResolver.country(for: Locale(identifier: region)), "gb", region)
    }
}
check("App Store parse: batch keeps only requested Mac App Store listings with https view URL; matching is case-insensitive") {
    let data = try fixture("appstore-lookup-batch.json")
    let records = try AppStoreResolver.parse(data, requested: ["com.acme.alpha", "com.acme.beta", "com.acme.phone", "com.acme.insecure"]).get().records
    // com.acme.phone is an iPhone/iPad listing (kind "software"), the only listing for that requested ID.
    try expectEqual(Set(records.keys), ["com.acme.alpha", "com.acme.beta", "com.acme.phone"])
    try expectEqual(records["com.acme.alpha"]?.trackID, 111); try expectEqual(records["com.acme.alpha"]?.version, "2.0")
    try expectEqual(records["com.acme.alpha"]?.minimumOSVersion, "13.0")
    try expectEqual(records["com.acme.beta"]?.version, "1.5.1")
    let single = try AppStoreResolver.parse(storeResponse([storeJSON("com.acme.a", 7, "3")]), requested: ["com.acme.a"]).get().records
    try expectEqual(single.count, 1)
    try expectEqual(try AppStoreResolver.parse(storeResponse([]), requested: ["com.acme.a"]).get().records.count, 0, "missing app is just absent")
}
check("App Store parse: an iPhone/iPad listing (kind software) counts when it is the only one; mac-software wins") {
    let ios = try AppStoreResolver.parse(storeResponse([storeJSON("net.example.chat", 9, "26.43.75", kind: "software")]),
                                         requested: ["net.example.chat"]).get().records
    try expectEqual(ios["net.example.chat"]?.version, "26.43.75")
    let both = try AppStoreResolver.parse(storeResponse([storeJSON("com.acme.both", 1, "1.0", kind: "software"),
                                                         storeJSON("com.acme.both", 2, "2.0")]),
                                          requested: ["com.acme.both"]).get()
    try expectEqual(both.records["com.acme.both"]?.trackID, 2); try expect(both.conflicts.isEmpty, "mac listing should win, not conflict")
    let other = try AppStoreResolver.parse(storeResponse([storeJSON("com.acme.tv", 3, "1.0", kind: "tv-software")]),
                                           requested: ["com.acme.tv"]).get().records
    try expect(other.isEmpty, "other kinds stay excluded")
}
check("App Store parse: malformed, oversized and ambiguous responses") {
    for bad in ["not json", "[]", #"{"resultCount":1}"#, #"{"results":"x"}"#] {
        if case .success = AppStoreResolver.parse(Data(bad.utf8), requested: ["com.acme.a"]) { throw CheckFailure(description: "accepted \(bad)") }
    }
    // Records with bad fields are skipped, not guessed at.
    let skipped = try AppStoreResolver.parse(storeResponse([storeJSON("com.acme.a", 0, "1"), storeJSON("com.acme.a", 5, ""),
        #"{"kind":"mac-software","bundleId":"com.acme.a","trackId":true,"version":"1","trackViewUrl":"https://x.test/"}"#]), requested: ["com.acme.a"]).get().records
    try expect(skipped.isEmpty, "bad records kept: \(skipped)")
    let dup = try AppStoreResolver.parse(storeResponse([storeJSON("com.acme.a", 5, "1"), storeJSON("com.acme.a", 6, "1"), storeJSON("com.acme.a", 7, "1")]), requested: ["com.acme.a"]).get()
    try expect(dup.records.isEmpty && dup.conflicts == ["com.acme.a"], "conflicting listings must be refused, not order-dependent")
    // Same track ID but different versions conflict too, whichever order they arrive in.
    for order in [[storeJSON("com.acme.a", 5, "1"), storeJSON("com.acme.a", 5, "2")], [storeJSON("com.acme.a", 5, "2"), storeJSON("com.acme.a", 5, "1")]] {
        let r = try AppStoreResolver.parse(storeResponse(order), requested: ["com.acme.a"]).get()
        try expect(r.records.isEmpty && r.conflicts == ["com.acme.a"], "same-id different-version records must conflict")
    }
    // Identical duplicates are accepted once.
    let same = try AppStoreResolver.parse(storeResponse([storeJSON("com.acme.a", 5, "1"), storeJSON("com.acme.a", 5, "1")]), requested: ["com.acme.a"]).get()
    try expect(same.records.count == 1 && same.conflicts.isEmpty, "identical duplicates")
    let big = Data(repeating: 0x20, count: AppStoreResolver.maxResponseBytes + 1)
    guard case .failure(.tooLarge) = AppStoreResolver.parse(big, requested: ["com.acme.a"]) else { throw CheckFailure(description: "oversized accepted") }
}
check("App Store lookup falls back to the us storefront when the region is not a storefront (HTTP 400)") {
    let f = FakeFetcher([lookupKey(["com.acme.a"], "im"): .failure(.http(400)), lookupKey(["com.acme.a"], "us"): .success(storeResponse([storeJSON("com.acme.a", 1, "2")]))])
    try expectEqual(try await AppStoreResolver.lookup(bundleIDs: ["com.acme.a"], country: "im", fetcher: f).get().records.count, 1)
    try expectEqual(f.requests.count, 2)
    try expectEqual(f.maxBytesSeen, [AppStoreResolver.maxResponseBytes, AppStoreResolver.maxResponseBytes], "cap on the initial and the fallback request")
    let bad = FakeFetcher([lookupKey(["com.acme.a"], "us"): .failure(.http(400))])
    guard case .failure = await AppStoreResolver.lookup(bundleIDs: ["com.acme.a"], country: "us", fetcher: bad) else { throw CheckFailure(description: "us 400 accepted") }
    try expectEqual(bad.requests.count, 1, "no retry loop on us")
}
check("App Store lookup batches 50 at a time and never sends an http URL") {
    let ids = (0..<120).map { String(format: "com.acme.app%03d", $0) }
    let f = FakeFetcher()
    _ = await AppStoreResolver.lookup(bundleIDs: ids, country: "us", fetcher: f)
    // Every request fails (404) so only the first batch is attempted, and it is a 50-ID https request.
    try expectEqual(f.requests.count, 1)
    try expect(f.requests[0].hasPrefix("https://itunes.apple.com/lookup?"), f.requests[0])
    try expectEqual(f.requests[0].components(separatedBy: "bundleId=")[1].components(separatedBy: "&")[0].components(separatedBy: ",").count, 50)
    let ok = FakeFetcher([lookupKey(Array(ids[0..<50]), "us"): .success(storeResponse([])), lookupKey(Array(ids[50..<100]), "us"): .success(storeResponse([])),
                          lookupKey(Array(ids[100..<120]), "us"): .success(storeResponse([storeJSON(ids[119], 9, "1.0")]))])
    let records = try await AppStoreResolver.lookup(bundleIDs: ids, country: "us", fetcher: ok).get().records
    try expectEqual(ok.requests.count, 3); try expectEqual(records.keys.sorted(), [ids[119]])
}
check("checker: App Store app is up to date / has an update, never installable, with appStoreURL; one batched request") {
    let ids = ["com.acme.alpha", "com.acme.beta", "com.acme.gone"]
    let world = FakeFetcher([lookupKey(ids): .success(storeResponse([storeJSON("com.acme.alpha", 111, "2.0"), storeJSON("com.acme.beta", 222, "1.5.1")]))])
    let checker = try await makeChecker(world)
    let out = await checker.check([app("Alpha", id: "com.acme.alpha", short: "1.0", mas: true), app("Beta", id: "com.acme.beta", short: "1.5.1", mas: true),
                                   app("Gone", id: "com.acme.gone", short: "1.0", mas: true)])
    try expectEqual(world.requests.count, 1, "one batched lookup")
    let alpha = out[0]
    guard case .updateAvailable(let offer) = alpha.result else { throw CheckFailure(description: "alpha: \(alpha.result)") }
    try expectEqual(offer.displayVersion, "2.0"); try expectEqual(alpha.source, .appStore(trackID: 111))
    try expect(!alpha.installable && !alpha.lowConfidence, "App Store updates are never installable")
    try expect(alpha.isAppStoreUpdate, "typed as App Store update")
    try expectEqual(alpha.managedByAppStore?.code, "app_store_managed"); try expectEqual(alpha.managedByAppStore?.message, "Update in the App Store")
    try expectEqual(alpha.appStoreURL?.absoluteString, "macappstore://apps.apple.com/app/id111")
    try expectEqual(out[1].result, .upToDate); try expectEqual(out[1].appStoreURL?.absoluteString, "macappstore://apps.apple.com/app/id222")
    try expect(!out[1].installable && !out[1].isAppStoreUpdate, "up to date is not an update")
    try expectEqual(out[2].result, .noSource); try expectEqual(out[2].noSourceReason, .appStoreNotListed)
    try expectEqual(out.appStoreUpdates.count, 1)
    try expectEqual(AppStoreLinks.updatesPageURL.absoluteString, "macappstore://showUpdatesPage")
}
check("checker: App Store version comparison (newer, older installed from the future, equal)") {
    for (installed, store, expectUpdate) in [("1.9", "1.10", true), ("2.0", "2.0", false), ("3.0", "2.9", false), ("1.0b1", "1.0", true)] {
        let world = FakeFetcher([lookupKey(["com.acme.v"]): .success(storeResponse([storeJSON("com.acme.v", 1, store)]))])
        let out = await (try await makeChecker(world)).checkOne(app("V", id: "com.acme.v", short: installed, mas: true))
        if expectUpdate { try expect(out.isAppStoreUpdate, "\(installed) -> \(store) should be an update") }
        else { try expectEqual(out.result, .upToDate, "\(installed) vs \(store)") }
    }
}
check("checker: an iPhone/iPad listing never claims an update; only an exact version match is up to date") {
    // Mac 3.0 against iOS 8.0 (higher) and 2.0 (lower): neither is compared; both defer to the App Store.
    for (installed, store, upToDate) in [("3.0", "8.0", false), ("3.0", "2.0", false), ("1.0", "1.0.0", false), ("1.0-1", "1.0-2", false), ("26.43.75", "26.43.75", true)] {
        let world = FakeFetcher([lookupKey(["com.acme.ios"]): .success(storeResponse([storeJSON("com.acme.ios", 5, store, kind: "software")]))])
        let out = await (try await makeChecker(world)).checkOne(app("Ios", id: "com.acme.ios", short: installed, mas: true))
        try expect(!out.isAppStoreUpdate && !out.installable, "\(installed) vs iOS \(store) claimed an update")
        if upToDate { try expectEqual(out.result, .upToDate, "\(installed) vs \(store)") }
        else { try expectEqual(out.result, .noSource); try expectEqual(out.noSourceReason, .appStoreNotListed) }
    }
}
check("checker: App Store lookup failure is typed; catalogue ignore and source override; no network call without App Store apps") {
    let down = FakeFetcher([lookupKey(["com.acme.a"]): .failure(.transport("offline"))])
    let failed = await (try await makeChecker(down)).checkOne(app("A", id: "com.acme.a", mas: true))
    try expectEqual(failed.result.refusalCode, "network"); try expect(failed.source == nil && !failed.installable, "failed lookup state")
    let ignored = FakeFetcher()
    let cat = UserCatalogue(entries: ["com.acme.a": .ignore])
    _ = await (try await makeChecker(ignored, catalogue: cat)).check([app("A", id: "com.acme.a", mas: true)])
    try expect(ignored.requests.isEmpty, "ignored App Store app was looked up: \(ignored.requests)")
    let world = try fakeWorld()
    let override = UserCatalogue(entries: ["com.acme.a": .source(.homebrewCask(token: "example"))])
    let o = await (try await makeChecker(world, catalogue: override)).check([app("A", id: "com.acme.a", short: "0.1", mas: true)])
    try expectEqual(o[0].source, .homebrewCask(token: "example"))
    try expect(!world.requests.contains { $0.contains("itunes.apple.com") }, "catalogue override still queried the App Store")
    let plain = FakeFetcher()
    _ = await (try await makeChecker(plain)).check([app("P", id: "com.acme.p")])
    try expect(!plain.requests.contains { $0.contains("itunes.apple.com") }, "non-App-Store app sent to Apple")
}
check("checker: App Store with no installed version is refused, not guessed") {
    let world = FakeFetcher([lookupKey(["com.acme.a"]): .success(storeResponse([storeJSON("com.acme.a", 1, "2.0")]))])
    let out = await (try await makeChecker(world)).checkOne(app("A", id: "com.acme.a", short: nil, build: nil, mas: true))
    try expectEqual(out.result.refusalCode, "missing_installed_version")
}

// MARK: Sourceless classification and JSON

check("no-source classification: this app vs no public feed; reasons only on no_source rows") {
    let checker = try await makeChecker(FakeFetcher())
    let me = await checker.checkOne(app("Patched", id: "im.patched.app"))
    let other = await checker.checkOne(app("Bank Tool", id: "com.bank.tool"))
    try expectEqual(me.noSourceReason, .thisApp); try expectEqual(other.noSourceReason, .noPublicFeed)
    try expectEqual(NoSourceReason.thisApp.text, "this app"); try expectEqual(NoSourceReason.noPublicFeed.text, "no public update feed")
    let upToDate = await checker.checkOne(app("Example", id: "com.example.app"))
    try expect(upToDate.noSourceReason == nil, "reason leaked onto a sourced row")
}
check("JSON report: noSourceReason, appStoreURL and app_store_managed keys are stable") {
    let world = FakeFetcher([lookupKey(["com.acme.a"]): .success(storeResponse([storeJSON("com.acme.a", 42, "2.0")]))])
    let checker = try await makeChecker(world)
    let out = [await checker.checkOne(app("Patched", id: "im.patched.app")), await checker.checkOne(app("Bank", id: "com.bank.x")),
               await checker.checkOne(app("A", id: "com.acme.a", short: "1.0", mas: true))]
    let json = try JSONSerialization.jsonObject(with: try CheckReportRow.json(out)) as! [[String: Any]]
    let keys = Set(json[0].keys)
    for row in json { try expectEqual(Set(row.keys), keys, "same keys on every row") }
    try expectEqual(json[0]["noSourceReason"] as? String, "this_app"); try expectEqual(json[1]["noSourceReason"] as? String, "no_public_feed")
    try expectEqual(json[2]["status"] as? String, "update_available"); try expectEqual(json[2]["sourceKind"] as? String, "appstore")
    try expectEqual(json[2]["reason"] as? String, "app_store_managed"); try expectEqual(json[2]["reasonDetail"] as? String, "Update in the App Store")
    try expectEqual(json[2]["installable"] as? Bool, false)
    try expectEqual(json[2]["appStoreURL"] as? String, "macappstore://apps.apple.com/app/id42")
    try expect(json[2]["noSourceReason"] is NSNull && json[0]["appStoreURL"] is NSNull, "null expected")
}

// MARK: Review fixes

check("review 1: bundle-ID match is installable only with name affinity and strong/medium evidence") {
    // Elgato lists DisplayLink's receipt, but is not bound to the app by name.
    let elgato = hbMatch("DisplayLink Manager", "com.displaylink.displaylinkmanagerapp")
    try expect(elgato == nil || elgato?.lowConfidence == true, "elgato must not be a normal-confidence match: \(String(describing: elgato))")
    try expectEqual(elgato?.token, "elgato-camera-hub")
    // Business Pro lists com.microsoft.wdav as a package receipt; Defender is not part of its name.
    let wdav = hbMatch("Microsoft Defender", "com.microsoft.wdav")
    try expect(wdav == nil || wdav?.lowConfidence == true, "wdav must not be installable: \(String(describing: wdav))")
    try expectEqual(wdav?.token, "microsoft-office-businesspro")
    // A bare-bones app name that merely shares the vendor word is still low confidence.
    try expectEqual(hbMatch("Microsoft Thing", "com.microsoft.wdav")?.lowConfidence, true)
    // Bound by name with medium/strong evidence: normal confidence.
    try expectEqual(hbMatch("Microsoft Teams", "com.microsoft.teams2")?.lowConfidence, false)
    try expectEqual(hbMatch("Parallels Toolbox", "com.parallels.toolbox")?.lowConfidence, false)
    try expectEqual(hbMatch("UniFi Endpoint", "com.ui.uid.standard-desktop")?.lowConfidence, false)
    // Weak evidence stays low even with affinity.
    try expectEqual(hbMatch("Malwarebytes", "com.malwarebytes.mbam.frontend.application")?.lowConfidence, true)
}
check("review 5: glob and regex strings are patterns, never identities") {
    let cask = #"[{"token":"patterned","name":["Patterned"],"artifacts":[{"uninstall":[{"pkgutil":["com.acme.editor[0-9]*","com.acme.question?","com.acme.escaped\\.helper","com.acme.alt(a|b)","com.acme.plus+","com.acme.brace{1}","com.acme.caret^","com.acme.dollar$"],"quit":"com.acme.quitpat*"}]},{"zap":[{"trash":["~/Library/Preferences/com.acme.zap[1].plist"]}]}]}]"#
    let index = try CaskIndex(decoding: Data(cask.utf8))
    for id in ["com.acme.editor", "com.acme.question", "com.acme.escaped", "com.acme.alt", "com.acme.plus", "com.acme.brace", "com.acme.caret", "com.acme.dollar", "com.acme.quitpat", "com.acme.zap"] {
        try expect(index.bundleMatch(appName: "X.app", bundleID: id) == nil, "pattern fragment registered as identity \(id)")
    }
    // A plain literal in the same stanza still counts.
    let literal = try CaskIndex(decoding: Data(#"[{"token":"plain","artifacts":[{"uninstall":[{"pkgutil":["com.acme.plain"]}]}]}]"#.utf8))
    try expectEqual(literal.bundleMatch(appName: "X.app", bundleID: "com.acme.plain")?.token, "plain")
}
check("review 4: bundle ID syntax is whole-string; line separators are refused without a crash") {
    for bad in ["com.acme.app\u{2028}", "com.acme.app\u{2029}", "com.acme.app\n", "com.acme.app\u{85}", " com.acme.app", "com.acme.", "com"] {
        try expect(AppStoreResolver.lookupURL(bundleIDs: [bad], country: "gb") == nil, "accepted \(bad.unicodeScalars.map(\.value))")
    }
    let f = FakeFetcher()
    let out = await (try await makeChecker(f)).checkOne(app("Sep", id: "com.acme.app\u{2028}", mas: true))
    try expectEqual(out.result.refusalCode, "invalid_source"); try expect(f.requests.isEmpty, "bad bundle ID sent to Apple")
    let url = AppStoreResolver.lookupURL(bundleIDs: ["com.acme.a", "com.acme.b"], country: "gb")!
    try expect(url.absoluteString.contains("bundleId=com.acme.a,com.acme.b"), url.absoluteString)
    // A separator inside a cask's evidence string does not become an identity either.
    let index = try CaskIndex(decoding: Data("[{\"token\":\"sep\",\"artifacts\":[{\"uninstall\":[{\"quit\":\"com.acme.sep\\u2028\"}]}]}]".utf8))
    try expect(index.bundleCandidates(appName: "Sep.app", bundleID: "com.acme.sep\u{2028}", installedBundleIDs: []).first?.strength != .strong, "separator-suffixed quit target counted as strong")
}
check("review 6: trackId must be an exactly representable positive integer") {
    for bad in ["42.75", "-5", "0", "9007199254740993", "1e3", "99999999999999999999", "\"42\"", "42.0"] {
        let item = #"{"kind":"mac-software","bundleId":"com.acme.a","trackId":\#(bad),"version":"1","trackViewUrl":"https://apps.apple.com/x"}"#
        let r = try AppStoreResolver.parse(storeResponse([item]), requested: ["com.acme.a"]).get()
        try expect(r.records.isEmpty, "trackId \(bad) accepted: \(r.records)")
    }
    let ok = try AppStoreResolver.parse(storeResponse([storeJSON("com.acme.a", 9007199254740991, "1")]), requested: ["com.acme.a"]).get()
    try expectEqual(ok.records["com.acme.a"]?.trackID, 9007199254740991)
}
check("review 6: conflicting App Store listings refuse that app only") {
    let ids = ["com.acme.a", "com.acme.b"]
    let world = FakeFetcher([lookupKey(ids): .success(storeResponse([storeJSON("com.acme.a", 1, "2"), storeJSON("com.acme.a", 1, "3"), storeJSON("com.acme.b", 2, "2")]))])
    let out = await (try await makeChecker(world)).check([app("A", id: "com.acme.a", mas: true), app("B", id: "com.acme.b", short: "1.0", mas: true)])
    try expectEqual(out[0].result.refusalCode, "lookup_conflict"); try expect(out[1].isAppStoreUpdate, "other app unaffected")
}
check("review 2: App Store apps are never installable, even with a catalogue source override") {
    let world = try fakeWorld()
    let override = UserCatalogue(entries: ["com.acme.a": .source(.homebrewCask(token: "example"))])
    let out = await (try await makeChecker(world, catalogue: override)).check([app("A", id: "com.acme.a", short: "0.1", mas: true)])
    guard case .updateAvailable = out[0].result else { throw CheckFailure(description: "override not used for version display: \(out[0].result)") }
    try expect(!out[0].installable, "receipt-bearing app installable through an override")
    try expect(out[0].isAppStoreUpdate && out[0].managedByAppStore?.code == "app_store_managed", "not typed as App Store managed")
    let json = try JSONSerialization.jsonObject(with: CheckReportRow.json(out)) as! [[String: Any]]
    try expectEqual(json[0]["reason"] as? String, "app_store_managed"); try expectEqual(json[0]["installable"] as? Bool, false)
    // The same app without a receipt stays installable through that override.
    let plain = await (try await makeChecker(world, catalogue: override)).check([app("A", id: "com.acme.a", short: "0.1")])
    try expect(plain[0].installable, "non-receipt app lost installability")
}
check("review 3: catalogue ignore sends nothing from check, checkOne or explain") {
    let cat = UserCatalogue(entries: ["com.acme.a": .ignore])
    let f = FakeFetcher()
    let checker = try await makeChecker(f, catalogue: cat)
    let mas = app("A", id: "com.acme.a", mas: true)
    _ = await checker.check([mas])
    let one = await checker.checkOne(mas)
    let (explained, lines) = await checker.explain(mas)
    let plain = await checker.checkOne(app("A", id: "com.acme.a", sparkle: sparkleFeedURL))
    try expect(f.requests.isEmpty, "requests were made for an ignored app: \(f.requests)")
    try expectEqual(one.noSourceReason, .ignored); try expectEqual(explained.noSourceReason, .ignored)
    try expectEqual(plain.noSourceReason, .ignored)
    try expect(lines.joined().contains("ignored"), "explain should say so")
}
check("wrapped iPhone/iPad app: the iOS listing is compared normally, is App Store owned and never installable") {
    // WiFiman 1.37.1 installed; the iOS listing is the one the App Store updates it from.
    for (store, want) in [("1.38.0", "update"), ("1.37.1", "same"), ("1.36.0", "same")] {
        let world = FakeFetcher([lookupKey(["com.ubnt.wifiman"]): .success(storeResponse([storeJSON("com.ubnt.wifiman", 1385561119, store, kind: "software")]))])
        let out = await (try await makeChecker(world)).checkOne(app("WiFiman", id: "com.ubnt.wifiman", short: "1.37.1", build: "202605136", wrapped: true))
        try expect(out.app.isAppStore && out.app.isWrappedIOSApp, "wrapped app is not App Store owned")
        try expect(!out.installable, "a wrapped iOS app became installable")
        if want == "update" {
            try expect(out.isAppStoreUpdate && out.source == .appStore(trackID: 1385561119), "no update for iOS \(store): \(out.result)")
            try expectEqual(out.appStoreURL?.absoluteString, "macappstore://apps.apple.com/app/id1385561119")
        } else { try expectEqual(out.result, .upToDate, "iOS \(store)") }
    }
    // The same listing against a non-wrapped Mac app keeps the exact-match rule, and keeps the track ID for a click.
    let world = FakeFetcher([lookupKey(["com.ubnt.wifiman"]): .success(storeResponse([storeJSON("com.ubnt.wifiman", 1385561119, "1.38.0", kind: "software")]))])
    let plain = await (try await makeChecker(world)).checkOne(app("WiFiman", id: "com.ubnt.wifiman", short: "1.37.1", mas: true))
    try expectEqual(plain.result, .noSource); try expectEqual(plain.noSourceReason, .appStoreNotListed)
    try expectEqual(plain.appStoreTrackID, 1385561119); try expect(plain.source == nil, "source kept")
    try expectEqual(plain.appStoreURL?.absoluteString, "macappstore://apps.apple.com/app/id1385561119")
    // Nothing found at all: no track ID.
    let none = await (try await makeChecker(FakeFetcher([lookupKey(["com.ubnt.wifiman"]): .success(storeResponse([]))]))).checkOne(app("W", id: "com.ubnt.wifiman", mas: true))
    try expect(none.appStoreTrackID == nil && none.appStoreURL == nil, "track ID invented")
}
check("catalogue ignore with includeIgnored: an outcome per ignored app and still no request") {
    let cat = UserCatalogue(entries: ["com.acme.a": .ignore])
    let f = FakeFetcher()
    let checker = try await makeChecker(f, catalogue: cat)
    let out = await checker.check([app("A", id: "com.acme.a", mas: true), app("Z", id: "com.acme.z", sparkle: nil)], includeIgnored: true)
    try expectEqual(out.map(\.app.name), ["A", "Z"])
    try expectEqual(out[0].noSourceReason, .ignored)
    try expect(!f.requests.contains { $0.contains("com.acme.a") }, "ignored app was looked up: \(f.requests)")
    try expectEqual(await checker.check([app("A", id: "com.acme.a", mas: true)]).count, 0)
}

// MARK: Editing the catalogue's ignore entries

func editFolder() throws -> URL {
    let dir = testTemporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
let mixedCatalogue = #"{"version":1,"apps":[{"bundleID":"com.keep.cask","source":{"homebrewCask":"example"}},{"bundleID":"com.keep.feed","source":{"sparkle":"https://updates.example.test/a.xml"}},{"bundleID":"com.keep.ignored","ignore":true}]}"#
func mode(_ url: URL) -> Int { Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue ?? -1) & 0o777 }

check("catalogue edit: ignoring writes exactly one entry and keeps every other entry; Stop ignoring removes only it") {
    let dir = try editFolder(), file = dir.appendingPathComponent("catalogue.json")
    try Data(mixedCatalogue.utf8).write(to: file)
    let before = try UserCatalogue.load(from: file)
    try expectEqual(try UserCatalogue.setIgnored(true, bundleID: "com.new.app", at: file), .added)
    let after = try UserCatalogue.load(from: file)
    var expected = before.entries; expected["com.new.app"] = .ignore
    try expectEqual(after.entries, expected, "entries after ignoring")
    try expectEqual(after.entries.count, before.entries.count + 1)
    try expectEqual(mode(file), 0o600, "mode")
    try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["catalogue.json", "catalogue.json.lock"], "temporary files left behind")
    // Already ignored: nothing changes, not even the bytes.
    let bytes = try Data(contentsOf: file)
    try expectEqual(try UserCatalogue.setIgnored(true, bundleID: "com.new.app", at: file), .unchanged)
    try expectEqual(try Data(contentsOf: file), bytes)
    try expectEqual(try UserCatalogue.setIgnored(false, bundleID: "com.new.app", at: file), .removed)
    try expectEqual(try UserCatalogue.load(from: file).entries, before.entries, "stop ignoring changed other entries")
    try expectEqual(try UserCatalogue.setIgnored(false, bundleID: "com.keep.ignored", at: file), .removed)
    var minusOne = before.entries; minusOne["com.keep.ignored"] = nil
    try expectEqual(try UserCatalogue.load(from: file).entries, minusOne, "removed more than the one entry")
    try expectEqual(try UserCatalogue.setIgnored(false, bundleID: "com.never.there", at: file), .unchanged)
}
check("catalogue edit: a missing catalogue is created 0600, and Stop ignoring does not create one") {
    let dir = try editFolder().appendingPathComponent("Updater"), file = dir.appendingPathComponent("catalogue.json")
    try expectEqual(try UserCatalogue.setIgnored(false, bundleID: "com.a.b", at: file), .unchanged)
    try expect(!FileManager.default.fileExists(atPath: dir.path), "Stop ignoring created a folder")
    try expectEqual(try UserCatalogue.setIgnored(true, bundleID: "com.a.b", at: file), .added)
    try expectEqual(try UserCatalogue.load(from: file).entries, ["com.a.b": .ignore])
    try expectEqual(mode(file), 0o600, "mode")
}
check("catalogue edit: an unparseable or odd catalogue is refused and left byte-for-byte unchanged") {
    let dir = try editFolder()
    let bad: [(String, String)] = [("not-json", "{nope"), ("array", "[]"), ("bad-version", #"{"version":2,"apps":[]}"#),
        ("unknown-key", #"{"version":1,"apps":[{"bundleID":"a.b","ignore":true,"colour":"red"}]}"#),
        ("dup", #"{"version":1,"apps":[{"bundleID":"a.b","ignore":true},{"bundleID":"a.b","ignore":true}]}"#)]
    for (name, text) in bad {
        let file = dir.appendingPathComponent("\(name).json")
        try Data(text.utf8).write(to: file)
        for ignored in [true, false] {
            do { _ = try UserCatalogue.setIgnored(ignored, bundleID: "com.new.app", at: file); throw CheckFailure(description: "\(name) accepted") }
            catch is CatalogueError {}
            try expectEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), text, "\(name) was modified")
        }
    }
    // An app with a source entry is not overwritten either way.
    let file = dir.appendingPathComponent("source.json")
    try Data(mixedCatalogue.utf8).write(to: file)
    for ignored in [true, false] {
        do { _ = try UserCatalogue.setIgnored(ignored, bundleID: "com.keep.cask", at: file); throw CheckFailure(description: "source entry replaced") }
        catch is CatalogueError {}
    }
    try expectEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), mixedCatalogue)
    do { _ = try UserCatalogue.setIgnored(true, bundleID: "", at: file); throw CheckFailure(description: "empty bundle ID") } catch is CatalogueError {}
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
    try expect(leftovers.isEmpty, "temporary files: \(leftovers)")
}
final class Log: @unchecked Sendable {
    private let lock = NSLock(); private var _items: [String] = []
    func add(_ s: String) { lock.withLock { _items.append(s) } }
    var items: [String] { lock.withLock { _items } }
}
func leftovers(_ dir: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".catalogue-") } }

check("catalogue edit: a second edit while one is in progress is refused, and the first still lands intact") {
    let dir = try editFolder(), file = dir.appendingPathComponent("catalogue.json")
    try Data(mixedCatalogue.utf8).write(to: file)
    let second = Log()
    var hooks = CatalogueEditHooks()
    hooks.afterRead = {
        do { _ = try UserCatalogue.setIgnored(true, bundleID: "com.second.app", at: file); second.add("accepted") }
        catch let error as CatalogueError { second.add("refused: \(error.message)") } catch { second.add("other") }
    }
    try expectEqual(try UserCatalogue.setIgnored(true, bundleID: "com.first.app", at: file, hooks: hooks), .added)
    try expect(second.items.count == 1 && second.items[0].hasPrefix("refused: catalogue.json is being edited"), "second edit: \(second.items)")
    let entries = try UserCatalogue.load(from: file).entries
    try expect(entries["com.first.app"] == .ignore && entries["com.second.app"] == nil && entries.count == 4, "entries: \(entries.keys.sorted())")
    // The lock is released afterwards.
    try expectEqual(try UserCatalogue.setIgnored(true, bundleID: "com.second.app", at: file), .added)
}
check("catalogue edit: a change to the file between the read and the commit is refused and the file keeps the other change") {
    let dir = try editFolder(), file = dir.appendingPathComponent("catalogue.json")
    try Data(mixedCatalogue.utf8).write(to: file)
    let manual = #"{"version":1,"apps":[{"bundleID":"com.owner.added","ignore":true}]}"#
    var hooks = CatalogueEditHooks()
    hooks.afterRead = { try? Data(manual.utf8).write(to: file) }
    do { _ = try UserCatalogue.setIgnored(true, bundleID: "com.first.app", at: file, hooks: hooks); throw CheckFailure(description: "overwrote a changed file") }
    catch let error as CatalogueError { try expect(error.message.contains("changed while"), "message: \(error.message)") }
    try expectEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), manual)
    try expect(try leftovers(dir).isEmpty, "temporary files: \(try leftovers(dir))")
    // The file appearing where there was none is refused as well.
    let fresh = dir.appendingPathComponent("fresh.json")
    var appear = CatalogueEditHooks()
    appear.afterRead = { try? Data(manual.utf8).write(to: fresh) }
    do { _ = try UserCatalogue.setIgnored(true, bundleID: "com.first.app", at: fresh, hooks: appear); throw CheckFailure(description: "overwrote a new file") } catch is CatalogueError {}
    try expectEqual(String(decoding: try Data(contentsOf: fresh), as: UTF8.self), manual)
}
check("catalogue edit: a parent folder swapped for another during the edit is refused and nothing is written to either") {
    let base = try editFolder(), dir = base.appendingPathComponent("Updater"), moved = base.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("catalogue.json")
    try Data(mixedCatalogue.utf8).write(to: file)
    var hooks = CatalogueEditHooks()
    hooks.afterRead = { try? FileManager.default.moveItem(at: dir, to: moved); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    do { _ = try UserCatalogue.setIgnored(true, bundleID: "com.new.app", at: file, hooks: hooks); throw CheckFailure(description: "edit went ahead") } catch is CatalogueError {}
    try expectEqual(String(decoding: try Data(contentsOf: moved.appendingPathComponent("catalogue.json")), as: UTF8.self), mixedCatalogue)
    try expect(!FileManager.default.fileExists(atPath: file.path), "wrote into the replacement folder")
    try expect(try leftovers(dir).isEmpty && leftovers(moved).isEmpty, "temporary files")
}
check("catalogue edit: the new file is created 0600, written and synced, renamed, then the folder is synced; failures leave no temporary file") {
    let dir = try editFolder(), file = dir.appendingPathComponent("catalogue.json")
    try Data(mixedCatalogue.utf8).write(to: file)
    let log = Log()
    var hooks = CatalogueEditHooks()
    hooks.event = { log.add($0) }
    hooks.tempMode = { log.add("mode \(String($0, radix: 8))") }
    try expectEqual(try UserCatalogue.setIgnored(true, bundleID: "com.new.app", at: file, hooks: hooks), .added)
    try expectEqual(log.items, ["lock", "read", "reread", "create", "mode 600", "write", "fsync-file", "rename", "fsync-dir"])
    try expect(try leftovers(dir).isEmpty, "temporary files remain")
    // A failed folder sync is an error, not silent success.
    var noSync = CatalogueEditHooks(); noSync.fail = { $0 == "fsync-dir" }
    do { _ = try UserCatalogue.setIgnored(true, bundleID: "com.other.app", at: file, hooks: noSync); throw CheckFailure(description: "sync failure ignored") }
    catch let error as CatalogueError { try expect(error.message.contains("could not be synced"), "message: \(error.message)") }
    // Injected failures at each step leave the catalogue as it was and no temporary file.
    for step in ["write", "fsync-file", "rename"] {
        let before = try Data(contentsOf: file)
        var broken = CatalogueEditHooks(); broken.fail = { $0 == step }
        do { _ = try UserCatalogue.setIgnored(true, bundleID: "com.fail.\(step)", at: file, hooks: broken); throw CheckFailure(description: "\(step) failure ignored") } catch is CatalogueError {}
        try expectEqual(try Data(contentsOf: file), before, "\(step): file changed")
        try expect(try leftovers(dir).isEmpty, "\(step): temporary files \(try leftovers(dir))")
    }
}
check("catalogue edit: a symlinked catalogue is refused and its target is untouched; a symlinked folder is refused") {
    let dir = try editFolder()
    let target = dir.appendingPathComponent("target.json"), link = dir.appendingPathComponent("catalogue.json")
    try Data(mixedCatalogue.utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    do { _ = try UserCatalogue.setIgnored(true, bundleID: "com.new.app", at: link); throw CheckFailure(description: "symlink followed") } catch is CatalogueError {}
    try expectEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), mixedCatalogue)
    let real = dir.appendingPathComponent("real", isDirectory: true), folderLink = dir.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: real)
    do { _ = try UserCatalogue.setIgnored(true, bundleID: "com.new.app", at: folderLink.appendingPathComponent("catalogue.json")); throw CheckFailure(description: "folder symlink used") } catch is CatalogueError {}
    try expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty, "wrote through a symlinked folder")
}
check("review 8: lookup passes the response cap on every request") {
    let f = FakeFetcher([lookupKey(["com.acme.a"]): .success(storeResponse([]))])
    _ = await AppStoreResolver.lookup(bundleIDs: ["com.acme.a"], country: "gb", fetcher: f)
    try expectEqual(f.maxBytesSeen, [AppStoreResolver.maxResponseBytes])
}

extension Optional {
    func unwrapChecked() throws -> Wrapped { guard let self else { throw CheckFailure(description: "unexpected nil") }; return self }
}

// MARK: Patched's own release (notify-only)

final class ReleaseFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Data, FetchError>
    private var _requests: [(url: String, max: Int, accept: String?, agent: String?)] = []
    private var _redirects: [Set<String>?] = []
    var redirectHosts: [Set<String>?] { lock.withLock { _redirects } }
    init(_ result: Result<Data, FetchError>) { self.result = result }
    var requests: [(url: String, max: Int, accept: String?, agent: String?)] { lock.withLock { _requests } }
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data { try await fetch(url, maxBytes: maxBytes, accept: nil, userAgent: nil, allowedRedirectHosts: nil) }
    func fetch(_ url: URL, maxBytes: Int, accept: String?, userAgent: String?, allowedRedirectHosts: Set<String>?) async throws -> Data {
        lock.withLock { _requests.append((url.absoluteString, maxBytes, accept, userAgent)); _redirects.append(allowedRedirectHosts) }
        return try result.get()
    }
}
func releaseJSON(tag: String = "v0.2.0", url: String? = nil, draft: Bool = false, prerelease: Bool = false, extra: String = "") -> Data {
    let page = url ?? "https://github.com/birdseeed/patched/releases/tag/\(tag)"
    return Data(#"{"tag_name":"\#(tag)","html_url":"\#(page)","draft":\#(draft),"prerelease":\#(prerelease)\#(extra)}"#.utf8)
}
let releasePage = URL(string: "https://github.com/birdseeed/patched/releases/tag/v0.2.0")!

check("self release: newer, equal and older than the running version") {
    try expectEqual(PatchedReleaseChecker.evaluate(releaseJSON(), currentVersion: "0.1.0"),
                    .newer(PatchedRelease(version: "0.2.0", pageURL: releasePage)))
    try expectEqual(PatchedReleaseChecker.evaluate(releaseJSON(), currentVersion: "0.2.0"), .noNews)
    try expectEqual(PatchedReleaseChecker.evaluate(releaseJSON(), currentVersion: "0.3.0"), .noNews)
    try expectEqual(PatchedReleaseChecker.evaluate(releaseJSON(tag: "v0.10.0"), currentVersion: "0.9.0"),
                    .newer(PatchedRelease(version: "0.10.0", pageURL: URL(string: "https://github.com/birdseeed/patched/releases/tag/v0.10.0")!)))
}
check("self release: v-prefixed and plain tags, and nothing else, are accepted") {
    let plain = PatchedReleaseChecker.parse(releaseJSON(tag: "0.2.0"))
    try expectEqual(plain, PatchedRelease(version: "0.2.0", pageURL: URL(string: "https://github.com/birdseeed/patched/releases/tag/0.2.0")!))
    try expectEqual(PatchedReleaseChecker.parse(releaseJSON(tag: "v0.2.0")), PatchedRelease(version: "0.2.0", pageURL: releasePage))
    for bad in ["V0.2.0", "vv0.2.0", "0.2.0-beta", "v0.2.0rc1", "0.2.", ".2", "v", "", "0..2", "1.0 ", "v1.0\n", "latest", "../0.2.0"] {
        try expect(PatchedReleaseChecker.parse(releaseJSON(tag: bad)) == nil, "accepted tag \(bad.debugDescription)")
    }
}
check("self release: draft and prerelease releases are ignored, and the flags must be present booleans") {
    try expect(PatchedReleaseChecker.parse(releaseJSON(draft: true)) == nil, "draft accepted")
    try expect(PatchedReleaseChecker.parse(releaseJSON(prerelease: true)) == nil, "prerelease accepted")
    try expectEqual(PatchedReleaseChecker.evaluate(releaseJSON(draft: true), currentVersion: "0.1.0"), .noNews)
    try expectEqual(PatchedReleaseChecker.evaluate(releaseJSON(prerelease: true), currentVersion: "0.1.0"), .noNews)
    let missing = Data(#"{"tag_name":"v0.2.0","html_url":"https://github.com/birdseeed/patched/releases/tag/v0.2.0"}"#.utf8)
    try expect(PatchedReleaseChecker.parse(missing) == nil, "missing flags accepted")
    let strings = Data(#"{"tag_name":"v0.2.0","html_url":"https://github.com/birdseeed/patched/releases/tag/v0.2.0","draft":"false","prerelease":"false"}"#.utf8)
    try expect(PatchedReleaseChecker.parse(strings) == nil, "string flags accepted")
}
check("self release: html_url on another host, path, tag or scheme is ignored") {
    let base = "https://github.com/birdseeed/patched/releases/tag/"
    let bad = ["https://evil.example/birdseeed/patched/releases/tag/v0.2.0", "https://github.com.evil.example/birdseeed/patched/releases/tag/v0.2.0",
               "https://github.com/someone/patched/releases/tag/v0.2.0", "https://github.com/birdseeed/other/releases/tag/v0.2.0",
               base + "v0.3.0", base + "0.2.0", base + "v0.2.0/", base + "v0.2.0?x=1", base + "v0.2.0#frag",
               "http://github.com/birdseeed/patched/releases/tag/v0.2.0", "https://github.com/birdseeed/patched/releases/download/v0.2.0/Patched.zip",
               "https://github.com/birdseeed/patched/releases/latest", "https://api.github.com/repos/birdseeed/patched/releases/1",
               "https://github.com:444/birdseeed/patched/releases/tag/v0.2.0", "https://user@github.com/birdseeed/patched/releases/tag/v0.2.0", ""]
    for url in bad { try expect(PatchedReleaseChecker.parse(releaseJSON(url: url)) == nil, "accepted html_url \(url)") }
    try expect(PatchedReleaseChecker.parse(releaseJSON(url: base + "v0.2.0")) != nil, "the exact page was refused")
}
check("self release: only tag_name, html_url, draft and prerelease are used (assets are never read)") {
    let withAssets = releaseJSON(extra: #","assets":[{"browser_download_url":"https://evil.example/Patched.zip"}],"zipball_url":"https://evil.example/z","body":"x","name":"Evil""#)
    let release = try PatchedReleaseChecker.parse(withAssets).unwrapChecked()
    try expectEqual(release, PatchedRelease(version: "0.2.0", pageURL: releasePage))
    let mirror = Mirror(reflecting: release).children.map { $0.label ?? "" }.sorted()
    try expectEqual(mirror, ["pageURL", "version"])
}
check("self release: malformed JSON, wrong shapes and oversized responses are silent") {
    for body in ["", "not json", "[]", "null", "{}", #"{"tag_name":5,"html_url":"x","draft":false,"prerelease":false}"#, "{\"tag_name\":\"v9.9.9\""] {
        try expectEqual(PatchedReleaseChecker.evaluate(Data(body.utf8), currentVersion: "0.1.0"), .noNews, body)
        let fetcher = ReleaseFetcher(.success(Data(body.utf8)))
        try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: fetcher), .noNews, "fetched \(body)")
    }
    let huge = releaseJSON(extra: #","body":""# + String(repeating: "a", count: FetchLimits.releaseBytes) + "\"")
    try expect(huge.count > FetchLimits.releaseBytes, "fixture not oversized")
    try expect(PatchedReleaseChecker.parse(huge) == nil, "oversized record parsed")
    try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: ReleaseFetcher(.success(huge))), .noNews)
    try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: ReleaseFetcher(.failure(.tooLarge))), .unavailable)
}
check("self release: 404 (no release yet) is no news; a network failure is unavailable") {
    try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: ReleaseFetcher(.failure(.http(404)))), .noNews)
    try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: ReleaseFetcher(.failure(.http(500)))), .unavailable)
    // Rate limiting and refusals say nothing about whether there is news: they must not clear what was known.
    for code in [400, 401, 403, 410, 429] {
        try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: ReleaseFetcher(.failure(.http(code)))), .unavailable, "HTTP \(code)")
    }
    try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: ReleaseFetcher(.failure(.insecureRedirect("https://evil.example/")))), .unavailable)
    try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: ReleaseFetcher(.failure(.transport("offline")))), .unavailable)
}
check("self release: one anonymous request with only Accept and a plain User-Agent") {
    let fetcher = ReleaseFetcher(.success(releaseJSON()))
    let result = await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: fetcher)
    try expectEqual(result, .newer(PatchedRelease(version: "0.2.0", pageURL: releasePage)))
    try expectEqual(fetcher.requests.count, 1, "requests")
    let request = fetcher.requests[0]
    try expectEqual(request.url, "https://api.github.com/repos/birdseeed/patched/releases/latest")
    try expectEqual(request.accept, "application/vnd.github+json")
    try expectEqual(request.agent, "Patched/0.1.0")
    try expectEqual(request.max, 256 * 1024, "cap")
    try expectEqual(fetcher.redirectHosts.first ?? nil, ["api.github.com"], "redirects must stay on the API host")
    try expect(PatchedReleaseChecker.apiURL.scheme == "https", "not https")
}

// MARK: Real fetcher, through a stub URLProtocol (no network)

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data))?
    private static let lock = NSLock()
    static func reset(_ h: @escaping @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)) {
        lock.withLock { seen = []; handler = h }
    }
    static var requests: [URLRequest] { lock.withLock { seen } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (handler, _) = Self.lock.withLock { () -> ((@Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data))?, Int) in
            Self.seen.append(request); return (Self.handler, 0) }
        guard let handler, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let r = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        if (300..<400).contains(r.status), let location = r.headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func stubFetcher() -> URLSessionFetcher {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSessionFetcher(configuration: configuration)
}

check("self release: the real fetcher sends Accept and a plain User-Agent, and nothing else identifying") {
    StubProtocol.reset { _ in (200, [:], releaseJSON()) }
    let result = await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: stubFetcher())
    try expectEqual(result, .newer(PatchedRelease(version: "0.2.0", pageURL: releasePage)))
    let requests = StubProtocol.requests
    try expectEqual(requests.count, 1, "requests")
    let request = requests[0]
    try expectEqual(request.url?.absoluteString, "https://api.github.com/repos/birdseeed/patched/releases/latest")
    try expectEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    try expectEqual(request.value(forHTTPHeaderField: "User-Agent"), "Patched/0.1.0")
    try expectEqual(request.httpMethod, "GET")
    try expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil, "extra identifying headers")
}
check("self release: the real fetcher refuses a redirect off api.github.com, and follows one within it") {
    StubProtocol.reset { request in
        if request.url?.host == "api.github.com", request.url?.path.hasSuffix("/latest") == true {
            return (302, ["Location": "https://evil.example/steal"], Data())
        }
        return (200, [:], releaseJSON())
    }
    try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: stubFetcher()), .unavailable)
    try expect(!StubProtocol.requests.contains { $0.url?.host == "evil.example" }, "followed the redirect: \(StubProtocol.requests.map { $0.url?.absoluteString ?? "" })")
    // Within api.github.com it is followed; elsewhere on the old behaviour (any https host) is unchanged.
    StubProtocol.reset { request in
        request.url?.path.hasSuffix("/latest") == true ? (302, ["Location": "https://api.github.com/repos/birdseeed/patched/releases/1"], Data()) : (200, [:], releaseJSON())
    }
    try expectEqual(await PatchedReleaseChecker.check(currentVersion: "0.1.0", fetcher: stubFetcher()), .newer(PatchedRelease(version: "0.2.0", pageURL: releasePage)))
    StubProtocol.reset { request in
        request.url?.host == "feed.example" ? (302, ["Location": "https://cdn.example/x"], Data()) : (200, [:], Data("ok".utf8))
    }
    let data = try await stubFetcher().fetch(URL(string: "https://feed.example/a")!, maxBytes: 100)
    try expectEqual(String(decoding: data, as: UTF8.self), "ok", "ordinary fetches still follow https redirects")
    try expectEqual(HTTPSRedirectPolicy.decide(URLRequest(url: URL(string: "http://api.github.com/x")!), allowedHosts: ["api.github.com"]) == nil, true, "http redirect")
}

// MARK: Runner

var failures = 0
for (name, action) in cases {
    do { try await action(); print("PASS update-sources: \(name)") }
    catch { failures += 1; print("FAIL update-sources: \(name): \(error)") }
}
print("update-sources checks: \(cases.count) cases, \(failures) failures")
exit(failures == 0 ? 0 : 1)
