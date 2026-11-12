import Foundation
import Darwin
import UpdateSources
import UpdateInstaller

// Self Service: the managed catalogue, and fresh installs into a temporary ~/Applications. Fakes and temporary
// folders only: no network, no real /Applications or ~/Applications, no real preferences.

/// Forced managed preferences. A key that is only "present for the user" is modelled by `userOnly`.
private struct FakeManaged: ManagedPreferenceReading {
    var forced: [String: Any] = [:]
    var userOnly: [String: Any] = [:]
    func isForced(_ key: String) -> Bool { forced[key] != nil }
    func forcedValue(forKey key: String) -> Any? { forced[key] }
}

private func catalogue(_ value: Any) -> SelfServiceCatalogue {
    SelfServiceCatalogue.load(from: ManagedPreferences(reader: FakeManaged(forced: [SelfServiceCatalogue.preferenceKey: value])))
}
private let goodFeed = "https://example.test/appcast.xml"
private func goodEntry(_ extra: [String: Any] = [:], removing: [String] = []) -> [String: Any] {
    var entry: [String: Any] = ["Name": "Example", "TeamID": teamA, "SparkleFeedURL": goodFeed]
    for (key, value) in extra { entry[key] = value }
    for key in removing { entry[key] = nil }
    return entry
}
/// The reason the single entry is invalid, or nil when it is valid.
private func invalidReason(_ entry: [String: Any]) throws -> String? {
    let items = catalogue([entry]).items
    try expectEqual(items.count, 1, "one item")
    if case .invalid(let reason) = items[0].validity { return reason }
    return nil
}

// MARK: Fresh-install fixtures

/// A temporary home with no Applications folder yet, a v2.0 app packed as `format`, and an entry pinned to `teamA`.
private struct FreshWorld {
    let box: Sandbox
    let home: String
    var root: String { home + "/Applications" }
    let downloader: FakeDownloader
    let url: String
    var destination: String { root + "/Example.app" }
}
private func freshWorld(format: ArtifactFormat = .zip, id: String = bundleID, team: String? = teamA, notarised: Bool = true,
                        secondApp: Bool = false) throws -> FreshWorld {
    let box = try Sandbox()
    let home = box.root + "/home"
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let source = box.fixtures + "/src"
    try makeApp(at: source + "/Example.app", id: id, short: "2.0", build: "200", team: team, notarised: notarised)
    if secondApp { try makeApp(at: source + "/Example Uninstaller.app", id: id + ".uninstaller", short: "2.0", build: "200") }
    let archive: String
    if format == .dmg {
        archive = box.fixtures + "/v2.dmg"
        try FileManager.default.createSymbolicLink(atPath: source + "/Applications", withDestinationPath: "/Applications")
        try dmg(from: source, to: archive)
    } else {
        archive = box.fixtures + "/v2.zip"
        if secondApp { try zip(source, to: archive) } else { try zip(source + "/Example.app", to: archive) }
    }
    let downloader = FakeDownloader()
    let url = "https://example.test/v2.\(format.rawValue)"
    downloader.serve(url, from: archive)
    return FreshWorld(box: box, home: home, downloader: downloader, url: url)
}
private func entry(bundle: String? = bundleID, team: String = teamA, needsAdmin: Bool = false) -> SelfServiceEntry {
    SelfServiceEntry(name: "Example", teamID: team, bundleID: bundle, source: .sparkle(feed: URL(string: goodFeed)!), needsAdmin: needsAdmin)
}
/// No staging folder in the destination, no downloads, no unfinished journals.
private func expectFreshClean(_ w: FreshWorld, line: Int = #line) throws {
    let staging = ((try? FileManager.default.contentsOfDirectory(atPath: w.root)) ?? []).filter { $0.hasPrefix(".mac-updater-") }
    try expect(staging.isEmpty, "staging folders left: \(staging)", line: line)
    let downloads = (try? FileManager.default.contentsOfDirectory(atPath: w.box.locations.downloads)) ?? []
    try expect(downloads.isEmpty, "downloads left: \(downloads)", line: line)
    try expect(JournalStore(directory: w.box.locations.transactions).unfinished().isEmpty, "unfinished journals left", line: line)
}
private func install(_ w: FreshWorld, _ e: SelfServiceEntry = entry(), offer o: UpdateOffer? = nil,
                     verifier: FakeVerifier = FakeVerifier(), crashAt: TransactionJournal.Phase? = nil,
                     crashAtCheckpoint: String? = nil) async throws -> FreshInstallReport {
    let format: ArtifactFormat = w.url.hasSuffix(".dmg") ? .dmg : .zip
    return try await installer(w.box, downloader: w.downloader, verifier: verifier, crashAt: crashAt, crashAtCheckpoint: crashAtCheckpoint)
        .freshInstall(e, offer: o ?? offer(w.url, format: format), into: w.root)
}

