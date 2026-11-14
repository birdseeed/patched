import Foundation
@_spi(Testing) import UpdateSources

// macOS updates: Apple's public feed and the Software Update plist, from fixtures only. The device IDs are made
// up; no real feed, plist or sysctl is read here.

/// Records each request (URL, cap, User-Agent, redirect hosts) and answers from a table.
final class MacFeedFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Result<Data, FetchError>
    private var _seen: [(url: String, maxBytes: Int, userAgent: String?, hosts: Set<String>?)] = []
    init(_ answer: Result<Data, FetchError>) { self.answer = answer }
    var seen: [(url: String, maxBytes: Int, userAgent: String?, hosts: Set<String>?)] { lock.withLock { _seen } }
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        try await fetch(url, maxBytes: maxBytes, accept: nil, userAgent: nil, allowedRedirectHosts: nil)
    }
    func fetch(_ url: URL, maxBytes: Int, accept: String?, userAgent: String?, allowedRedirectHosts: Set<String>?) async throws -> Data {
        lock.withLock { _seen.append((url.absoluteString, maxBytes, userAgent, allowedRedirectHosts)) }
        let data = try answer.get()
        if data.count > maxBytes { throw FetchError.tooLarge }
        return data
    }
}

func registerMacOSUpdateChecks() {
    func host(_ version: String, _ device: String?) -> MacOSHost { MacOSHost(runningVersion: MacOSVersion(version)!, deviceID: device) }
    func status(_ result: MacOSUpdateResult) throws -> MacOSUpdateStatus {
        guard case .found(let status) = result else { throw CheckFailure(description: "expected a result, got \(result)") }
        return status
    }
    func plistPath(_ name: String) -> String { fixtureRoot.appendingPathComponent(name).path }
    let missingPlist = testTemporaryDirectory.appendingPathComponent("no-such-softwareupdate.plist").path

    check("macOS version: numeric by component, strict text") {
        let table: [(String, String, Bool)] = [("27.2.1", "27.0.1", true), ("27.10", "27.9", true), ("27.2", "27.2.0", false),
                                               ("28.0", "27.9.9", true), ("9.9", "10.0", false), ("27.0.1", "27.0.1", false)]
        for (a, b, newer) in table {
            try expect((MacOSVersion(a)! > MacOSVersion(b)!) == newer, "\(a) > \(b) should be \(newer)")
        }
        try expect(MacOSVersion("27.2") == MacOSVersion("27.2.0"), "27.2 and 27.2.0 differ")
        for bad in ["", "27.", ".1", "27.2 beta", "v27", "27..1", "27..2", "27.2.", "27.2.1abc", "1.2.3.4.5", "27.2.1\n", "1234567"] {
            try expect(MacOSVersion(bad) == nil, "accepted \(bad.debugDescription)")
        }
        // A leading zero is accepted and normalised: "027.2" is 27.2, shown as "27.2".
        let padded = try MacOSVersion("027.2").unwrap()
        try expect(padded == MacOSVersion("27.2")! && padded.description == "27.2", "027.2: \(padded.description)")
        try expect(MacOSVersion("1.2.3.4") != nil, "four parts refused")
        try expectEqual(MacOSVersion(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)).description, "27.0.1")
        try expectEqual(MacOSVersion(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)).description, "27.2")
    }

    check("macOS feed: only PublicAssetSets.macOS is read, and bad entries are dropped one by one") {
        let entries = try MacOSFeed.parse(fixture("gdmf-pmv.json")).unwrap()
        // 14 well-formed-looking items: wrong types, a missing field, a bad date, a beta, a non-string device and a
        // string item are all dropped; the iOS, AssetSets and Background Security Improvements entries never count.
        // A missing ExpirationDate keeps the entry (27.3); a malformed one drops it (27.3.1).
        try expectEqual(entries.map(\.version.description), ["14.8.9", "27.2.1", "26.7.3", "27.2.1", "15.8.3", "27.1", "27.2.1", "28.0", "27.3"])
        try expect(!entries.contains { ["26Z1", "26A434a", "30A1"].contains($0.build) }, "read outside PublicAssetSets.macOS")
    }

    check("macOS feed: a supported device gets the newest minor in its major, with this device's build") {
        let entries = try MacOSFeed.parse(fixture("gdmf-pmv.json")).unwrap()
        let picked = MacOSFeed.select(entries, running: MacOSVersion("27.0.1")!, deviceID: "J999AP")
        try expectEqual(picked.minor, MacOSUpdate(kind: .minor, version: "27.2.1", build: "26B131", postingDate: "2026-11-09", source: .appleFeed))
        try expect(picked.major == nil, "major: \(String(describing: picked.major))")
        // The same version listed three times: each device gets its own build.
        try expectEqual(MacOSFeed.select(entries, running: MacOSVersion("27.0.1")!, deviceID: "J888AP").minor?.build, "26B7131")
        try expectEqual(MacOSFeed.select(entries, running: MacOSVersion("27.0.1")!, deviceID: "J777AP").minor?.build, "26B8132")
        // Older majors (26.7.3, 15.8.3) list this device but are never offered.
        let older = MacOSFeed.select(entries, running: MacOSVersion("27.2.1")!, deviceID: "J999AP")
        try expect(older.minor == nil && older.major == nil, "up to date offered \(older)")
        // A Mac on 26 sees 26.7.3 as its update and 27.2.1 as the new major.
        let on26 = MacOSFeed.select(entries, running: MacOSVersion("26.5")!, deviceID: "J999AP")
        try expect(on26.minor?.version == "26.7.3" && on26.major?.version == "27.2.1" && on26.major?.kind == .major, "on 26: \(on26)")
    }

    check("macOS feed: an unsupported device is never offered a version") {
        let entries = try MacOSFeed.parse(fixture("gdmf-pmv.json")).unwrap()
        let none = MacOSFeed.select(entries, running: MacOSVersion("27.0.1")!, deviceID: "J000AP")
        try expect(none.minor == nil && none.major == nil, "unsupported: \(none)")
        // 28.0 is listed only for J777AP.
        try expect(MacOSFeed.select(entries, running: MacOSVersion("27.0.1")!, deviceID: "J999AP").major == nil, "28.0 offered to J999AP")
        try expectEqual(MacOSFeed.select(entries, running: MacOSVersion("27.0.1")!, deviceID: "J777AP").major?.version, "28.0")
    }

    check("macOS feed: several majors give the newest higher major only, never as a minor") {
        let entries = try MacOSFeed.parse(fixture("gdmf-pmv-majors.json")).unwrap()
        let picked = MacOSFeed.select(entries, running: MacOSVersion("27.0.1")!, deviceID: "J999AP")
        try expect(picked.minor == nil, "minor: \(String(describing: picked.minor))")
        try expectEqual(picked.major, MacOSUpdate(kind: .major, version: "28.1", build: "27B10", postingDate: "2026-11-12", source: .appleFeed))
        try expectEqual(picked.major?.majorVersion, 28)
        // 29.0 is for another device.
        try expect(MacOSFeed.select(entries, running: MacOSVersion("28.1")!, deviceID: "J999AP").major == nil, "29 offered")
    }

    check("macOS feed: malformed top levels are unusable") {
        for bad in ["", "[]", "{}", #"{"PublicAssetSets": []}"#, #"{"PublicAssetSets": {"macOS": {}}}"#,
                    #"{"PublicAssetSets": {"iOS": []}}"#, #"{"AssetSets": {"macOS": []}}"#, "not json"] {
            try expect(MacOSFeed.parse(Data(bad.utf8)) == nil, "parsed \(bad)")
        }
        try expectEqual(MacOSFeed.parse(Data(#"{"PublicAssetSets": {"macOS": []}}"#.utf8)), [])
        let huge = Data((#"{"PublicAssetSets": {"macOS": []}, "pad": ""# + String(repeating: "a", count: FetchLimits.macOSFeedBytes) + "\"}").utf8)
        try expect(huge.count > FetchLimits.macOSFeedBytes && MacOSFeed.parse(huge) == nil, "oversized feed parsed")
    }

    check("Software Update plist: macOS entries only, with the build and last check") {
        let plist = try SoftwareUpdatePlist.read(at: plistPath("softwareupdate-recommended.plist")).unwrap()
        try expectEqual(plist.recommended, [SoftwareUpdatePlist.Recommended(version: MacOSVersion("27.2.1")!, build: "26B131")])
        try expectEqual(plist.lastSuccessfulDate, ISO8601DateFormatter().date(from: "2026-11-14T13:43:37Z"))
        let picked = plist.select(running: MacOSVersion("27.0.1")!)
        try expectEqual(picked.minor, MacOSUpdate(kind: .minor, version: "27.2.1", build: "26B131", source: .softwareUpdate))
        try expect(picked.major == nil, "Safari or Command Line Tools counted as macOS")
        try expect(plist.select(running: MacOSVersion("27.2.1")!).minor == nil, "up to date offered")
        try expect(SoftwareUpdatePlist.read(at: missingPlist) == nil, "missing plist read")
        try expect(SoftwareUpdatePlist.parse(Data("not a plist".utf8)) == nil, "garbage parsed")
        let array = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .xml, options: 0)
        try expect(SoftwareUpdatePlist.parse(array) == nil, "array plist parsed")
        // A macOS major found by Software Update is a major.
        let major = try PropertyListSerialization.data(fromPropertyList: ["RecommendedUpdates": [
            ["Display Version": "28.0", "Product Key": "MSU_UPDATE_27A100_patch_28.0_major"],
            ["Display Version": 27.3, "MobileSoftwareUpdate": true]]], format: .binary, options: 0)
        let parsed = try SoftwareUpdatePlist.parse(major).unwrap()
        try expectEqual(parsed.select(running: MacOSVersion("27.2.1")!).major?.version, "28.0")
        try expectEqual(parsed.recommended.count, 1, "a non-string version was kept")
        // A symlink to the plist is not followed.
        let link = testTemporaryDirectory.appendingPathComponent("su-link-\(UUID().uuidString).plist").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: plistPath("softwareupdate-recommended.plist"))
        defer { try? FileManager.default.removeItem(atPath: link) }
        try expect(SoftwareUpdatePlist.read(at: link) == nil, "followed a symlink")
    }

    check("macOS check: one anonymous GET with the plain User-Agent, capped, redirects only on gdmf.apple.com") {
        let fetcher = MacFeedFetcher(.success(try fixture("gdmf-pmv.json")))
        let result = await MacOSUpdateChecker.check(host: host("27.0.1", "J999AP"), fetcher: fetcher,
                                                    plistPath: plistPath("softwareupdate-recommended.plist"), patchedVersion: "0.3.0")
        let seen = fetcher.seen
        try expect(seen.count == 1, "requests: \(seen.map(\.url))")
        try expectEqual(seen[0].url, "https://gdmf.apple.com/v2/pmv")
        try expectEqual(seen[0].maxBytes, FetchLimits.macOSFeedBytes)
        try expectEqual(seen[0].userAgent, "Patched/0.3.0")
        try expectEqual(seen[0].hosts, ["gdmf.apple.com"])
        let found = try status(result)
        try expect(found.source == .appleFeed && found.minor?.version == "27.2.1" && found.minor?.build == "26B131" && found.major == nil,
                   "found: \(found)")
        try expectEqual(found.runningVersion, "27.0.1")
        try expect(found.lastSoftwareUpdateCheck != nil, "the plist's last check is shown with the feed result")
    }

    check("macOS check: already up to date by the feed, even when the plist still lists the update") {
        let fetcher = MacFeedFetcher(.success(try fixture("gdmf-pmv.json")))
        let found = try status(await MacOSUpdateChecker.check(host: host("27.2.1", "J999AP"), fetcher: fetcher,
                                                              plistPath: plistPath("softwareupdate-recommended.plist"), patchedVersion: "0.3.0"))
        try expect(found.source == .appleFeed && found.minor == nil && found.major == nil, "up to date: \(found)")
    }

    check("macOS check: feed down, malformed or oversized falls back to the plist; neither is unavailable") {
        let answers: [(String, Result<Data, FetchError>)] = [
            ("offline", .failure(.offline("no network"))), ("server error", .failure(.http(503))),
            ("malformed", .success(Data(#"{"PublicAssetSets": "nope"}"#.utf8))),
            ("oversized", .success(Data(repeating: 0x20, count: FetchLimits.macOSFeedBytes + 1)))]
        for (name, answer) in answers {
            let fallback = try status(await MacOSUpdateChecker.check(host: host("27.0.1", "J999AP"), fetcher: MacFeedFetcher(answer),
                                                                     plistPath: plistPath("softwareupdate-recommended.plist"), patchedVersion: "0.3.0"))
            try expect(fallback.source == .softwareUpdate && fallback.minor == MacOSUpdate(kind: .minor, version: "27.2.1", build: "26B131", source: .softwareUpdate),
                       "\(name): \(fallback)")
            let nothing = await MacOSUpdateChecker.check(host: host("27.0.1", "J999AP"), fetcher: MacFeedFetcher(answer),
                                                         plistPath: missingPlist, patchedVersion: "0.3.0")
            try expectEqual(nothing, .unavailable, name)
        }
        // The real fetcher's cap: a feed over 1 MiB is refused while it streams, and the plist is used.
        StubProtocol.reset { _ in (200, [:], Data(repeating: 0x20, count: FetchLimits.macOSFeedBytes + 70_000)) }
        let capped = try status(await MacOSUpdateChecker.check(host: host("27.0.1", "J999AP"), fetcher: stubFetcher(),
                                                               plistPath: plistPath("softwareupdate-recommended.plist"), patchedVersion: "0.3.0"))
        try expect(capped.source == .softwareUpdate, "oversized stream used: \(capped)")
        try expectEqual(StubProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent"), "Patched/0.3.0")
        // A redirect off gdmf.apple.com is not followed.
        StubProtocol.reset { request in
            request.url?.host == "gdmf.apple.com" ? (302, ["Location": "https://elsewhere.example/pmv"], Data()) : (200, [:], (try? fixture("gdmf-pmv.json")) ?? Data())
        }
        let redirected = try status(await MacOSUpdateChecker.check(host: host("27.0.1", "J999AP"), fetcher: stubFetcher(),
                                                                   plistPath: plistPath("softwareupdate-recommended.plist"), patchedVersion: "0.3.0"))
        try expect(redirected.source == .softwareUpdate && !StubProtocol.requests.contains { $0.url?.host == "elsewhere.example" },
                   "followed the redirect: \(StubProtocol.requests.map { $0.url?.absoluteString ?? "" })")
    }

    check("macOS check: no device ID, or a feed that lists this Mac nowhere, uses the plist and makes no request without an ID") {
        let fetcher = MacFeedFetcher(.success(try fixture("gdmf-pmv.json")))
        let noID = try status(await MacOSUpdateChecker.check(host: host("27.0.1", nil), fetcher: fetcher,
                                                             plistPath: plistPath("softwareupdate-recommended.plist"), patchedVersion: "0.3.0"))
        try expect(noID.source == .softwareUpdate && fetcher.seen.isEmpty, "no ID: \(noID), requests \(fetcher.seen.count)")
        let unknown = try status(await MacOSUpdateChecker.check(host: host("27.0.1", "J000AP"), fetcher: MacFeedFetcher(.success(try fixture("gdmf-pmv.json"))),
                                                                plistPath: plistPath("softwareupdate-recommended.plist"), patchedVersion: "0.3.0"))
        try expect(unknown.source == .softwareUpdate && unknown.minor?.version == "27.2.1", "unlisted device: \(unknown)")
        // Without the plist an unlisted device has nothing to go on.
        let neither = await MacOSUpdateChecker.check(host: host("27.0.1", "J000AP"), fetcher: MacFeedFetcher(.success(try fixture("gdmf-pmv.json"))),
                                                     plistPath: missingPlist, patchedVersion: "0.3.0")
        try expectEqual(neither, .unavailable)
    }

    check("macOS check: source guard, never softwareupdate, defaults or a process") {
        let source = try String(contentsOf: fixtureRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UpdateSources/MacOSUpdates.swift"), encoding: .utf8)
        for word in ["Process(", "/usr/sbin/softwareupdate", "\"defaults\"", "NSTask", "posix_spawn", "system(", "AuthorizationCreate"] {
            try expect(!source.contains(word), "MacOSUpdates.swift mentions \(word)")
        }
    }
}

extension Optional {
    func unwrap(_ message: String = "unexpected nil", line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw CheckFailure(description: "\(message) (line \(line))") }
        return value
    }
}