func registerSelfServiceChecks() {
    // MARK: Catalogue

    check("self service catalogue: valid Sparkle and Homebrew entries with every optional field") {
        let items = catalogue([
            goodEntry(["Description": "Notes app", "Category": "Productivity", "BundleID": "com.example.notes", "NeedsAdmin": false]),
            ["Name": "Cask App", "TeamID": teamB, "HomebrewCask": "example-app+beta", "NeedsAdmin": true],
        ]).items
        try expectEqual(items.count, 2)
        let first = try items[0].entry.unwrapChecked(), second = try items[1].entry.unwrapChecked()
        try expectEqual(first, SelfServiceEntry(name: "Example", description: "Notes app", category: "Productivity", teamID: teamA,
                                                bundleID: "com.example.notes", source: .sparkle(feed: URL(string: goodFeed)!)))
        try expectEqual(second.source, .homebrewCask(token: "example-app+beta"))
        try expect(second.needsAdmin, "NeedsAdmin lost")
        try expect(items[0].id != items[1].id, "ids collide")
        try expect(catalogue([goodEntry()]).isFullyValid, "a valid catalogue is not fully valid")
    }
    check("self service catalogue: each bad field makes only that entry invalid, with a plain reason") {
        let long = String(repeating: "x", count: 600)
        let cases: [(String, [String: Any], String)] = [
            ("bad Team ID", goodEntry(["TeamID": "aaaaaaaaaa"]), "TeamID"),
            ("Team ID injection", goodEntry(["TeamID": "AAAA\" or 1"]), "TeamID"),
            ("missing Team ID", goodEntry(removing: ["TeamID"]), "no TeamID"),
            ("http feed", goodEntry(["SparkleFeedURL": "http://example.test/appcast.xml"]), "https"),
            ("credentials in the feed", goodEntry(["SparkleFeedURL": "https://user:secret" + "@" + "example.test/appcast.xml"]), "password"),
            ("user name in the feed", goodEntry(["SparkleFeedURL": "https://user" + "@" + "example.test/appcast.xml"]), "user name"),
            ("feed with no host", goodEntry(["SparkleFeedURL": "https:///appcast.xml"]), "https"),
            ("bad cask token", goodEntry(["HomebrewCask": "Bad Token;rm"], removing: ["SparkleFeedURL"]), "cask"),
            ("both sources", goodEntry(["HomebrewCask": "example"]), "both"),
            ("neither source", goodEntry(removing: ["SparkleFeedURL"]), "no source"),
            ("oversized name", goodEntry(["Name": long]), "Name"),
            ("empty name", goodEntry(["Name": "  "]), "Name"),
            ("missing name", goodEntry(removing: ["Name"]), "no Name"),
            ("name on two lines", goodEntry(["Name": "Two\nLines"]), "Name"),
            ("oversized description", goodEntry(["Description": long]), "Description"),
            ("oversized category", goodEntry(["Category": long]), "Category"),
            ("a number for a string", goodEntry(["Category": 42]), "Category"),
            ("bad bundle ID", goodEntry(["BundleID": "../evil"]), "BundleID"),
            ("NeedsAdmin as text", goodEntry(["NeedsAdmin": "true"]), "NeedsAdmin"),
            ("NeedsAdmin as a number", goodEntry(["NeedsAdmin": 1]), "NeedsAdmin"),
            ("misspelt key", goodEntry(["BundleId": "com.example.notes"]), "BundleId"),
        ]
        for (label, dictionary, mention) in cases {
            let reason = try invalidReason(dictionary)
            try expect(reason != nil, "\(label): accepted")
            try expect(reason!.contains(mention), "\(label): reason \"\(reason!)\" does not mention \(mention)")
            try expect(!reason!.contains("\u{2014}"), "\(label): reason has an em dash")
        }
        // The valid entries next to an invalid one still work.
        let mixed = catalogue([goodEntry(["TeamID": "nope"]), goodEntry(), "not a dictionary"]).items
        try expectEqual(mixed.map { $0.entry != nil }, [false, true, false])
        try expectEqual(mixed[0].name, "Example", "an invalid entry keeps its name for the row")
        try expectEqual(mixed[2].name, "Entry 3")
        try expect(!catalogue([goodEntry(["TeamID": "nope"]), goodEntry()]).isFullyValid, "an invalid entry counted as valid")
    }
    check("self service catalogue: a wrong top-level type or too many entries means no entries at all") {
        for value: Any in [goodEntry(), "a string", 42, true] {
            guard case .invalid = catalogue(value) else { throw CheckFailure(description: "\(type(of: value)) accepted as a catalogue") }
            try expect(catalogue(value).items.isEmpty, "entries from an invalid catalogue")
        }
        let limit = Array(repeating: goodEntry() as Any, count: SelfServiceLimits.maxEntries)
        try expectEqual(catalogue(limit).items.count, SelfServiceLimits.maxEntries, "the limit itself is allowed")
        guard case .invalid = catalogue(limit + [goodEntry()]) else { throw CheckFailure(description: "\(SelfServiceLimits.maxEntries + 1) entries accepted") }
        try expectEqual(catalogue([Any]()), .items([]))
    }
    check("self service catalogue: a value that is not forced is ignored, and the real reader reads nothing under the tripwire") {
        let userOnly = FakeManaged(forced: [:], userOnly: [SelfServiceCatalogue.preferenceKey: [goodEntry()]])
        try expectEqual(SelfServiceCatalogue.load(from: ManagedPreferences(reader: userOnly)), .notManaged)
        if RealStateTripwire.isActive {
            try expectEqual(SelfServiceCatalogue.load(), .notManaged, "the real managed preferences were read")
            do { _ = try SelfServiceDestination.standard(); throw CheckFailure(description: "real ~/Applications resolved under the tripwire") }
            catch is RealStateTripwire.Forbidden {}
        }
    }
    check("self service catalogue: the CLI listing names each entry and why one is invalid") {
        let lines = catalogue([goodEntry(["NeedsAdmin": true]), goodEntry(["TeamID": "nope"])]).listing
        try expectEqual(lines.count, 4, "\(lines)")
        try expect(lines[0] == "Self Service catalogue: 2 entries, 1 invalid.", lines[0])
        try expect(lines[1].hasPrefix("1. Example: valid. Team ID AAAAAAAAAA, Sparkle https://example.test/appcast.xml, needs admin rights"), lines[1])
        try expect(lines[2] == "   Warning: no BundleID, so any app signed and notarised by Team ID AAAAAAAAAA can be installed for this entry. Add BundleID.", lines[2])
        try expect(lines[3].hasPrefix("2. Example: invalid. The TeamID"), lines[3])
        try expectEqual(catalogue([goodEntry(["BundleID": "com.example.notes"])]).listing.count, 2, "warned about an entry with a BundleID")
        try expect(SelfServiceCatalogue.notManaged.listing[0].contains("SelfServiceCatalogue"), "not-managed text")
    }

    // MARK: Fresh install

    check("self service install: a zip goes into a new ~/Applications, verified, journalled and cleaned up") {
        let w = try freshWorld()
        try expect(!FileManager.default.fileExists(atPath: w.root), "fixture already has ~/Applications")
        let report = try await install(w)
        try expectEqual(report.path, w.destination)
        try expectEqual(report.version, "2.0 (200)")
        try expectEqual(try version(w.destination), "2.0")
        try expectEqual(FileSafety.mode(w.root), 0o700, "new ~/Applications is not private")
        try expectFreshClean(w)
        // A finished fresh install leaves no record: nothing to roll back, and an older Patched could not read it.
        try expect(journals(w.box).isEmpty, "finished fresh install left a record: \(journals(w.box).map(\.phase))")
        try expect(JournalStore(directory: w.box.locations.transactions).all().unreadable.isEmpty, "unreadable record left")
        try expect(installer(w.box).backups().isEmpty, "a fresh install made a backup")
        let line = OutcomeText.line(name: "Example", status: "installed_new", from: nil, to: report.version, backupFolder: report.folder,
                                    reason: nil, detail: nil)
        try expect(line == "Example: installed 2.0 (200) in \(w.root)", line)
    }
    check("self service install: a dmg, with and without a bundle ID in the entry") {
        let w = try freshWorld(format: .dmg)
        _ = try await install(w)
        try expectEqual(try version(w.destination), "2.0")
        try expect(!(try tool("/usr/bin/hdiutil", ["info"])).contains(w.box.root), "image still attached")
        try expectFreshClean(w)
        let plain = try freshWorld()
        _ = try await install(plain, entry(bundle: nil))
        try expectEqual(try version(plain.destination), "2.0")
        // The record is deleted once finished, so read it from an install interrupted after the move.
        let interrupted = try freshWorld()
        do { _ = try await install(interrupted, entry(bundle: nil), crashAt: .swapped); throw CheckFailure(description: "no crash") }
        catch is SimulatedCrash {}
        try expectEqual(journals(interrupted.box).first?.bundleID, bundleID, "journal kept the placeholder bundle ID")
        _ = await installer(interrupted.box).recover()
        try expect(journals(interrupted.box).isEmpty, "recovered fresh install left a record")
        // With no bundle ID to choose by, a download holding two apps is refused rather than guessed.
        let two = try freshWorld(secondApp: true)
        try await expectRefusal("ambiguous_bundle") { _ = try await install(two, entry(bundle: nil)) }
        try expect(!FileManager.default.fileExists(atPath: two.destination), "installed anyway"); try expectFreshClean(two)
    }
    check("self service install: wrong Team ID, unsigned, failed Gatekeeper and wrong bundle ID are refused, nothing installed") {
        let wrongTeam = try freshWorld(team: teamB)
        try await expectRefusal("signature_invalid") { _ = try await install(wrongTeam) }
        let unsigned = try freshWorld(team: nil)
        try await expectRefusal("signature_invalid") { _ = try await install(unsigned) }
        let rejected = try freshWorld(notarised: false)
        try await expectRefusal("notarisation_rejected") { _ = try await install(rejected) }
        let otherID = try freshWorld(id: "test.mac-updater.Other")
        try await expectRefusal("bundle_not_found") { _ = try await install(otherID) }
        let dmgTeam = try freshWorld(format: .dmg, team: teamB)
        try await expectRefusal("signature_invalid") { _ = try await install(dmgTeam) }
        for w in [wrongTeam, unsigned, rejected, otherID, dmgTeam] {
            try expect(!FileManager.default.fileExists(atPath: w.destination), "something was installed")
            // Refused in staging, before anything reached the destination: the journal was settled and removed, not
            // left as a copy that was moved into place and then taken out again.
            try expect(journals(w.box).isEmpty, "refused only after the move: \(journals(w.box).map(\.phase))")
            try expectFreshClean(w)
        }
    }
    check("self service install: the download must be the version the feed offers") {
        let w = try freshWorld()
        try await expectRefusal("version_mismatch") { _ = try await install(w, offer: offer(w.url, short: "3.0", build: "300")) }
        try expect(!FileManager.default.fileExists(atPath: w.destination), "installed"); try expectFreshClean(w)
    }
    check("self service install: never overwrites anything already at the destination") {
        let w = try freshWorld()
        try FileManager.default.createDirectory(atPath: w.root, withIntermediateDirectories: true)
        try makeApp(at: w.destination, short: "1.0", build: "100", payload: "MINE")
        let before = FileSafety.directoryIdentity(w.destination)
        try await expectRefusal("destination_exists") { _ = try await install(w) }
        try expectEqual(FileSafety.directoryIdentity(w.destination), before, "destination replaced")
        try expectEqual(try version(w.destination), "1.0")
        try expectFreshClean(w)
        // A plain file of the same name counts too.
        let file = try freshWorld()
        try FileManager.default.createDirectory(atPath: file.root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: file.destination))
        try await expectRefusal("destination_exists") { _ = try await install(file) }
        try expectEqual(FileManager.default.contents(atPath: file.destination), Data("x".utf8))
    }
    check("self service install: pkg and other formats are refused before anything is downloaded") {
        let w = try freshWorld()
        try await expectRefusal("unsupported_format") { _ = try await install(w, offer: offer("https://example.test/v2.pkg", format: .pkg)) }
        try await expectRefusal("unsupported_format") { _ = try await install(w, offer: offer("https://example.test/v2.tgz", format: .tarball)) }
        try expectEqual(w.downloader.calls, 0, "downloaded")
        try expect(journals(w.box).isEmpty, "journalled")
    }
    check("self service install: a symlinked ~/Applications is refused and its target is untouched") {
        let w = try freshWorld()
        let elsewhere = w.box.root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: w.root, withDestinationPath: elsewhere)
        try await expectRefusal("unsafe_path") { _ = try await install(w) }
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere), [], "wrote through the symlink")
        try expectEqual(w.downloader.calls, 0, "downloaded")
        // A symlink above it is refused too.
        let above = try freshWorld()
        let realHome = above.box.root + "/realhome"
        try FileManager.default.createDirectory(atPath: realHome + "/Applications", withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: above.home)
        try FileManager.default.createSymbolicLink(atPath: above.home, withDestinationPath: realHome)
        try await expectRefusal("unsafe_path") { _ = try await install(above) }
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: realHome + "/Applications"), [])
    }
    check("self service install: a NeedsAdmin entry is never installed") {
        let w = try freshWorld()
        try await expectRefusal("needs_admin") { _ = try await install(w, entry(needsAdmin: true)) }
        try await expectRefusal("needs_admin") {
            _ = try await installer(w.box, downloader: w.downloader).installFromCatalogue(entry(needsAdmin: true), into: w.root, fetcher: NoFetch())
        }
        try expectEqual(w.downloader.calls, 0); try expect(!FileManager.default.fileExists(atPath: w.root), "created ~/Applications")
    }
    check("self service install: the entry's Sparkle feed is resolved only at install time, then installed") {
        let w = try freshWorld()
        let feed = FeedFetcher(body: """
            <?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
            <sparkle:version>200</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString>
            <enclosure url="\(w.url)" type="application/zip"/></item></channel></rss>
            """)
        let report = try await installer(w.box, downloader: w.downloader)
            .installFromCatalogue(entry(), into: w.root, fetcher: feed, environment: HostEnvironment(arch: .arm64, osVersion: "15.0"))
        try expectEqual(feed.requested, [goodFeed]); try expectEqual(report.version, "2.0 (200)")
        // A feed that cannot be reached is a plain refusal; nothing is downloaded or created.
        let offline = try freshWorld()
        try await expectRefusal("not_installable") {
            _ = try await installer(offline.box, downloader: offline.downloader).installFromCatalogue(entry(), into: offline.root, fetcher: NoFetch())
        }
        try expectEqual(offline.downloader.calls, 0); try expect(!FileManager.default.fileExists(atPath: offline.root), "created ~/Applications")
    }
    check("self service install: an offer from another source is refused") {
        let w = try freshWorld()
        try await expectRefusal("not_installable") { _ = try await install(w, offer: offer(w.url, sparkle: false)) }
        try expectEqual(w.downloader.calls, 0)
    }
    check("self service install: a copy that fails verification at the destination is removed again") {
        let w = try freshWorld()
        try await expectRefusal("signature_invalid") { _ = try await install(w, verifier: FakeVerifier(failSignatureAt: [w.destination])) }
        try expect(!FileManager.default.fileExists(atPath: w.destination), "unverified copy left installed")
        try expect(journals(w.box).isEmpty, "reverted fresh install left a record"); try expectFreshClean(w)
    }

    // MARK: Recover

    check("self service recover: an interruption at each journal phase ends with nothing half-installed, idempotently") {
        // (crash point, expected outcome, installed afterwards)
        let points: [(TransactionJournal.Phase?, String?, RecoveryOutcome?, Bool)] = [
            (.staging, nil, .discarded, false),
            (.prepared, nil, .discarded, false),
            // After the move the copy is checked again; it passes here, so the install is finished and kept.
            (nil, "freshInstall.moved", .finishedFreshInstall, true),
            (.swapped, nil, .finishedFreshInstall, true),
        ]
        for (phase, checkpoint, outcome, installed) in points {
            let label = phase?.rawValue ?? checkpoint ?? "?"
            for format in [ArtifactFormat.zip, .dmg] where format == .zip || phase == .staging {
                let w = try freshWorld(format: format)
                do { _ = try await install(w, crashAt: phase, crashAtCheckpoint: checkpoint); throw CheckFailure(description: "no crash at \(label)") }
                catch is SimulatedCrash {}
                let first = await installer(w.box).recover()
                try expectEqual(first.reports.map { try? $0.result.get() }, outcome.map { [$0] } ?? [], "recover after \(label) (\(format))")
                try expectEqual(FileManager.default.fileExists(atPath: w.destination), installed, "installed after \(label)")
                if installed { try expectEqual(try version(w.destination), "2.0") }
                try expectFreshClean(w)
                try expect(!(try tool("/usr/bin/hdiutil", ["info"])).contains(w.box.root), "image still attached after \(label)")
                let again = await installer(w.box).recover()
                try expect(again.reports.isEmpty, "second recover after \(label) found work")
            }
        }
    }
    check("self service recover: never removes a destination the journal does not prove Patched put there") {
        // Interrupted before the move; someone else's app then appears at the destination.
        let before = try freshWorld()
        do { _ = try await install(before, crashAt: .prepared); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
        try makeApp(at: before.destination, short: "9.0", build: "900", payload: "THEIRS")
        let theirs = FileSafety.directoryIdentity(before.destination)
        try expectEqual(await installer(before.box).recover().reports.map { try? $0.result.get() }, [.discarded])
        try expectEqual(FileSafety.directoryIdentity(before.destination), theirs, "someone else's app was touched")
        try expectEqual(try version(before.destination), "9.0"); try expectFreshClean(before)

        // Interrupted after the move; our copy was replaced by another app before recovery ran.
        let after = try freshWorld()
        do { _ = try await install(after, crashAt: .swapped); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
        try FileManager.default.removeItem(atPath: after.destination)
        try makeApp(at: after.destination, short: "9.0", build: "900")
        let replaced = FileSafety.directoryIdentity(after.destination)
        try expectEqual(await installer(after.box).recover().reports.map { try? $0.result.get() }, [.discarded])
        try expectEqual(FileSafety.directoryIdentity(after.destination), replaced, "a replacement app was removed")

        // A journal whose recorded identity matches an app with a different bundle ID: refused, left in place.
        let forged = try freshWorld()
        do { _ = try await install(forged, crashAt: .swapped); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
        let store = JournalStore(directory: forged.box.locations.transactions)
        var journal = try store.unfinished().first.unwrapChecked()
        let other = forged.root + "/Other.app"
        try makeApp(at: other, id: "test.mac-updater.Other", short: "1.0", build: "100")
        journal.targetPath = other; journal.newIdentity = FileSafety.directoryIdentity(other)
        try store.write(&journal)
        let refused = await installer(forged.box).recover().reports
        guard case .failure(let refusal) = refused.first?.result, refusal.code == "recovery_ambiguous" else {
            throw CheckFailure(description: "forged journal: \(refused.map(\.result))")
        }
        try expect(FileManager.default.fileExists(atPath: other), "an app the journal did not prove was removed")
    }
    check("self service recover: a running copy at the destination is not removed") {
        let w = try freshWorld()
        do { _ = try await install(w, crashAt: .swapped); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
        let running = FakeRunningApps()
        running.set(running: w.destination, willQuit: false)
        let result = await installer(w.box, running: running).recover().reports
        guard case .failure(let refusal) = result.first?.result, refusal.code == "app_running" else {
            throw CheckFailure(description: "running copy: \(result.map(\.result))")
        }
        try expect(FileManager.default.fileExists(atPath: w.destination), "removed while running")
    }
    check("self service install: a pending fresh-install journal blocks the next one until recovered") {
        let w = try freshWorld()
        do { _ = try await install(w, crashAt: .staging); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
        try await expectRefusal("unfinished_transaction") { _ = try await install(w) }
        _ = await installer(w.box).recover()
        _ = try await install(w)
        try expectEqual(try version(w.destination), "2.0")
    }

    // MARK: Review fixes

    check("self service recover: a recover running while an install is still staging leaves that install alone") {
        let w = try freshWorld()
        let blocking = BlockingDownloader(inner: w.downloader)
        let live = UpdateInstaller(locations: w.box.locations, downloader: blocking, verifier: FakeVerifier(), runningApps: FakeRunningApps(),
                                   teamIDReader: fakeTeamReader, quitTimeout: 1, selfServiceRoot: w.root)
        // The entry names its bundle ID, so the journal could otherwise carry a lock nobody holds yet.
        let root = w.root, url = w.url
        let running = Task { try await live.freshInstall(entry(), offer: offer(url), into: root) }
        await blocking.waitUntilStarted()
        let staging = try JournalStore(directory: w.box.locations.transactions).unfinished().first.unwrapChecked().stagingDir
        let reports = await installer(w.box).recover().reports
        guard case .failure(let refusal) = reports.first?.result, refusal.code == "busy" else {
            blocking.release()
            _ = try? await running.value
            throw CheckFailure(description: "recover touched a live install: \(reports.map(\.result))")
        }
        try expect(FileManager.default.fileExists(atPath: staging), "the live install's staging folder was removed")
        blocking.release()
        let report = try await running.value
        try expectEqual(try version(report.path), "2.0"); try expectFreshClean(w)
    }
    check("self service recover: a forged journal pointing outside the Self Service folder is refused and nothing is deleted") {
        for consistent in [true, false] {
            let w = try freshWorld()
            do { _ = try await install(w, crashAt: .swapped); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
            let store = JournalStore(directory: w.box.locations.transactions)
            var journal = try store.unfinished().first.unwrapChecked()
            // A victim with the journal's bundle ID that would fail verification, so a recovery that accepted the journal
            // would delete it.
            let elsewhere = w.box.root + "/elsewhere"
            let victim = try makeApp(at: elsewhere + "/Victim.app", short: "9.0", build: "900")
            let staging = elsewhere + "/.mac-updater-" + journal.id
            try FileSafety.makeFreshPrivateDirectory(staging)
            journal.targetPath = victim; journal.stagingDir = staging
            journal.newIdentity = FileSafety.directoryIdentity(victim)
            // Either the journal claims the other folder as its root, or it keeps the real root and the target is outside it.
            if consistent { journal.destinationRoot = elsewhere }
            try store.write(&journal)
            let reports = await installer(w.box).recover().reports
            guard case .failure(let refusal) = reports.first?.result, refusal.code == "journal_error" else {
                throw CheckFailure(description: "forged journal (consistent: \(consistent)) accepted: \(reports.map(\.result))")
            }
            try expect(FileManager.default.fileExists(atPath: victim), "an app outside the Self Service folder was deleted")
            try expectEqual(try version(victim), "9.0")
        }
        // A journal that names no folder at all is refused too.
        let w = try freshWorld()
        do { _ = try await install(w, crashAt: .swapped); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
        let store = JournalStore(directory: w.box.locations.transactions)
        var journal = try store.unfinished().first.unwrapChecked()
        journal.destinationRoot = nil
        try store.write(&journal)
        guard case .failure(let refusal)? = await installer(w.box).recover().reports.first?.result, refusal.code == "journal_error" else {
            throw CheckFailure(description: "a journal with no destination folder was recovered")
        }
        try expect(FileManager.default.fileExists(atPath: w.destination), "removed")
        // And an install into a folder other than the configured one is refused up front.
        try await expectRefusal("unsafe_path") {
            _ = try await installer(w.box, downloader: w.downloader).freshInstall(entry(), offer: offer(w.url), into: w.box.root + "/other/Applications")
        }
    }
    check("self service recover: after the move, a copy that verifies is kept and one that does not is removed") {
        let w = try freshWorld()
        do { _ = try await install(w, crashAt: .swapped); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
        let failing = FakeVerifier(failSignatureAt: [w.destination])
        try expectEqual(await installer(w.box, verifier: failing).recover().reports.map { try? $0.result.get() }, [.removedUnfinishedInstall])
        try expect(!FileManager.default.fileExists(atPath: w.destination), "an unverified copy was kept")
        try expectFreshClean(w)
        let kept = try freshWorld()
        do { _ = try await install(kept, crashAt: .swapped); throw CheckFailure(description: "no crash") } catch is SimulatedCrash {}
        try expectEqual(await installer(kept.box).recover().reports.map { try? $0.result.get() }, [.finishedFreshInstall])
        try expectEqual(try version(kept.destination), "2.0")
        try expect(journals(kept.box).isEmpty, "recovered fresh install left a record"); try expectFreshClean(kept)
    }
    check("self service install: an unverified copy that is already running is never quit, and the result says to delete it") {
        let w = try freshWorld()
        let running = FakeRunningApps()
        running.set(running: w.destination, willQuit: true)
        do {
            _ = try await installer(w.box, downloader: w.downloader, verifier: FakeVerifier(failSignatureAt: [w.destination]), running: running)
                .freshInstall(entry(), offer: offer(w.url), into: w.root)
            throw CheckFailure(description: "installed")
        } catch let refusal as InstallRefusal {
            try expectEqual(refusal.code, "unresolved")
            try expect(refusal.message.contains("the copy at \(w.destination) failed verification") && refusal.message.contains("is not trusted")
                       && refusal.message.contains("delete it"), refusal.message)
        }
        try expectEqual(running.quitRequests, 0, "asked the app to quit")
        try expect(FileManager.default.fileExists(atPath: w.destination), "removed while running")
        try expectEqual(JournalStore(directory: w.box.locations.transactions).unfinished().map(\.phase), [.swapped], "journal not kept open")
    }
    check("self service install: an item that replaced the copy before it failed verification is left alone, and the result says so") {
        let w = try freshWorld()
        let verifier = SwappingVerifier(destination: w.destination)
        let live = UpdateInstaller(locations: w.box.locations, downloader: w.downloader, verifier: verifier, runningApps: FakeRunningApps(),
                                   teamIDReader: fakeTeamReader, quitTimeout: 1, selfServiceRoot: w.root)
        do {
            _ = try await live.freshInstall(entry(), offer: offer(w.url), into: w.root)
            throw CheckFailure(description: "installed")
        } catch let refusal as InstallRefusal {
            try expectEqual(refusal.code, "recovery_ambiguous")
            try expect(refusal.message.contains("was not put there by Patched, so it was left alone"), refusal.message)
        }
        try expectEqual(try BundleFacts.read(bundleAt: w.destination).bundleID, "test.mac-updater.Other", "the replacement was touched")
    }
    check("self service catalogue: an unknown key name that is not plain text never reaches the reason") {
        let reason = try invalidReason(goodEntry(["Bad\u{202E}Key\nInjected": 1])).unwrapChecked()
        try expect(reason.contains("(a name that cannot be shown)") && !reason.contains("\u{202E}") && !reason.contains("Injected"), reason)
    }
}

/// Serves one feed body and records what was asked for.
private final class FeedFetcher: HTTPFetching, @unchecked Sendable {
    let body: String
    private let lock = NSLock()
    private var urls: [String] = []
    init(body: String) { self.body = body }
    var requested: [String] { lock.withLock { urls } }
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        lock.withLock { urls.append(url.absoluteString) }
        return Data(body.utf8)
    }
}

/// Holds the download until released, so a check can act while an install is in staging.
private final class BlockingDownloader: ArtifactDownloading, @unchecked Sendable {
    let inner: FakeDownloader
    private let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
    init(inner: FakeDownloader) { self.inner = inner }
    func waitUntilStarted() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.global().async { self.started.wait(); c.resume() } }
    }
    func release() { gate.signal() }
    func download(_ url: URL, into sink: ArtifactSink, expectedLength: Int64?) async throws {
        started.signal()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.global().async { self.gate.wait(); c.resume() } }
        try await inner.download(url, into: sink, expectedLength: expectedLength)
    }
}

/// Fails the check at the destination after replacing what is there with another app, as if someone swapped it.
private struct SwappingVerifier: CodeVerifying {
    let destination: String
    func verifySignature(ofBundleAt path: String, teamID: String) throws {
        if path == destination {
            try? FileManager.default.removeItem(atPath: path)
            _ = try? makeApp(at: path, id: "test.mac-updater.Other", short: "9.0", build: "900")
            throw InstallRefusal.signatureInvalid("fake: replaced before the check")
        }
        try FakeVerifier().verifySignature(ofBundleAt: path, teamID: teamID)
    }
    func assessGatekeeper(ofBundleAt path: String) throws { try FakeVerifier().assessGatekeeper(ofBundleAt: path) }
}

/// A fetcher that must never be used.
private struct NoFetch: HTTPFetching {
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data { throw CheckFailure(description: "network used for \(url)") }
}
