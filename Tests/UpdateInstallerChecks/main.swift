import Foundation
import CryptoKit
import Darwin
import UpdateSources
import UpdateInstaller

// Phase 2a installer checks. Default runs use temporary fixtures only, with no network or real
// /Applications access. PATCHED_RUN_INSTALLED_APP_CHECKS=1 explicitly enables the manual native
// verifier integration check against installed apps only when PATCHED_FORBID_REAL_STATE is not 1.
// Temporary fixtures are removed afterwards.

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) throws {
    if !(try condition()) { throw CheckFailure(description: "\(message) (main.swift:\(line))") }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", line: Int = #line) throws {
    if a != b { throw CheckFailure(description: "\(message) expected \(b), got \(a) (line \(line))") }
}
nonisolated(nonsending) func expectRefusal(_ code: String, line: Int = #line, _ body: nonisolated(nonsending) () async throws -> Void) async throws {
    do {
        try await body()
    } catch let refusal as InstallRefusal {
        if refusal.code != code { throw CheckFailure(description: "expected \(code), got \(refusal) (line \(line))") }
        return
    }
    throw CheckFailure(description: "expected refusal \(code), got success (line \(line))")
}

nonisolated(unsafe) var cases: [(String, () async throws -> Void)] = []
func check(_ name: String, _ action: @escaping () async throws -> Void) { cases.append((name, action)) }

// MARK: Tools (fixed paths, argv only; never a shell)

@discardableResult
func tool(_ path: String, _ args: [String], stdin: Data? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    let input = Pipe()
    process.standardInput = stdin == nil ? FileHandle(forReadingAtPath: "/dev/null") : input
    try process.run()
    if let stdin { input.fileHandleForWriting.write(stdin); try input.fileHandleForWriting.close() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw CheckFailure(description: "\(path) \(args.joined(separator: " ")) failed: \(text)")
    }
    return text
}

extension Optional {
    func unwrapChecked() throws -> Wrapped { guard let self else { throw CheckFailure(description: "unexpected nil") }; return self }
}

// MARK: Fixtures

extension UpdateInstaller {
    /// Checks drive the lower-level entry point with fixture offers that are, by construction, installable.
    func update(appAt path: String, offer: UpdateOffer, options: UpdateOptions = UpdateOptions()) async throws -> InstallReport {
        try await update(appAt: path, offer: offer, installable: true, options: options)
    }
}

final class Sandbox {
    let root: String
    let apps: String
    let state: String
    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("uicheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let real = FileSafety.realPath(base.path) else { throw CheckFailure(description: "no realpath") }
        root = real
        apps = real + "/Applications"
        state = real + "/state"
        try FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: real + "/fixtures", withIntermediateDirectories: true)
    }
    var fixtures: String { root + "/fixtures" }
    var locations: InstallerLocations { .under(state) }
    deinit {
        // Make sure nothing we chmod'ed blocks removal.
        _ = try? tool("/bin/chmod", ["-R", "u+rwx", root])
        try? FileManager.default.removeItem(atPath: root)
    }
}

let teamA = "AAAAAAAAAA", teamB = "BBBBBBBBBB"
let bundleID = "test.mac-updater.Example"

/// A minimal .app tree. `team` is what the fake verifier treats as the signing team.
@discardableResult
func makeApp(at path: String, id: String = bundleID, short: String?, build: String?, team: String? = teamA,
             edKey: String? = nil, notarised: Bool = true, payload: String = "") throws -> String {
    let fm = FileManager.default
    try fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
    var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Example", "CFBundlePackageType": "APPL"]
    if let short { plist["CFBundleShortVersionString"] = short }
    if let build { plist["CFBundleVersion"] = build }
    if let edKey { plist["SUPublicEDKey"] = edKey }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
    try Data("#!/bin/false\n\(short ?? "")\(payload)\n".utf8).write(to: URL(fileURLWithPath: path + "/Contents/MacOS/Example"))
    chmod(path + "/Contents/MacOS/Example", 0o755)
    if let team { try Data(team.utf8).write(to: URL(fileURLWithPath: path + "/Contents/Resources/fake-team")) }
    if !notarised { try Data().write(to: URL(fileURLWithPath: path + "/Contents/Resources/fake-not-notarised")) }
    // A framework-style relative symlink that stays inside, like real bundles have.
    try fm.createDirectory(atPath: path + "/Contents/Frameworks/Lib.framework/Versions/A", withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: path + "/Contents/Frameworks/Lib.framework/Versions/Current", withDestinationPath: "A")
    return path
}

func zip(_ items: String, to archive: String) throws {
    try tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", items, archive])
}
func dmg(from folder: String, to image: String, extra: [String] = [], stdin: Data? = nil) throws {
    try tool("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", folder, "-volname", "Example", "-format", "UDZO", "-ov"] + extra + [image], stdin: stdin)
}
func sha256Hex(_ path: String) throws -> String {
    SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
}
func sha512Base64(_ path: String) throws -> String {
    Data(SHA512.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))).base64EncodedString()
}
func version(_ app: String) throws -> String? { try BundleFacts.read(bundleAt: app).shortVersion }

func offer(_ url: String, short: String = "2.0", build: String? = "200", format: ArtifactFormat = .zip,
           sha256: String? = nil, sha512: String? = nil, ed: String? = nil, length: Int? = nil,
           sparkle: Bool = true) -> UpdateOffer {
    UpdateOffer(displayVersion: short, buildVersion: build, downloadURL: URL(string: url)!, sha256: sha256, sha512: sha512,
                edSignature: ed, length: length, format: format,
                source: sparkle ? .sparkle(feed: URL(string: "https://example.test/appcast.xml")!) : .homebrewCask(token: "example"))
}

// MARK: Fakes

/// Streams local files into the sink in 64 KiB chunks, like the real downloader.
final class FakeDownloader: ArtifactDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    private var extra: [String: Int] = [:]
    private var crash = false
    private(set) var calls = 0
    func serve(_ url: String, from path: String, appendBytes: Int = 0) {
        lock.withLock { files[url] = path; extra[url] = appendBytes }
    }
    func crashMidway() { lock.withLock { crash = true } }
    func download(_ url: URL, into sink: ArtifactSink, expectedLength: Int64?) async throws {
        let (path, more, crashNow) = lock.withLock { () -> (String?, Int, Bool) in
            calls += 1; return (files[url.absoluteString], extra[url.absoluteString] ?? 0, crash)
        }
        guard let path else { throw InstallRefusal.download("HTTP 404") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path)) + Data(repeating: 0x41, count: more)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 65_536, data.count)
            try sink.append(data.subdata(in: offset..<end))
            offset = end
            if crashNow { throw SimulatedCrash(phase: "download") }
        }
    }
}

/// "Signature" = Contents/Resources/fake-team equals the pinned team and the executable does not contain
/// TAMPERED. It can also be told to fail at chosen paths (optionally only for one version) and for copies
/// being made into the backups folder.
struct FakeVerifier: CodeVerifying {
    var failSignatureAt: Set<String> = []
    var failGatekeeperAt: Set<String> = []
    /// Limit the path-based failures to bundles with this short version.
    var onlyVersion: String? = nil
    var failPartialCopies = false
    func versionMatches(_ path: String) -> Bool {
        guard let only = onlyVersion else { return true }
        return (try? BundleFacts.read(bundleAt: path).shortVersion) == only
    }
    func verifySignature(ofBundleAt path: String, teamID: String) throws {
        if failSignatureAt.contains(path) && versionMatches(path) { throw InstallRefusal.signatureInvalid("fake failure at \(path)") }
        if failPartialCopies && path.contains("/.partial-") { throw InstallRefusal.signatureInvalid("fake failure for the backup copy") }
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Resources/fake-team"),
              String(decoding: data, as: UTF8.self) == teamID else {
            throw InstallRefusal.signatureInvalid("fake: not signed by \(teamID)")
        }
        if let exe = FileManager.default.contents(atPath: path + "/Contents/MacOS/Example"),
           String(decoding: exe, as: UTF8.self).contains("TAMPERED") {
            throw InstallRefusal.signatureInvalid("fake: executable modified")
        }
    }
    func assessGatekeeper(ofBundleAt path: String) throws {
        if failGatekeeperAt.contains(path) && versionMatches(path) { throw InstallRefusal.notarisationRejected("fake: rejected at \(path)") }
        if FileManager.default.fileExists(atPath: path + "/Contents/Resources/fake-not-notarised") {
            throw InstallRefusal.notarisationRejected("fake: not notarised")
        }
    }
}

final class FakeRunningApps: RunningAppControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: [pid_t]] = [:]
    private var willQuit = true
    private var respawn = false
    private var respawnArmed = false
    private var duringQuit: (@Sendable () -> Void)?
    private(set) var relaunched: [String] = []
    private(set) var quitRequests = 0
    func set(running path: String, willQuit: Bool, respawnAfterQuit: Bool = false, duringQuit: (@Sendable () -> Void)? = nil) {
        lock.withLock {
            running[path] = [4242]; self.willQuit = willQuit; respawn = respawnAfterQuit; self.duringQuit = duringQuit
        }
    }
    func runningInstances(bundleID: String, path: String) -> [pid_t] {
        lock.withLock {
            // A helper relaunches the app right after the first one quit.
            if respawnArmed { respawnArmed = false; running[path] = [4343] }
            return running[path] ?? []
        }
    }
    func quit(bundleID: String, path: String, timeout: TimeInterval) async -> Bool {
        let hook = lock.withLock { duringQuit }
        hook?()
        return lock.withLock {
            quitRequests += 1
            if willQuit { running[path] = nil; if respawn { respawnArmed = true } }
            return willQuit
        }
    }
    func relaunch(path: String) async { lock.withLock { relaunched.append(path) } }
}

let fakeTeamReader: TeamIDReader = { path in
    FileManager.default.contents(atPath: path + "/Contents/Resources/fake-team").map { String(decoding: $0, as: UTF8.self) }
}

func installer(_ box: Sandbox, downloader: FakeDownloader = FakeDownloader(), verifier: FakeVerifier = FakeVerifier(),
               running: FakeRunningApps = FakeRunningApps(), uid: uid_t = geteuid(),
               crashAt: TransactionJournal.Phase? = nil, failJournalAt: TransactionJournal.Phase? = nil,
               budget: UnpackBudget = .standard, forceCopyBackup: Bool = false,
               crashAtCheckpoint: String? = nil,
               detacher: @escaping @Sendable (String) -> Bool = { Unpacker.detachDiskImage(at: $0) }) -> UpdateInstaller {
    UpdateInstaller(locations: box.locations, downloader: downloader, verifier: verifier, runningApps: running, uid: uid,
                    teamIDReader: fakeTeamReader,
                    hooks: TransactionHooks(afterJournalWrite: { phase in
                        if phase == crashAt { throw SimulatedCrash(phase: phase.rawValue) }
                        if phase == failJournalAt { throw InstallRefusal.journal("simulated journal write failure") }
                    }, atCheckpoint: { name in
                        if name == crashAtCheckpoint { throw SimulatedCrash(phase: name) }
                    }),
                    quitTimeout: 1, unpackBudget: budget, forceCopyBackup: forceCopyBackup, diskImageDetacher: detacher)
}

/// Installed v1 at Applications/Example.app and a v2 zip served at https://example.test/v2.zip.
struct World {
    let box: Sandbox
    let target: String
    let downloader: FakeDownloader
    let archive: String
}
func world(format: ArtifactFormat = .zip, installedKey: String? = nil, newShort: String = "2.0", newBuild: String = "200",
           newID: String = bundleID, newTeam: String = teamA) throws -> World {
    let box = try Sandbox()
    let target = try makeApp(at: box.apps + "/Example.app", short: "1.0", build: "100", edKey: installedKey)
    let source = box.fixtures + "/src"
    try makeApp(at: source + "/Example.app", id: newID, short: newShort, build: newBuild, team: newTeam, edKey: installedKey)
    let archive: String
    if format == .dmg {
        archive = box.fixtures + "/v2.dmg"
        try FileManager.default.createSymbolicLink(atPath: source + "/Applications", withDestinationPath: "/Applications")
        try dmg(from: source, to: archive)
    } else {
        archive = box.fixtures + "/v2.zip"
        try zip(source + "/Example.app", to: archive)
    }
    let downloader = FakeDownloader()
    downloader.serve("https://example.test/v2.\(format.rawValue)", from: archive)
    return World(box: box, target: target, downloader: downloader, archive: archive)
}

/// No staging folders, no downloads, no unfinished journals.
func expectClean(_ box: Sandbox, line: Int = #line) throws {
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: box.apps)) ?? []).filter { $0.hasPrefix(".mac-updater-") }
    try expect(leftovers.isEmpty, "staging folders left: \(leftovers)", line: line)
    let downloads = (try? FileManager.default.contentsOfDirectory(atPath: box.locations.downloads)) ?? []
    try expect(downloads.isEmpty, "downloads left: \(downloads)", line: line)
    try expect(JournalStore(directory: box.locations.transactions).unfinished().isEmpty, "unfinished journals left", line: line)
}
func journals(_ box: Sandbox) -> [TransactionJournal] { JournalStore(directory: box.locations.transactions).all().journals }

// MARK: 1. Preconditions

check("unsigned or ad-hoc installed app cannot be pinned") {
    let box = try Sandbox()
    let app = try makeApp(at: box.apps + "/Example.app", short: "1.0", build: "100", team: nil)
    try await expectRefusal("cannot_pin_identity") { _ = try installer(box).checkPreconditions(appPath: app, format: .zip) }
}
check("a malformed Team ID is refused before it can reach a code requirement") {
    try expect(!TeamIdentifier.isValid("AAAA\" or anchor apple"), "injection accepted")
    try expect(!TeamIdentifier.isValid("aaaaaaaaaa"), "lower case accepted")
    try expect(TeamIdentifier.isValid("6JSW4SJWN9"), "real team rejected")
    try await expectRefusal("cannot_pin_identity") { _ = try TeamIdentifier.requirement(for: "X\" or true") }
}
check("symlink anywhere in the target path is refused") {
    let box = try Sandbox()
    try FileManager.default.createDirectory(atPath: box.root + "/real", withIntermediateDirectories: true)
    try makeApp(at: box.root + "/real/Example.app", short: "1.0", build: "100")
    try FileManager.default.createSymbolicLink(atPath: box.root + "/linked", withDestinationPath: box.root + "/real")
    try await expectRefusal("unsafe_path") { _ = try installer(box).checkPreconditions(appPath: box.root + "/linked/Example.app", format: .zip) }
    // Deeper: the symlink is two levels above the app, so only the per-component check sees it.
    try makeApp(at: box.root + "/real/Sub/Example.app", short: "1.0", build: "100")
    do {
        _ = try installer(box).checkPreconditions(appPath: box.root + "/linked/Sub/Example.app", format: .zip)
        throw CheckFailure(description: "deep symlink accepted")
    } catch let refusal as InstallRefusal {
        try expect(refusal.message.contains("/linked is a symlink"), "wrong refusal: \(refusal)")
    }
    try FileManager.default.createSymbolicLink(atPath: box.apps + "/Link.app", withDestinationPath: box.root + "/real/Example.app")
    try await expectRefusal("unsafe_path") { _ = try installer(box).checkPreconditions(appPath: box.apps + "/Link.app", format: .zip) }
    try await expectRefusal("unsafe_path") { _ = try installer(box).checkPreconditions(appPath: box.apps + "/../Applications/Example.app", format: .zip) }
}
check("bundle not owned by the current user needs admin") {
    let w = try world()
    try await expectRefusal("needs_admin") { _ = try installer(w.box, uid: 4242).checkPreconditions(appPath: w.target, format: .zip) }
}
check("unwritable applications folder needs admin") {
    let w = try world()
    chmod(w.box.apps, 0o555)
    defer { chmod(w.box.apps, 0o755) }
    try await expectRefusal("needs_admin") { _ = try installer(w.box).checkPreconditions(appPath: w.target, format: .zip) }
}
check("pkg and other formats are unsupported") {
    let w = try world()
    try await expectRefusal("unsupported_format") { _ = try installer(w.box).checkPreconditions(appPath: w.target, format: .pkg) }
    try await expectRefusal("unsupported_format") { _ = try installer(w.box).checkPreconditions(appPath: w.target, format: .tarball) }
    try await expectRefusal("unsupported_format") { _ = try installer(w.box).checkPreconditions(appPath: w.target, format: .unknown) }
    try await expectRefusal("unsupported_format") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.pkg", format: .pkg))
    }
    try expectEqual(w.downloader.calls, 0, "nothing downloaded")
}

// MARK: 2. Download

check("download limits and https-only") {
    try expectEqual(DownloadLimits.maxBytes, 4 * 1024 * 1024 * 1024)
    let box = try Sandbox()
    try FileSafety.makePrivateDirectory(box.state)
    let sink = try ArtifactSink(path: box.state + "/a", maxBytes: 10)
    try sink.append(Data(count: 10))
    try await expectRefusal("too_large") { try sink.append(Data(count: 1)) }
    let other = try ArtifactSink(path: box.state + "/b", maxBytes: 100)
    try await expectRefusal("insecure_download") {
        try await URLSessionArtifactDownloader().download(URL(string: "http://example.test/a.zip")!, into: other, expectedLength: nil)
    }
    try expect(HTTPSRedirectPolicy.decide(URLRequest(url: URL(string: "http://example.test/")!)) == nil, "http redirect allowed")
}
check("SHA-256 mismatch is refused and everything is cleaned up") {
    let w = try world()
    try await expectRefusal("hash_mismatch") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target,
            offer: offer("https://example.test/v2.zip", sha256: String(repeating: "0", count: 64)))
    }
    try expectEqual(try version(w.target), "1.0"); try expectClean(w.box)
}
check("SHA-512 mismatch is refused") {
    let w = try world()
    try await expectRefusal("hash_mismatch") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target,
            offer: offer("https://example.test/v2.zip", sha512: Data(repeating: 1, count: 64).base64EncodedString()))
    }
    try expectClean(w.box)
}
check("length mismatch is refused, short and long") {
    let w = try world()
    let size = Int((try FileManager.default.attributesOfItem(atPath: w.archive)[.size] as? NSNumber)?.intValue ?? 0)
    try await expectRefusal("length_mismatch") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip", length: size + 1))
    }
    w.downloader.serve("https://example.test/v2.zip", from: w.archive, appendBytes: 70_000)
    try await expectRefusal("length_mismatch") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip", length: size))
    }
    try expectClean(w.box)
}
check("feed length beyond the 4 GiB cap is refused up front") {
    let w = try world()
    try await expectRefusal("too_large") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target,
            offer: offer("https://example.test/v2.zip", length: Int(DownloadLimits.maxBytes) + 1))
    }
    try expectEqual(w.downloader.calls, 0); try expectClean(w.box)
}
check("matching hashes and length pass") {
    let w = try world()
    let size = (try FileManager.default.attributesOfItem(atPath: w.archive)[.size] as? NSNumber)?.intValue
    let report = try await installer(w.box, downloader: w.downloader).update(appAt: w.target,
        offer: offer("https://example.test/v2.zip", sha256: try sha256Hex(w.archive), sha512: try sha512Base64(w.archive), length: size))
    try expectEqual(report.status, .installed); try expectEqual(try version(w.target), "2.0")
}

// MARK: 3. Sparkle EdDSA

check("EdDSA: good signature installs, bad and missing are refused") {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let w = try world(installedKey: publicKey)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: w.archive))
    let good = try key.signature(for: bytes).base64EncodedString()
    let bad = try key.signature(for: bytes + Data([0])).base64EncodedString()
    let other = try Curve25519.Signing.PrivateKey().signature(for: bytes).base64EncodedString()
    let url = "https://example.test/v2.zip"
    try await expectRefusal("ed_signature_missing") { _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer(url)) }
    try await expectRefusal("ed_signature_invalid") { _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer(url, ed: bad)) }
    try await expectRefusal("ed_signature_invalid") { _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer(url, ed: other)) }
    try await expectRefusal("ed_signature_invalid") { _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer(url, ed: "not base64!")) }
    try expectClean(w.box); try expectEqual(try version(w.target), "1.0")
    let report = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer(url, ed: good))
    try expectEqual(report.status, .installed)
}
check("EdDSA: a malformed pinned key fails closed, no key skips the check") {
    let box = try Sandbox()
    try FileSafety.makePrivateDirectory(box.state)
    let file = box.state + "/f"; try Data("x".utf8).write(to: URL(fileURLWithPath: file))
    try await expectRefusal("ed_signature_invalid") { try SparkleSignature.check(publicKey: "", signature: "abc", archivePath: file) }
    try await expectRefusal("ed_signature_invalid") { try SparkleSignature.check(publicKey: "AAAA", signature: "abc", archivePath: file) }
    try SparkleSignature.check(publicKey: nil, signature: nil, archivePath: file)
}

// MARK: 4-5. Unpack and select

check("wrong bundle ID in the download is refused") {
    let w = try world(newID: "test.other.App")
    try await expectRefusal("bundle_not_found") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
    try expectClean(w.box)
}
check("two candidate apps with the bundle ID are refused") {
    let w = try world()
    let folder = w.box.fixtures + "/two"
    try makeApp(at: folder + "/Example.app", short: "2.0", build: "200")
    try makeApp(at: folder + "/Example Copy.app", short: "2.0", build: "200")
    try zip(folder, to: w.box.fixtures + "/two.zip")
    w.downloader.serve("https://example.test/two.zip", from: w.box.fixtures + "/two.zip")
    try await expectRefusal("ambiguous_bundle") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/two.zip"))
    }
    try expectClean(w.box)
}
check("a zip that wraps the app in a folder is accepted (depth 2)") {
    let w = try world()
    let folder = w.box.fixtures + "/Wrapper"
    try makeApp(at: folder + "/Example.app", short: "2.0", build: "200")
    try makeApp(at: folder + "/Helper.app", id: "test.helper", short: "1", build: "1")
    try zip(folder, to: w.box.fixtures + "/wrapped.zip")
    w.downloader.serve("https://example.test/wrapped.zip", from: w.box.fixtures + "/wrapped.zip")
    let report = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/wrapped.zip"))
    try expectEqual(report.status, .installed); try expectEqual(try version(w.target), "2.0")
}
check("symlinks that leave the bundle are refused") {
    for destination in ["/etc/passwd", "../../../../outside", "../../../Example.app"] {
        let w = try world()
        let src = w.box.fixtures + "/evil/Example.app"
        try makeApp(at: src, short: "2.0", build: "200")
        try FileManager.default.createSymbolicLink(atPath: src + "/Contents/Resources/link", withDestinationPath: destination)
        try zip(src, to: w.box.fixtures + "/evil.zip")
        w.downloader.serve("https://example.test/evil.zip", from: w.box.fixtures + "/evil.zip")
        try await expectRefusal("unsafe_symlink") {
            _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/evil.zip"))
        }
        try expectClean(w.box)
    }
}
check("dmg install works and the image is always detached") {
    let w = try world(format: .dmg)
    let report = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.dmg", format: .dmg))
    try expectEqual(report.status, .installed); try expectEqual(try version(w.target), "2.0")
    try expectClean(w.box)
    let info = try tool("/usr/bin/hdiutil", ["info"])
    try expect(!info.contains(w.box.root), "an image from this check is still attached:\n\(info)")
}
check("dmg with the wrong app is refused and detached") {
    let w = try world(format: .dmg, newID: "test.other.App")
    try await expectRefusal("bundle_not_found") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.dmg", format: .dmg))
    }
    try expectClean(w.box)
    try expect(!(try tool("/usr/bin/hdiutil", ["info"])).contains(w.box.root), "image still attached")
}
check("dmg that needs interaction (password) fails instead of hanging, and is detached") {
    let w = try world()
    let folder = w.box.fixtures + "/src"
    try dmg(from: folder, to: w.box.fixtures + "/locked.dmg", extra: ["-encryption", "AES-128", "-stdinpass"], stdin: Data("secret".utf8))
    w.downloader.serve("https://example.test/locked.dmg", from: w.box.fixtures + "/locked.dmg")
    let started = Date()
    try await expectRefusal("unpack_failed") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/locked.dmg", format: .dmg))
    }
    try expect(Date().timeIntervalSince(started) < 60, "took too long")
    try expectClean(w.box)
    try expect(!(try tool("/usr/bin/hdiutil", ["info"])).contains(w.box.root), "image still attached")
}

// MARK: 6. Verification of the staged app

check("staged app signed by another team is refused") {
    let w = try world(newTeam: teamB)
    try await expectRefusal("signature_invalid") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
    try expectClean(w.box); try expectEqual(try version(w.target), "1.0")
}
check("staged app Gatekeeper rejects is refused") {
    let w = try world()
    let src = w.box.fixtures + "/nn/Example.app"
    try makeApp(at: src, short: "2.0", build: "200", notarised: false)
    try zip(src, to: w.box.fixtures + "/nn.zip")
    w.downloader.serve("https://example.test/nn.zip", from: w.box.fixtures + "/nn.zip")
    try await expectRefusal("notarisation_rejected") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/nn.zip"))
    }
    try expectClean(w.box)
}
check("downgrade, same version and offer mismatch are refused") {
    for (short, build, offered, offeredBuild, code) in [("0.9", "90", "0.9", "90", "not_newer"), ("1.0", "100", "1.0", "100", "not_newer"),
                                                         ("2.0", "200", "3.0", "300", "version_mismatch"),
                                                         ("2.0", "200", "2.0", "201", "version_mismatch"),
                                                         ("2.0", "90", "2.0", "90", "not_newer")] {
        let w = try world(newShort: short, newBuild: build)
        try await expectRefusal(code) {
            _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target,
                offer: offer("https://example.test/v2.zip", short: offered, build: offeredBuild))
        }
        try expectClean(w.box); try expectEqual(try version(w.target), "1.0")
    }
    // A Homebrew offer for 3.0 whose download is really 2.0 (no build number to catch it).
    let lying = try world()
    try await expectRefusal("version_mismatch") {
        _ = try await installer(lying.box, downloader: lying.downloader).update(appAt: lying.target,
            offer: offer("https://example.test/v2.zip", short: "3.0", build: nil, sparkle: false))
    }
    try expectClean(lying.box); try expectEqual(try version(lying.target), "1.0")
    // Homebrew offers compare display versions; the cask's build part is not CFBundleVersion.
    let w = try world()
    let report = try await installer(w.box, downloader: w.downloader).update(appAt: w.target,
        offer: offer("https://example.test/v2.zip", short: "2.0", build: "abcdef", sparkle: false))
    try expectEqual(report.status, .installed)
}
check("real verifier: a third-party app passes with its own Team ID only; ad-hoc copies fail") {
    // The real-state prohibition takes precedence even over an explicit opt-in.
    let environment = ProcessInfo.processInfo.environment
    guard environment["PATCHED_FORBID_REAL_STATE"] != "1" else {
        print("SKIP real verifier: installed-app integration forbidden by PATCHED_FORBID_REAL_STATE"); return
    }
    guard environment["PATCHED_RUN_INSTALLED_APP_CHECKS"] == "1" else {
        print("SKIP real verifier: installed-app integration check disabled (explicit opt-in required)"); return
    }
    // Read-only against a real installed app; the ad-hoc copy is an APFS clone in a temp folder.
    let candidates = ["/Applications/Obsidian.app", "/Applications/DuckDuckGo.app", "/Applications/Google Chrome.app"]
    guard let real = candidates.first(where: { CodeSigningIdentity.teamID(ofBundleAt: URL(fileURLWithPath: $0)) != nil }),
          let team = CodeSigningIdentity.teamID(ofBundleAt: URL(fileURLWithPath: real)) else {
        print("SKIP real verifier: no signed third-party app found"); return
    }
    let verifier = SystemCodeVerifier(enforceRevocation: false)   // no network in checks
    try verifier.verifySignature(ofBundleAt: real, teamID: team)
    try await expectRefusal("signature_invalid") { try verifier.verifySignature(ofBundleAt: real, teamID: team == teamA ? teamB : teamA) }
    try verifier.assessGatekeeper(ofBundleAt: real)
    let box = try Sandbox()
    let copy = box.fixtures + "/AdHoc.app"
    try tool("/bin/cp", ["-c", "-R", real, copy])
    try tool("/usr/bin/codesign", ["--force", "-s", "-", copy])
    try await expectRefusal("signature_invalid") { try verifier.verifySignature(ofBundleAt: copy, teamID: team) }
    try await expectRefusal("notarisation_rejected") { try verifier.assessGatekeeper(ofBundleAt: copy) }
    try expectEqual(CodeSigningIdentity.teamID(ofBundleAt: URL(fileURLWithPath: copy)), nil, "ad-hoc copy has no Team ID")
    // A minimal ad-hoc bundle as well.
    let tiny = try makeApp(at: box.fixtures + "/Tiny.app", short: "1", build: "1")
    try FileManager.default.removeItem(atPath: tiny + "/Contents/MacOS/Example")
    try FileManager.default.removeItem(atPath: tiny + "/Contents/Frameworks")
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: tiny + "/Contents/MacOS/Example")
    try tool("/usr/bin/codesign", ["--force", "-s", "-", tiny])
    try await expectRefusal("signature_invalid") { try verifier.verifySignature(ofBundleAt: tiny, teamID: team) }
}
check("Gatekeeper output interpretation fails closed") {
    let p = "/x/A.app"
    try SystemCodeVerifier.interpretAssessment(status: 0, output: "\(p): accepted\nsource=Notarized Developer ID\n", path: p)
    try await expectRefusal("notarisation_rejected") {
        try SystemCodeVerifier.interpretAssessment(status: 0, output: "\(p): accepted\nsource=Developer ID\n", path: p)
    }
    try await expectRefusal("notarisation_rejected") {
        try SystemCodeVerifier.interpretAssessment(status: 0, output: "\(p): accepted\nsource=Notarized Developer ID\noverride=security disabled\n", path: p)
    }
    try await expectRefusal("notarisation_rejected") {
        try SystemCodeVerifier.interpretAssessment(status: 3, output: "\(p): rejected\nsource=no usable signature\n", path: p)
    }
    try await expectRefusal("notarisation_rejected") {
        try SystemCodeVerifier.interpretAssessment(status: 0, output: "/other.app: accepted\nsource=Notarized Developer ID\n", path: p)
    }
}

// MARK: 7. Running app

check("running app: refused without --quit, quit and relaunched with it, refused if it will not quit") {
    let w = try world()
    let running = FakeRunningApps()
    running.set(running: w.target, willQuit: false)
    let url = "https://example.test/v2.zip"
    try await expectRefusal("app_running") {
        _ = try await installer(w.box, downloader: w.downloader, running: running).update(appAt: w.target, offer: offer(url))
    }
    try expectEqual(w.downloader.calls, 0, "refused before downloading")
    try await expectRefusal("app_would_not_quit") {
        _ = try await installer(w.box, downloader: w.downloader, running: running).update(appAt: w.target, offer: offer(url),
                                                                                        options: UpdateOptions(quitIfRunning: true))
    }
    try expectEqual(try version(w.target), "1.0"); try expectClean(w.box)
    try expectEqual(running.relaunched, [], "never relaunched when it did not quit")
    running.set(running: w.target, willQuit: true)
    let report = try await installer(w.box, downloader: w.downloader, running: running).update(appAt: w.target, offer: offer(url),
                                                                                             options: UpdateOptions(quitIfRunning: true))
    try expectEqual(report.status, .installed); try expect(report.relaunched, "not relaunched")
    try expectEqual(running.relaunched, [w.target])
}
check("dry run verifies, changes nothing and cleans up") {
    let w = try world()
    let report = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"),
                                                                           options: UpdateOptions(dryRun: true))
    try expectEqual(report.status, .dryRunPassed); try expectEqual(report.toVersion, "2.0 (200)")
    try expectEqual(try version(w.target), "1.0"); try expectClean(w.box)
    try expect(journals(w.box).isEmpty, "dry run left a journal")
    try expect(installer(w.box).backups().isEmpty, "dry run made a backup")
}

// MARK: 8. Swap, journal and backup

check("swap succeeds, backup kept (only the newest), journal finished") {
    let w = try world()
    // An older backup from before must be pruned.
    let stale = w.box.locations.backups + "/" + bundleID + "/0.5-50"
    try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: true)
    let identityBefore = FileSafety.directoryIdentity(w.target)
    let report = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    try expectEqual(report.status, .installed); try expectEqual(report.fromVersion, "1.0 (100)"); try expectEqual(report.toVersion, "2.0 (200)")
    try expectEqual(try version(w.target), "2.0")
    let backups = installer(w.box).backups()
    try expectEqual(backups.count, 1); try expectEqual(backups[0].shortVersion, "1.0"); try expectEqual(backups[0].teamID, teamA)
    try expectEqual(FileSafety.directoryIdentity(backups[0].bundlePath!), identityBefore, "the old bundle itself was moved, not copied")
    try expect(!FileManager.default.fileExists(atPath: stale), "stale backup kept")
    let js = journals(w.box)
    try expectEqual(js.count, 1); try expectEqual(js[0].phase, .finished)
    try expectClean(w.box)
    // Permissions on private state.
    for dir in [w.box.locations.transactions, w.box.locations.backups, w.box.locations.downloads] {
        try expectEqual(FileSafety.mode(dir), 0o700, dir)
    }
    try expectEqual(FileSafety.mode(w.box.locations.transactions + "/" + js[0].id + ".json"), 0o600)
}
check("re-verification failure after the swap swaps back") {
    let w = try world()
    let verifier = FakeVerifier(failSignatureAt: [w.target], onlyVersion: "2.0")
    try await expectRefusal("verification_failed_after_swap") {
        _ = try await installer(w.box, downloader: w.downloader, verifier: verifier).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
    try expectEqual(try version(w.target), "1.0")
    try expectEqual(journals(w.box).map(\.phase), [.reverted])
    try expect(installer(w.box).backups().isEmpty, "no backup on revert")
    try expectClean(w.box)
}
check("busy lock and unfinished journals block a new update") {
    let w = try world()
    try FileSafety.makePrivateDirectory(w.box.locations.transactions)
    var held: AppLock? = try AppLock(directory: w.box.locations.transactions, bundleID: bundleID)
    try await expectRefusal("busy") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
    try expect(held != nil, "lock released early")
    held = nil
    do {
        _ = try await installer(w.box, downloader: w.downloader, crashAt: .swapped).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    } catch is SimulatedCrash {}
    try await expectRefusal("unfinished_transaction") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
}

// MARK: 9. Crash recovery

/// After recovery the app is either fully new with the old one backed up, or fully old; nothing is left over.
func expectConsistent(_ w: World, new: Bool, line: Int = #line) throws {
    try expectEqual(try version(w.target), new ? "2.0" : "1.0", "target version", line: line)
    let backups = installer(w.box).backups()
    if new { try expectEqual(backups.map(\.shortVersion), ["1.0"], "backup", line: line) }
    else { try expect(backups.isEmpty, "unexpected backup", line: line) }
    try expectClean(w.box, line: line)
}

check("crash mid-download: recover removes the leftovers") {
    let w = try world()
    w.downloader.crashMidway()
    do { _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip")); throw CheckFailure(description: "no crash") }
    catch is SimulatedCrash {}
    try expect(!(try FileManager.default.contentsOfDirectory(atPath: w.box.locations.downloads)).isEmpty, "crash should leave the download")
    let result = await installer(w.box).recover()
    try expectEqual(result.reports.map { try? $0.result.get() }, [.discarded])
    try expectConsistent(w, new: false)
}
check("crash with a dmg still mounted: recover detaches and cleans up") {
    let w = try world(format: .dmg)
    // Simulate a crash during unpacking: journal at staging, image attached at the journal's mount point.
    let id = UUID().uuidString
    let mount = w.box.locations.downloads + "/" + id + "/mnt"
    let staging = w.box.apps + "/.mac-updater-" + id
    try FileSafety.makePrivateDirectory(w.box.locations.transactions)
    try FileSafety.makePrivateDirectory(mount)
    try FileSafety.makeFreshPrivateDirectory(staging)
    var journal = TransactionJournal(id: id, kind: .update, phase: .staging, bundleID: bundleID, teamID: teamA,
        targetPath: w.target, stagingDir: staging, downloadDir: w.box.locations.downloads + "/" + id, mountPoint: mount,
        createdAt: "2026-11-05T00:00:00Z", updatedAt: "")
    try JournalStore(directory: w.box.locations.transactions).write(&journal)
    try Unpacker.attachDiskImage(w.archive, at: mount)
    try expect(Unpacker.isMountPoint(mount), "not mounted")
    let result = await installer(w.box).recover()
    try expectEqual(result.reports.map { try? $0.result.get() }, [.discarded])
    try expect(!(try tool("/usr/bin/hdiutil", ["info"])).contains(w.box.root), "image still attached")
    try expectConsistent(w, new: false)
}
check("crash at each journal state: recover reaches a consistent state, idempotently") {
    let expectations: [(TransactionJournal.Phase, Bool, RecoveryOutcome, Bool)] = [
        // phase, verification fails after swap?, outcome, ends new?
        (.staging, false, .discarded, false),
        (.prepared, false, .discarded, false),
        (.swapped, false, .completed, true),
        (.backingUp, false, .completed, true),
        (.swapBack, true, .reverted, false),
    ]
    for (phase, failAfterSwap, outcome, endsNew) in expectations {
        let w = try world()
        let verifier = FakeVerifier(failSignatureAt: failAfterSwap ? [w.target] : [], onlyVersion: "2.0")
        do {
            _ = try await installer(w.box, downloader: w.downloader, verifier: verifier, crashAt: phase)
                .update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
            throw CheckFailure(description: "no crash at \(phase)")
        } catch is SimulatedCrash {}
        let first = await installer(w.box, verifier: verifier).recover()
        try expectEqual(first.reports.map { try? $0.result.get() }, [outcome], "recover after crash at \(phase)")
        try expectConsistent(w, new: endsNew)
        do { let r = await installer(w.box).recover().reports; try expect(r.isEmpty, "second recover after \(phase) found work") }
    }
    // Crash after finishing is already consistent.
    let w = try world()
    do { _ = try await installer(w.box, downloader: w.downloader, crashAt: .finished).update(appAt: w.target, offer: offer("https://example.test/v2.zip")) }
    catch is SimulatedCrash {}
    do { let r = await installer(w.box).recover().reports; try expect(r.isEmpty, "finished journal recovered") }
    try expectConsistent(w, new: true)
}
check("a journal that says swap back is honoured even if the new app would now verify") {
    let w = try world()
    do {
        _ = try await installer(w.box, downloader: w.downloader, verifier: FakeVerifier(failSignatureAt: [w.target], onlyVersion: "2.0"), crashAt: .swapBack)
            .update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
        throw CheckFailure(description: "no crash")
    } catch is SimulatedCrash {}
    // The verifier used by recovery would accept the new app; the recorded decision must still win.
    let result = await installer(w.box).recover()
    try expectEqual(result.reports.map { try? $0.result.get() }, [.reverted])
    try expectConsistent(w, new: false)
}
check("unreadable journals block updates until someone looks") {
    let w = try world()
    try FileSafety.makePrivateDirectory(w.box.locations.transactions)
    try Data("{not json".utf8).write(to: URL(fileURLWithPath: w.box.locations.transactions + "/broken.json"))
    try await expectRefusal("unfinished_transaction") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
    try expectEqual(await installer(w.box).recover().unreadable, ["broken.json"])
}
check("a crash during recovery is itself recoverable") {
    let w = try world()
    do { _ = try await installer(w.box, downloader: w.downloader, crashAt: .swapped).update(appAt: w.target, offer: offer("https://example.test/v2.zip")) }
    catch is SimulatedCrash {}
    // recover() catches the crash as an error report and leaves the journal in backingUp.
    let interrupted = await installer(w.box, crashAt: .backingUp).recover()
    try expectEqual(interrupted.reports.count, 1)
    try expectEqual(JournalStore(directory: w.box.locations.transactions).unfinished().map(\.phase), [.backingUp])
    let second = await installer(w.box).recover()
    try expectEqual(second.reports.map { try? $0.result.get() }, [.completed])
    try expectConsistent(w, new: true)
}
check("recovery refuses what it cannot explain and leaves the journal") {
    let w = try world()
    do { _ = try await installer(w.box, downloader: w.downloader, crashAt: .swapped).update(appAt: w.target, offer: offer("https://example.test/v2.zip")) }
    catch is SimulatedCrash {}
    try FileManager.default.removeItem(atPath: w.target)   // someone deleted the app in between
    let result = await installer(w.box).recover()
    try expectEqual(result.reports.count, 1)
    guard case .failure(let refusal) = result.reports[0].result else { throw CheckFailure(description: "recovered the unexplainable") }
    try expectEqual(refusal.code, "recovery_ambiguous")
    try expectEqual(JournalStore(directory: w.box.locations.transactions).unfinished().count, 1, "journal kept")
}
check("journals with paths outside the expected places are refused") {
    let w = try world()
    try FileSafety.makePrivateDirectory(w.box.locations.transactions)
    var journal = TransactionJournal(id: "evil", kind: .update, phase: .staging, bundleID: bundleID, teamID: teamA,
        targetPath: w.target, stagingDir: w.box.root, downloadDir: nil, createdAt: "2026-11-05T00:00:00Z", updatedAt: "")
    try JournalStore(directory: w.box.locations.transactions).write(&journal)
    let result = await installer(w.box).recover()
    guard case .failure(let refusal)? = result.reports.first?.result else { throw CheckFailure(description: "evil journal recovered") }
    try expectEqual(refusal.code, "journal_error")
    try expect(FileManager.default.fileExists(atPath: w.box.fixtures), "something was deleted")
}

// MARK: Rollback

check("rollback round trip: update, rollback, update again") {
    let w = try world()
    let url = "https://example.test/v2.zip"
    _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer(url))
    try expectEqual(try version(w.target), "2.0")
    let back = try await installer(w.box).rollback(appAt: w.target)
    try expectEqual(back.status, .rolledBack); try expectEqual(back.toVersion, "1.0 (100)")
    try expectEqual(try version(w.target), "1.0")
    try expectEqual(installer(w.box).backups().map(\.shortVersion), ["2.0"], "replaced version kept as the backup")
    try expectClean(w.box)
    _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer(url))
    try expectEqual(try version(w.target), "2.0")
    try expectEqual(installer(w.box).backups().map(\.shortVersion), ["1.0"])
    try expectEqual(journals(w.box).map(\.phase), [.finished, .finished, .finished])
    try expectClean(w.box)
}
check("rollback verifies the backup's signature against the installed Team ID") {
    let w = try world()
    _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    let backup = installer(w.box).backups()[0].bundlePath!
    try Data(teamB.utf8).write(to: URL(fileURLWithPath: backup + "/Contents/Resources/fake-team"))
    try await expectRefusal("signature_invalid") { _ = try await installer(w.box).rollback(appAt: w.target) }
    try expectEqual(try version(w.target), "2.0"); try expectClean(w.box)
    try expect(FileManager.default.fileExists(atPath: backup), "backup must survive a refused rollback")
}
check("rollback with no backup is refused; crash during rollback recovers") {
    let w = try world()
    try await expectRefusal("no_backup") { _ = try await installer(w.box).rollback(appAt: w.target) }
    _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    for phase: TransactionJournal.Phase in [.prepared, .swapped] {
        do { _ = try await installer(w.box, crashAt: phase).rollback(appAt: w.target); throw CheckFailure(description: "no crash") }
        catch is SimulatedCrash {}
        let result = await installer(w.box).recover()
        try expectEqual(result.reports.count, 1)
        try expectClean(w.box)
    }
    // prepared -> discarded (still 2.0 with 1.0 backup); swapped -> completed (now 1.0 with 2.0 backup).
    try expectEqual(try version(w.target), "1.0")
    try expectEqual(installer(w.box).backups().map(\.shortVersion), ["2.0"])
}

// MARK: Review fixes (Phase 2a security review)

func crashUpdate(_ w: World, at phase: TransactionJournal.Phase, verifier: FakeVerifier = FakeVerifier(),
                 forceCopyBackup: Bool = false) async throws {
    do {
        _ = try await installer(w.box, downloader: w.downloader, verifier: verifier, crashAt: phase, forceCopyBackup: forceCopyBackup)
            .update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
        throw CheckFailure(description: "no crash at \(phase)")
    } catch is SimulatedCrash {}
}
func tamper(_ app: String) throws {
    let exe = URL(fileURLWithPath: app + "/Contents/MacOS/Example")
    let handle = try FileHandle(forWritingTo: exe)
    try handle.seekToEnd(); handle.write(Data("TAMPERED\n".utf8)); try handle.close()
}
func unfinished(_ box: Sandbox) -> [TransactionJournal] { JournalStore(directory: box.locations.transactions).unfinished() }

check("#6 relaunch only after a verified outcome: restored is relaunched, unresolved is left stopped") {
    let url = "https://example.test/v2.zip"
    // New app fails after the swap, old app verifies: restored and relaunched.
    var w = try world()
    var running = FakeRunningApps(); running.set(running: w.target, willQuit: true)
    try await expectRefusal("verification_failed_after_swap") {
        _ = try await installer(w.box, downloader: w.downloader, verifier: FakeVerifier(failSignatureAt: [w.target], onlyVersion: "2.0"),
                                running: running).update(appAt: w.target, offer: offer(url), options: UpdateOptions(quitIfRunning: true))
    }
    try expectEqual(running.relaunched, [w.target]); try expectEqual(try version(w.target), "1.0")
    // #2 too: the new app fails and the old one was modified in the meantime, so it no longer verifies.
    // Nothing is swapped back and the app stays stopped.
    w = try world()
    running = FakeRunningApps()
    let oldApp = w.target
    running.set(running: w.target, willQuit: true, duringQuit: { try? tamper(oldApp) })
    let staged = { (j: TransactionJournal) in j.stagedBundlePath }
    try await expectRefusal("unresolved") {
        _ = try await installer(w.box, downloader: w.downloader,
                                verifier: FakeVerifier(failSignatureAt: [w.target], onlyVersion: "2.0"), running: running)
            .update(appAt: w.target, offer: offer(url), options: UpdateOptions(quitIfRunning: true))
    }
    try expectEqual(running.relaunched, [], "unresolved must not relaunch")
    let pending = unfinished(w.box)
    try expectEqual(pending.map(\.phase), [.swapBack], "journal kept for recover")
    try expectEqual(try version(w.target), "2.0", "nothing swapped back")
    try expectEqual(try version(staged(pending[0])), "1.0", "old app left in place")
    // A journal write failing right after the swap: unverified, so not relaunched.
    w = try world()
    running = FakeRunningApps(); running.set(running: w.target, willQuit: true)
    try await expectRefusal("unresolved") {
        _ = try await installer(w.box, downloader: w.downloader, running: running, failJournalAt: .swapped)
            .update(appAt: w.target, offer: offer(url), options: UpdateOptions(quitIfRunning: true))
    }
    try expectEqual(running.relaunched, [], "unverified swap must not relaunch")
    try expectEqual(await installer(w.box).recover().reports.map { try? $0.result.get() }, [.completed], "recover finishes it")
}
check("#2 recovery will not swap back a restoration source that no longer verifies") {
    let w = try world()
    try await crashUpdate(w, at: .swapBack, verifier: FakeVerifier(failSignatureAt: [w.target], onlyVersion: "2.0"))
    let journal = unfinished(w.box)[0]
    try tamper(journal.stagedBundlePath)   // the outgoing app was replaced in the meantime
    let result = await installer(w.box).recover()
    guard case .failure(let refusal)? = result.reports.first?.result else { throw CheckFailure(description: "swapped back a tampered app") }
    try expectEqual(refusal.code, "unresolved")
    try expectEqual(try version(w.target), "2.0", "nothing swapped")
    try expect(FileManager.default.fileExists(atPath: journal.stagedBundlePath), "restoration source deleted")
    try expectEqual(unfinished(w.box).count, 1, "journal kept")
}
check("#4 an unexplained folder at the backup path keeps the original") {
    let w = try world()
    try await crashUpdate(w, at: .backingUp)
    let journal = unfinished(w.box)[0]
    try FileManager.default.createDirectory(atPath: journal.backupBundlePath!, withIntermediateDirectories: true)
    let result = await installer(w.box).recover()
    guard case .failure(let refusal)? = result.reports.first?.result else { throw CheckFailure(description: "recovered") }
    try expectEqual(refusal.code, "recovery_ambiguous")
    try expectEqual(try version(journal.stagedBundlePath), "1.0", "the original must survive")
    try expectEqual(unfinished(w.box).count, 1, "journal kept")
}
check("#7 cross-volume backup: copy verified and synced before the original goes; failure keeps it") {
    var w = try world()
    let report = try await installer(w.box, downloader: w.downloader, forceCopyBackup: true)
        .update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    try expectEqual(report.status, .installed)
    let finished = journals(w.box)[0]
    try expect(finished.backupCopyIdentity != nil, "copy identity not recorded")
    try expect(finished.backupCopyIdentity != finished.oldIdentity, "not a copy")
    try expectEqual(installer(w.box).backups().map(\.shortVersion), ["1.0"]); try expectClean(w.box)
    // The copy fails verification: the original stays in staging and nothing is half-written.
    w = try world()
    try await expectRefusal("unresolved") {
        _ = try await installer(w.box, downloader: w.downloader, verifier: FakeVerifier(failPartialCopies: true), forceCopyBackup: true)
            .update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
    let pending = unfinished(w.box)
    try expectEqual(pending.count, 1)
    try expectEqual(try version(pending[0].stagedBundlePath), "1.0", "original kept")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: pending[0].backupDir!)) ?? []
    try expect(!leftovers.contains { $0.hasPrefix(".partial-") }, "partial copy left: \(leftovers)")
}
check("#7/v2 crash around the cross-volume rename: recovery finishes from either location") {
    // Before the copy is recorded, after it is recorded (just before the rename), and after the rename
    // (before the original is deleted).
    for point in ["backup.copied", "backup.copyRecorded", "backup.renamed"] {
        let x = try world()
        do {
            _ = try await installer(x.box, downloader: x.downloader, forceCopyBackup: true, crashAtCheckpoint: point)
                .update(appAt: x.target, offer: offer("https://example.test/v2.zip"))
            throw CheckFailure(description: "no crash at \(point)")
        } catch is SimulatedCrash {}
        let pending = unfinished(x.box)
        try expectEqual(pending.count, 1, point)
        try expectEqual(pending[0].backupCopyIdentity != nil, point != "backup.copied", "copy recorded at \(point)")
        try expectEqual(try version(pending[0].stagedBundlePath), "1.0", "original still in staging at \(point)")
        let result = await installer(x.box, forceCopyBackup: true).recover()
        try expectEqual(result.reports.map { try? $0.result.get() }, [.completed], "recover after \(point)")
        try expectConsistent(x, new: true)
    }
}
check("#3 crash in backingUp then the installed executable is modified: recover does not finish") {
    let w = try world()
    try await crashUpdate(w, at: .backingUp)
    try tamper(w.target)
    let result = await installer(w.box).recover()
    // The old app still verifies, so it is put back; nothing of the original was deleted.
    try expectEqual(result.reports.map { try? $0.result.get() }, [.reverted])
    try expectEqual(try version(w.target), "1.0")
    try expect(installer(w.box).backups().isEmpty, "finished with a tampered app")
    // Same after the backup is in place (backedUp): refused, backup kept, journal kept.
    let v = try world()
    try await crashUpdate(v, at: .backedUp)
    try tamper(v.target)
    let second = await installer(v.box).recover()
    guard case .failure(let refusal)? = second.reports.first?.result else { throw CheckFailure(description: "recovered a tampered app") }
    try expectEqual(refusal.code, "unresolved")
    let journal = unfinished(v.box)[0]
    try expectEqual(try version(journal.backupBundlePath!), "1.0", "backup must survive")
    try expectEqual(journal.phase, .backedUp)
}
check("#1 Gatekeeper is repeated on the installed bundle; staged identity is re-checked before commit") {
    var w = try world()
    try await expectRefusal("verification_failed_after_swap") {
        _ = try await installer(w.box, downloader: w.downloader, verifier: FakeVerifier(failGatekeeperAt: [w.target], onlyVersion: "2.0"))
            .update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
    try expectEqual(try version(w.target), "1.0"); try expectClean(w.box)
    // The staged bundle is replaced while the app is being quit.
    w = try world()
    let running = FakeRunningApps()
    let apps = w.box.apps
    running.set(running: w.target, willQuit: true, duringQuit: {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: apps)) ?? [] where name.hasPrefix(".mac-updater-") {
            let staged = apps + "/" + name + "/Example.app"
            try? FileManager.default.removeItem(atPath: staged)
            _ = try? makeApp(at: staged, short: "2.0", build: "200", payload: "swapped in")
        }
    })
    try await expectRefusal("io_error") {
        _ = try await installer(w.box, downloader: w.downloader, running: running)
            .update(appAt: w.target, offer: offer("https://example.test/v2.zip"), options: UpdateOptions(quitIfRunning: true))
    }
    try expectEqual(try version(w.target), "1.0"); try expectClean(w.box)
}
check("#5 recursive deletes refuse paths outside the root, symlinked ancestors and ..") {
    let box = try Sandbox()
    let root = box.root + "/state"
    let precious = box.root + "/precious"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: precious + "/sub", withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: URL(fileURLWithPath: precious + "/sub/file"))
    try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: precious)
    try await expectRefusal("unsafe_path") { try FileSafety.removeTree(root + "/link/sub", within: root) }
    try await expectRefusal("unsafe_path") { try FileSafety.removeTree(precious + "/sub", within: root) }
    try await expectRefusal("unsafe_path") { try FileSafety.removeTree(root + "/../precious/sub", within: root) }
    try await expectRefusal("unsafe_path") { try FileSafety.removeTree(root, within: root) }
    try expect(FileManager.default.fileExists(atPath: precious + "/sub/file"), "precious data deleted")
    // A symlink inside the tree is removed as a link, not followed.
    try FileManager.default.createDirectory(atPath: root + "/tree", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: root + "/tree/out", withDestinationPath: precious)
    try FileSafety.removeTree(root + "/tree", within: root)
    try expect(!FileManager.default.fileExists(atPath: root + "/tree"), "tree not removed")
    try expect(FileManager.default.fileExists(atPath: precious + "/sub/file"), "followed a symlink inside the tree")
    // Pruning through a per-app backups folder that became a symlink deletes nothing behind it.
    let w = try world()
    try await crashUpdate(w, at: .backedUp)
    let appBackups = w.box.locations.backups + "/" + bundleID
    try FileManager.default.createDirectory(atPath: precious + "/old-backup", withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: appBackups, toPath: w.box.root + "/moved-backups")
    try FileManager.default.createSymbolicLink(atPath: appBackups, withDestinationPath: precious)
    _ = await installer(w.box).recover()
    try expect(FileManager.default.fileExists(atPath: precious + "/old-backup"), "pruned through a symlink")
    try expect(FileManager.default.fileExists(atPath: precious + "/sub/file"), "deleted user data")
}
check("#8 rollback refuses a backup that is not notarised") {
    let w = try world()
    _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    let backup = installer(w.box).backups()[0].bundlePath!
    try Data().write(to: URL(fileURLWithPath: backup + "/Contents/Resources/fake-not-notarised"))
    try await expectRefusal("notarisation_rejected") { _ = try await installer(w.box).rollback(appAt: w.target) }
    try expectEqual(try version(w.target), "2.0"); try expectClean(w.box)
    try expect(FileManager.default.fileExists(atPath: backup), "backup kept")
}
check("#9 unpack budget: free-space preflight and an expanding zip are refused and cleaned up") {
    let w = try world()
    let bomb = w.box.fixtures + "/bomb/Example.app"
    try makeApp(at: bomb, short: "2.0", build: "200")
    try Data(count: 64 * 1024 * 1024).write(to: URL(fileURLWithPath: bomb + "/Contents/Resources/zeros"))
    try zip(bomb, to: w.box.fixtures + "/bomb.zip")
    let zipped = FileSafety.lstatInfoSize(w.box.fixtures + "/bomb.zip")
    try expect(zipped < 1024 * 1024, "fixture not compressible (\(zipped))")
    w.downloader.serve("https://example.test/bomb.zip", from: w.box.fixtures + "/bomb.zip")
    let small = UnpackBudget(reserveBytes: 0, reservePerDownloadByte: 0, maxStagedFloor: 4 * 1024 * 1024,
                             maxStagedPerDownloadByte: 6, minFreeDuring: 0, pollInterval: 0.01)
    try await expectRefusal("unpack_too_large") {
        _ = try await installer(w.box, downloader: w.downloader, budget: small).update(appAt: w.target, offer: offer("https://example.test/bomb.zip"))
    }
    try expectClean(w.box); try expectEqual(try version(w.target), "1.0")
    let greedy = UnpackBudget(reserveBytes: Int64.max / 4, reservePerDownloadByte: 4, maxStagedFloor: 0,
                              maxStagedPerDownloadByte: 6, minFreeDuring: 0)
    try await expectRefusal("unpack_too_large") {
        _ = try await installer(w.box, downloader: w.downloader, budget: greedy).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    }
    try expectClean(w.box)
    try expectEqual(UnpackBudget.standard.maxStaged(downloadBytes: 10), 8 * 1024 * 1024 * 1024)
    try expectEqual(UnpackBudget.standard.maxStaged(downloadBytes: 2 * 1024 * 1024 * 1024), 12 * 1024 * 1024 * 1024)
}
check("#10 quit waits for replacement instances, and a relaunch before the swap is refused") {
    // Original exits, a replacement appears and stays: not done.
    nonisolated(unsafe) var calls = 0
    nonisolated(unsafe) var asked: [pid_t] = []
    let stuck = await QuitPolling.waitUntilNoneRemain(timeout: 0.3, interval: 0.01, enumerate: {
        calls += 1; return calls < 3 ? [100] : [101]
    }, requestQuit: { asked.append($0) })
    try expect(!stuck, "returned success while a replacement was running")
    try expectEqual(asked, [100, 101], "replacement not asked to quit")
    calls = 0; asked = []
    let done = await QuitPolling.waitUntilNoneRemain(timeout: 2, interval: 0.01, enumerate: {
        calls += 1; return calls == 1 ? [100] : calls == 2 ? [101] : []
    }, requestQuit: { asked.append($0) })
    try expect(done, "did not finish when all instances were gone"); try expectEqual(asked, [100, 101])
    // Installer: quit succeeds, then a helper relaunches the app before the swap.
    let w = try world()
    let running = FakeRunningApps()
    running.set(running: w.target, willQuit: true, respawnAfterQuit: true)
    try await expectRefusal("app_running") {
        _ = try await installer(w.box, downloader: w.downloader, running: running)
            .update(appAt: w.target, offer: offer("https://example.test/v2.zip"), options: UpdateOptions(quitIfRunning: true))
    }
    try expectEqual(try version(w.target), "1.0", "swapped while running"); try expectClean(w.box)
}

check("v2#1 budget: an over-budget extraction that finishes between polls is still refused") {
    let w = try world()
    let fat = w.box.fixtures + "/fat/Example.app"
    try makeApp(at: fat, short: "2.0", build: "200")
    try Data(count: 8 * 1024 * 1024).write(to: URL(fileURLWithPath: fat + "/Contents/Resources/zeros"))
    try zip(fat, to: w.box.fixtures + "/fat.zip")
    w.downloader.serve("https://example.test/fat.zip", from: w.box.fixtures + "/fat.zip")
    // Default poll interval (0.25 s): ditto finishes long before the first poll.
    let budget = UnpackBudget(reserveBytes: 0, reservePerDownloadByte: 0, maxStagedFloor: 1024 * 1024,
                              maxStagedPerDownloadByte: 1, minFreeDuring: 0)
    try expectEqual(budget.pollInterval, 0.25)
    try await expectRefusal("unpack_too_large") {
        _ = try await installer(w.box, downloader: w.downloader, budget: budget).update(appAt: w.target, offer: offer("https://example.test/fat.zip"))
    }
    try expectClean(w.box); try expectEqual(try version(w.target), "1.0")
}
check("v2#1 budget: too many entries are refused") {
    let w = try world()
    let many = w.box.fixtures + "/many/Example.app"
    try makeApp(at: many, short: "2.0", build: "200")
    for i in 0..<300 { try Data("x".utf8).write(to: URL(fileURLWithPath: many + "/Contents/Resources/f\(i)")) }
    try zip(many, to: w.box.fixtures + "/many.zip")
    w.downloader.serve("https://example.test/many.zip", from: w.box.fixtures + "/many.zip")
    let budget = UnpackBudget(reserveBytes: 0, reservePerDownloadByte: 0, maxStagedFloor: 1 << 40,
                              maxStagedPerDownloadByte: 1, minFreeDuring: 0, maxEntries: 100)
    try await expectRefusal("unpack_too_large") {
        _ = try await installer(w.box, downloader: w.downloader, budget: budget).update(appAt: w.target, offer: offer("https://example.test/many.zip"))
    }
    try expectClean(w.box)
    try expectEqual(UnpackBudget.standard.maxEntries, 200_000)
    let scan = FileSafety.boundedTreeScan(many, maxBytes: 1 << 40, maxEntries: 50)
    try expect(scan.entries == 51, "scan not bounded by entries: \(scan.entries)")
}
check("v2#1 a slow scan cannot hold up the timeout") {
    let box = try Sandbox()
    let big = box.fixtures + "/big"
    let handle = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: big, contents: nil); return big }())!
    for _ in 0..<64 { handle.write(Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })) }
    try handle.close()
    let started = Date()
    let output = ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", big, box.fixtures + "/big.zip"], timeout: 0.3,
                                   watchdog: { Thread.sleep(forTimeInterval: 5); return nil })
    let elapsed = Date().timeIntervalSince(started)
    try expect(output.timedOut, "did not time out: \(output.summary)")
    try expect(elapsed < 4, "timeout waited for the scan (\(elapsed) s)")
}
check("v2#3 recovery refuses while the app runs from an affected path; --quit quits; a restart is caught") {
    let crashed = { () async throws -> World in
        let w = try world()
        try await crashUpdate(w, at: .swapBack, verifier: FakeVerifier(failSignatureAt: [w.target], onlyVersion: "2.0"))
        return w
    }
    var w = try await crashed()
    var running = FakeRunningApps(); running.set(running: w.target, willQuit: true)   // the user restarted it
    var result = await installer(w.box, running: running).recover()
    guard case .failure(let refusal)? = result.reports.first?.result else { throw CheckFailure(description: "recovered while running") }
    try expectEqual(refusal.code, "app_running")
    try expectEqual(try version(w.target), "2.0", "swapped while running"); try expectEqual(unfinished(w.box).count, 1)
    result = await installer(w.box, running: running).recover(quitIfRunning: true)
    try expectEqual(result.reports.map { try? $0.result.get() }, [.reverted])
    try expectEqual(running.relaunched, [w.target]); try expectConsistent(w, new: false)
    // Quit works, then a helper starts it again before the swap.
    w = try await crashed()
    running = FakeRunningApps(); running.set(running: w.target, willQuit: true, respawnAfterQuit: true)
    result = await installer(w.box, running: running).recover(quitIfRunning: true)
    guard case .failure(let again)? = result.reports.first?.result else { throw CheckFailure(description: "swapped after restart") }
    try expectEqual(again.code, "app_running")
    try expectEqual(try version(w.target), "2.0"); try expectEqual(running.relaunched, [])
}
check("v2#4 failed detach keeps a cleanup-pending journal; recover retries") {
    let w = try world(format: .dmg)
    let id = UUID().uuidString
    let mount = w.box.locations.downloads + "/" + id + "/mnt"
    let staging = w.box.apps + "/.mac-updater-" + id
    try FileSafety.makePrivateDirectory(w.box.locations.transactions)
    try FileSafety.makePrivateDirectory(mount)
    try FileSafety.makeFreshPrivateDirectory(staging)
    var journal = TransactionJournal(id: id, kind: .update, phase: .staging, bundleID: bundleID, teamID: teamA,
        targetPath: w.target, stagingDir: staging, downloadDir: w.box.locations.downloads + "/" + id, mountPoint: mount,
        createdAt: "2026-11-05T00:00:00Z", updatedAt: "")
    try JournalStore(directory: w.box.locations.transactions).write(&journal)
    try Unpacker.attachDiskImage(w.archive, at: mount)
    defer { Unpacker.detachDiskImage(at: mount) }
    let failed = await installer(w.box, detacher: { _ in false }).recover()
    try expectEqual(failed.reports.count, 1)
    try expect(failed.reports[0].leftovers.contains { $0.contains(mount) }, "mount not reported: \(failed.reports[0].leftovers)")
    let pending = unfinished(w.box)
    try expectEqual(pending.map(\.phase), [.cleanupPending])
    try expect(Unpacker.isMountPoint(mount), "should still be mounted")
    try await expectRefusal("unfinished_transaction") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.dmg", format: .dmg))
    }
    let retried = await installer(w.box).recover()
    try expectEqual(retried.reports.map { try? $0.result.get() }, [.cleanedUp])
    try expect(!(try tool("/usr/bin/hdiutil", ["info"])).contains(w.box.root), "image still attached")
    try expectClean(w.box)
}
check("v2#4 failed directory removal keeps a cleanup-pending journal and reports it") {
    let w = try world()
    try await crashUpdate(w, at: .prepared)
    let staging = unfinished(w.box)[0].stagingDir
    chmod(w.box.apps, 0o555)
    let failed = await installer(w.box).recover()
    chmod(w.box.apps, 0o755)
    try expectEqual(failed.reports.map { try? $0.result.get() }, [.discarded])
    try expectEqual(failed.reports[0].leftovers, [staging])
    try expectEqual(unfinished(w.box).map(\.phase), [.cleanupPending])
    try expectEqual(unfinished(w.box)[0].cleanupPending ?? [], [staging])
    let retried = await installer(w.box).recover()
    try expectEqual(retried.reports.map { try? $0.result.get() }, [.cleanedUp])
    try expectConsistent(w, new: false)
    try expect(journals(w.box).isEmpty, "journal should be gone after a discard")
}
check("v2#5 Electron prereleases: beta to release accepted, release offer with beta download refused") {
    let electron = UpdateSource.electron(feed: URL(string: "https://example.test/latest-mac.yml")!)
    func facts(_ v: String) -> BundleFacts { BundleFacts(bundleID: bundleID, shortVersion: v, build: v, sparklePublicEDKey: nil) }
    let release = UpdateOffer(displayVersion: "2.0.0", downloadURL: URL(string: "https://example.test/a.zip")!, format: .zip, source: electron)
    try UpdateInstaller.checkVersions(staged: facts("2.0.0"), installed: facts("2.0.0-beta.1"), offer: release)
    try await expectRefusal("version_mismatch") {
        try UpdateInstaller.checkVersions(staged: facts("2.0.0-beta.1"), installed: facts("1.0.0"), offer: release)
    }
    try await expectRefusal("not_newer") {
        let beta = UpdateOffer(displayVersion: "2.0.0-beta.2", downloadURL: release.downloadURL, format: .zip, source: electron)
        try UpdateInstaller.checkVersions(staged: facts("2.0.0-beta.2"), installed: facts("2.0.0"), offer: beta)
    }
    // Same answer as Phase 1, from the same function.
    try expectEqual(SourceVersioning.isNewer(candidateShort: "2.0.0", candidateBuild: nil, installedShort: "2.0.0-beta.1",
                                             installedBuild: nil, source: electron), .success(true))
}
check("v2#6 full version in CFBundleVersion (Opera): offered, accepted, and up to date afterwards") {
    let cask = UpdateSource.homebrewCask(token: "opera")
    func facts(_ short: String, _ build: String) -> BundleFacts { BundleFacts(bundleID: bundleID, shortVersion: short, build: build, sparklePublicEDKey: nil) }
    let offer = UpdateOffer(displayVersion: "139.0.6053.38", downloadURL: URL(string: "https://example.test/o.zip")!, format: .zip, source: cask)
    try expectEqual(SourceVersioning.isNewer(candidateShort: "139.0.6053.38", candidateBuild: nil, installedShort: "139.0",
                                             installedBuild: "139.0.6053.22", source: cask), .success(true))
    try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.38"), installed: facts("139.0", "139.0.6053.22"), offer: offer)
    // Once installed, the same offer is no longer an update (no endless re-offer).
    try expectEqual(SourceVersioning.isNewer(candidateShort: "139.0.6053.38", candidateBuild: nil, installedShort: "139.0",
                                             installedBuild: "139.0.6053.38", source: cask), .success(false))
    // A download with a different full version is refused, including one newer than installed but older than offered.
    try await expectRefusal("version_mismatch") {
        try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.30"), installed: facts("139.0", "139.0.6053.22"), offer: offer)
    }
    // The raw short alone no longer satisfies a full-version offer when the build disagrees.
    try await expectRefusal("version_mismatch") {
        try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.38.1"), installed: facts("139.0", "139.0.6053.22"), offer: offer)
    }
    // Unchanged elsewhere: build counters, a build one component longer, App Store, Electron and Sparkle sources.
    try expectEqual(SourceVersioning.bundleVersion(short: "2.0", build: "4512", against: "2.0.1", source: cask), "2.0")
    try expectEqual(SourceVersioning.bundleVersion(short: "1.2", build: "1.2.100", against: "1.2.1", source: cask), "1.2")
    try expectEqual(SourceVersioning.isNewer(candidateShort: "1.2.1", candidateBuild: nil, installedShort: "1.2",
                                             installedBuild: "1.2.100", source: cask), .success(true))
    for other in [UpdateSource.appStore(trackID: 1),
                  .electron(feed: URL(string: "https://example.test/latest-mac.yml")!),
                  .sparkle(feed: URL(string: "https://example.test/a.xml")!)] {
        try expectEqual(SourceVersioning.bundleVersion(short: "139.0", build: "139.0.6053.38", against: "139.0.6053.38", source: other), "139.0")
    }
    // Split cask versions ("2.0,2.0.10" -> display 2.0): short equals the offer, so nothing is promoted.
    try expectEqual(SourceVersioning.bundleVersion(short: "2.0", build: "2.0.0.5", against: "2.0", source: cask), "2.0")
    // Installed build fuller than the offer: never downgraded, and not offered in Phase 1 either.
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.38"), installed: facts("139.0", "139.0.6053.38.1"), offer: offer)
    }
    try expectEqual(SourceVersioning.isNewer(candidateShort: "139.0.6053.38", candidateBuild: nil, installedShort: "139.0",
                                             installedBuild: "139.0.6053.38.1", source: cask), .success(false))
    // Build counters with a numeric prefix are not promoted against a one-component-longer offer (round-3 #1).
    try expectEqual(SourceVersioning.isNewer(candidateShort: "1.2.1", candidateBuild: nil, installedShort: "1.2",
                                             installedBuild: "1.2.100.1", source: cask), .success(true))
    try UpdateInstaller.checkVersions(staged: facts("1.2.1", "1.2.101.1"), installed: facts("1.2", "1.2.100.1"),
        offer: UpdateOffer(displayVersion: "1.2.1", downloadURL: offer.downloadURL, format: .zip, source: cask))
    // A download whose build exactly equals the offer installs even with a three-part short (round-3 #2).
    try UpdateInstaller.checkVersions(staged: facts("139.0.6053", "139.0.6053.38"), installed: facts("139.0", "139.0.6053.22"), offer: offer)
    // Round 4: three-part short, installed build ahead of the offer: refused by the raw-build guard.
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0.6053", "139.0.6053.38"), installed: facts("139.0.6053", "139.0.6053.40"), offer: offer)
    }
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0.6053", "139.0.6053.38"), installed: facts("139.0.6053", "139.0.6053.38.1"), offer: offer)
    }
    // Round 5: short precision differs between installed and download; still never a downgrade by build.
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.38"), installed: facts("139.0.6053", "139.0.6053.40"), offer: offer)
    }
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0.6053", "139.0.6053.38"), installed: facts("139.0", "139.0.6053.40"), offer: offer)
    }
    // Round 6: zero-padded components are the same numbers for prefix checks.
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.38"), installed: facts("139.00.6053", "139.00.6053.40"), offer: offer)
    }
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.00", "139.0.6053.38"), installed: facts("139.0", "139.0.6053.40"), offer: offer)
    }
    // Round 7: long zero padding and decorations canonicalise the same way as display comparison.
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.38"),
                                          installed: facts("139." + String(repeating: "0", count: 19), "139.0.6053.40"), offer: offer)
    }
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.38"), installed: facts("v139.0", "139.0.6053.40"), offer: offer)
    }
    // Round 8: unparseable installed versions are refused when the download relies on its build;
    // decorated builds and huge components compare exactly.
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0", "139.0.6053.38"), installed: facts("139.0.", "139.0.6053.40"), offer: offer)
    }
    try await expectRefusal("not_newer") {
        try UpdateInstaller.checkVersions(staged: facts("139.0.6053", "139.0.6053.38"), installed: facts("139.0.6053", "v139.0.6053.40"), offer: offer)
    }
    let huge = UpdateOffer(displayVersion: "1.0.9223372036854775809.1", downloadURL: offer.downloadURL, format: .zip, source: cask)
    try await expectRefusal("version_mismatch") {
        try UpdateInstaller.checkVersions(staged: facts("1.0", "1.0.9223372036854775808.1"), installed: facts("1.0", "1.0.0.1"), offer: huge)
    }
    try UpdateInstaller.checkVersions(staged: facts("1.0", "1.0.9223372036854775809.1"), installed: facts("1.0", "1.0.0.1"), offer: huge)
    // Round 9: offer build equal to display must not reopen the saturating fallback.
    let hugeBoth = UpdateOffer(displayVersion: "1.0.9223372036854775809.1", buildVersion: "1.0.9223372036854775809.1",
                               downloadURL: offer.downloadURL, format: .zip, source: cask)
    try await expectRefusal("version_mismatch") {
        try UpdateInstaller.checkVersions(staged: facts("1.0", "1.0.9223372036854775808.1"), installed: facts("1.0", "1.0.0.1"), offer: hugeBoth)
    }
    // A genuine short-version advance with plain counters is unaffected.
    try UpdateInstaller.checkVersions(staged: facts("2.1", "2100"), installed: facts("2.0", "4512"),
        offer: UpdateOffer(displayVersion: "2.1", downloadURL: offer.downloadURL, format: .zip, source: cask))
    // Homebrew split version "2.0,2.0.10": a bundle built 2.0.5 is not the promised download.
    let split = UpdateOffer(displayVersion: "2.0", buildVersion: "2.0.10", downloadURL: offer.downloadURL, format: .zip, source: cask)
    try await expectRefusal("version_mismatch") {
        try UpdateInstaller.checkVersions(staged: facts("2.0", "2.0.5"), installed: facts("1.9", "1.9"), offer: split)
    }
    try UpdateInstaller.checkVersions(staged: facts("2.0", "2.0.10"), installed: facts("1.9", "1.9"), offer: split)
    // A split build that is not a version (download id) imposes nothing.
    let opaque = UpdateOffer(displayVersion: "2.0", buildVersion: "a1b2c3", downloadURL: offer.downloadURL, format: .zip, source: cask)
    try UpdateInstaller.checkVersions(staged: facts("2.0", "2.0.5"), installed: facts("1.9", "1.9"), offer: opaque)
    // Electron prerelease offer still refuses a release download with a refined build.
    let electron = UpdateSource.electron(feed: URL(string: "https://example.test/latest-mac.yml")!)
    let beta = UpdateOffer(displayVersion: "2.0.0-beta.1", downloadURL: offer.downloadURL, format: .zip, source: electron)
    try await expectRefusal("version_mismatch") {
        try UpdateInstaller.checkVersions(staged: facts("2.0.0", "2.0.0.0"), installed: facts("1.0.0", "1.0.0"), offer: beta)
    }
}
check("v2 the installer itself refuses offers that are not installable") {
    let w = try world()
    let app = InstalledApp(name: "Example", path: w.target, bundleID: bundleID, shortVersion: "1.0", build: "100")
    let o = offer("https://example.test/v2.zip", sparkle: false)
    let outcome = AppCheckOutcome(app: app, teamID: teamA, source: o.source, lowConfidence: true, installable: false,
                                  result: .updateAvailable(o))
    try await expectRefusal("not_installable") { _ = try await installer(w.box, downloader: w.downloader).update(outcome) }
    try await expectRefusal("not_installable") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: o, installable: false)
    }
    try expectEqual(w.downloader.calls, 0)
    let ok = AppCheckOutcome(app: app, teamID: teamA, source: o.source, lowConfidence: false, installable: true, result: .updateAvailable(o))
    try expectEqual(try await installer(w.box, downloader: w.downloader).update(ok).status, .installed)
}

check("review 2: the installer refuses a Mac App Store app (receipt) before downloading, even when installable") {
    let w = try world()
    let receipt = w.target + "/Contents/_MASReceipt"
    try FileManager.default.createDirectory(atPath: receipt, withIntermediateDirectories: true)
    try Data("r".utf8).write(to: URL(fileURLWithPath: receipt + "/receipt"))
    let app = InstalledApp(name: "Example", path: w.target, bundleID: bundleID, shortVersion: "1.0", build: "100", isAppStore: true)
    let o = offer("https://example.test/v2.zip", sparkle: false)
    let outcome = AppCheckOutcome(app: app, teamID: teamA, source: o.source, lowConfidence: false, installable: true, result: .updateAvailable(o))
    try await expectRefusal("app_store_managed") { _ = try await installer(w.box, downloader: w.downloader).update(outcome) }
    try await expectRefusal("app_store_managed") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: o, installable: true)
    }
    try expectEqual(w.downloader.calls, 0, "nothing may be downloaded for an App Store app")
}

check("the installer refuses a wrapped iPhone/iPad app from the App Store before downloading, by layout and by flag") {
    let w = try world()
    let o = offer("https://example.test/v2.zip", sparkle: false)
    // By layout: Wrapper/iTunesMetadata.plist, even for a caller that says nothing about it.
    let wrapper = w.target + "/Wrapper"
    try FileManager.default.createDirectory(atPath: wrapper, withIntermediateDirectories: true)
    try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: wrapper + "/iTunesMetadata.plist"))
    try await expectRefusal("app_store_managed") {
        _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: o, installable: true)
    }
    // By flag: the outcome says wrapped, whatever is on disk.
    let plain = try world()
    let app = InstalledApp(name: "Example", path: plain.target, bundleID: bundleID, shortVersion: "1.0", build: "100", isWrappedIOSApp: true)
    try expect(app.isAppStore, "a wrapped iOS app is App Store owned")
    let outcome = AppCheckOutcome(app: app, teamID: teamA, source: o.source, lowConfidence: false, installable: true, result: .updateAvailable(o))
    try await expectRefusal("app_store_managed") { _ = try await installer(plain.box, downloader: plain.downloader).update(outcome) }
    try expectEqual(w.downloader.calls + plain.downloader.calls, 0, "nothing may be downloaded for a wrapped iOS app")
}

check("v3#1 a staging folder that cannot be inspected keeps a cleanup-pending journal") {
    let w = try world()
    w.downloader.crashMidway()
    do { _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip")); throw CheckFailure(description: "no crash") }
    catch is SimulatedCrash {}
    let staging = unfinished(w.box)[0].stagingDir
    chmod(w.box.apps, 0o000)   // traversal denied: the staging folder's existence cannot be established
    let failed = await installer(w.box).recover()
    chmod(w.box.apps, 0o755)
    try expectEqual(failed.reports.count, 1)
    try expect(failed.reports[0].leftovers.contains(staging), "staging not reported: \(failed.reports[0].leftovers)")
    try expectEqual(unfinished(w.box).map(\.phase), [.cleanupPending], "journal must survive")
    try expect(FileManager.default.fileExists(atPath: staging), "fixture: staging should still be there")
    let retried = await installer(w.box).recover()
    try expectEqual(retried.reports.map { try? $0.result.get() }, [.cleanedUp])
    try expectConsistent(w, new: false)
    // removeTree itself refuses rather than treating "cannot tell" as "gone".
    try FileManager.default.createDirectory(atPath: w.box.apps + "/locked/inner", withIntermediateDirectories: true)
    chmod(w.box.apps + "/locked", 0o000)
    defer { chmod(w.box.apps + "/locked", 0o755) }
    try await expectRefusal("io_error") { try FileSafety.removeTree(w.box.apps + "/locked/inner", within: w.box.apps) }
}
check("v3#2 resuming a cleanup that will prune backups re-verifies the installed app first") {
    let w = try world()
    // A stale backup that cannot be pruned (its folder is read-only), so finishing leaves cleanupPending.
    let stale = w.box.locations.backups + "/" + bundleID + "/0.5-50"
    try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: URL(fileURLWithPath: stale + "/file"))
    chmod(stale, 0o555)
    defer { chmod(stale, 0o755) }
    let report = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer("https://example.test/v2.zip"))
    try expectEqual(report.status, .installed)
    try expect(report.leftovers.contains(stale), "prune failure not reported: \(report.leftovers)")
    let pending = unfinished(w.box)
    try expectEqual(pending.map(\.phase), [.cleanupPending]); try expectEqual(pending[0].cleanupThen, .finished)
    // The installed app goes bad before recovery runs.
    let exe = w.target + "/Contents/MacOS/Example"
    let original = try Data(contentsOf: URL(fileURLWithPath: exe))
    try tamper(w.target)
    chmod(stale, 0o755)   // pruning would now succeed: only the verification can stop it
    let result = await installer(w.box).recover()
    guard case .failure(let refusal)? = result.reports.first?.result else { throw CheckFailure(description: "pruned for a bad app") }
    try expectEqual(refusal.code, "unresolved")
    try expect(FileManager.default.fileExists(atPath: stale + "/file"), "older backup pruned")
    try expectEqual(installer(w.box).backups().map(\.shortVersion), ["1.0"], "backup kept")
    try expectEqual(unfinished(w.box).map(\.phase), [.cleanupPending])
    try original.write(to: URL(fileURLWithPath: exe))
    let fixed = await installer(w.box).recover()
    try expectEqual(fixed.reports.map { try? $0.result.get() }, [.cleanedUp])
    try expect(!FileManager.default.fileExists(atPath: stale), "prune did not resume")
}
check("v3#3 the final scan runs under the deadline: a fast child with a slow final scan times out") {
    let box = try Sandbox()
    try Data("x".utf8).write(to: URL(fileURLWithPath: box.fixtures + "/small"))
    let started = Date()
    let output = ProcessRunner.run("/usr/bin/ditto", [box.fixtures + "/small", box.fixtures + "/copy"], timeout: 0.5,
                                   watchdog: { Thread.sleep(forTimeInterval: 3); return nil })
    let elapsed = Date().timeIntervalSince(started)
    try expect(output.timedOut, "final scan escaped the timeout")
    try expect(!output.succeeded, "reported success without a final verdict")
    try expect(elapsed < 2, "waited for the slow scan (\(elapsed) s)")
}
check("v3#6 the periodic watchdog runs while the child runs and stops it early") {
    let box = try Sandbox()
    let big = box.fixtures + "/big"
    FileManager.default.createFile(atPath: big, contents: nil)
    let handle = FileHandle(forWritingAtPath: big)!
    for _ in 0..<64 { handle.write(Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })) }
    try handle.close()
    var started = Date()
    let normal = ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", big, box.fixtures + "/a.zip"], timeout: 120)
    let fullRun = Date().timeIntervalSince(started)
    try expect(normal.succeeded && fullRun > 0.25, "fixture too fast to tell (\(fullRun) s)")
    final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0 }
    let calls = Counter()
    started = Date()
    let stopped = ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", big, box.fixtures + "/b.zip"], timeout: 120, pollInterval: 0.02,
                                    watchdog: { calls.lock.withLock { calls.n += 1; return calls.n >= 3 ? "stop" : nil } })
    let elapsed = Date().timeIntervalSince(started)
    try expectEqual(stopped.abortedBy, "stop")
    try expectEqual(calls.lock.withLock { calls.n }, 3, "watchdog invocations")
    try expect(elapsed < fullRun * 0.6, "not stopped before normal completion (\(elapsed) s vs \(fullRun) s)")
    try expect(!stopped.succeeded && stopped.status != 0, "child was not terminated")
}
check("v3#4 discard-only recovery leaves an untouched running app alone") {
    for quit in [false, true] {
        let w = try world()
        try await crashUpdate(w, at: .prepared)
        let running = FakeRunningApps(); running.set(running: w.target, willQuit: true)
        let result = await installer(w.box, running: running).recover(quitIfRunning: quit)
        try expectEqual(result.reports.map { try? $0.result.get() }, [.discarded], "quit=\(quit)")
        try expectEqual(running.quitRequests, 0, "quit an unaffected app")
        try expectEqual(running.relaunched, [])
        try expectConsistent(w, new: false)
    }
}
check("v3#5 rollback output keeps cleanup warnings") {
    let line = OutcomeText.line(name: "Example", status: "rolled_back", from: "2.0", to: "1.0", backupFolder: "/b",
                                reason: "cleanup_incomplete", detail: "could not remove (run `mac-updater recover`): /x")
    try expect(line.contains("warning: could not remove"), line)
    let installed = OutcomeText.line(name: "Example", status: "installed", from: "1.0", to: "2.0", backupFolder: "/b",
                                     reason: "cleanup_incomplete", detail: "could not remove: /x")
    try expect(installed.contains("warning: could not remove"), installed)
}

// MARK: Source guards

check("no shell anywhere and processes only through the fixed-path runner") {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")
    let files = (FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String]) ?? []
    try expect(files.count > 10, "source tree not found")
    for relative in files where relative.hasSuffix(".swift") {
        let text = try String(contentsOfFile: sources.path + "/" + relative, encoding: .utf8)
        for forbidden in ["/bin/sh", "/bin/bash", "/bin/zsh", "\"-c\""] {
            try expect(!text.contains(forbidden), "\(relative) mentions \(forbidden)")
        }
        if relative.hasPrefix("UpdateInstaller/") && relative != "UpdateInstaller/ProcessRunner.swift" {
            try expect(!text.contains("Process()"), "\(relative) starts a process outside ProcessRunner")
        }
    }
    try expectEqual(ProcessRunner.allowedTools, ["/usr/bin/ditto", "/usr/bin/hdiutil", "/usr/sbin/spctl",
                                                 "/usr/sbin/pkgutil", "/usr/bin/open", "/usr/bin/codesign"])
    // `pkgutil` is only for the admin path; `open` for the admin path and for reopening Patched after its own
    // update; `codesign` (verify only) for that self-update. Nothing else names them.
    for relative in files where relative.hasSuffix(".swift") && relative.hasPrefix("UpdateInstaller/") {
        let text = try String(contentsOfFile: sources.path + "/" + relative, encoding: .utf8)
        if relative != "UpdateInstaller/AdminUpdates.swift" && relative != "UpdateInstaller/ProcessRunner.swift" {
            try expect(!text.contains("/usr/sbin/pkgutil"), "\(relative) runs an admin-only tool")
            if relative != "UpdateInstaller/SelfUpdate.swift" {
                try expect(!text.contains("/usr/bin/open") && !text.contains("/usr/bin/codesign"), "\(relative) runs a tool it should not")
            }
        }
    }
    try expectEqual(ProcessRunner.run("/bin/ls", [], timeout: 5).status, -1, "tool outside the allow-list ran")
}

registerAdminChecks()
registerSelfUpdateChecks()

// Run only the temporary-root migration checks when requested explicitly.
if Array(CommandLine.arguments.dropFirst()) == ["--migration"] { cases.removeAll() }
// The read-only real-verifier check alone, so the gate can run it without lifting the real-state
// tripwire from the rest of the suite. It reads installed app signatures and writes only temp clones.
let realVerifierOnly = Array(CommandLine.arguments.dropFirst()) == ["--real-verifier-only"]
if realVerifierOnly { cases.removeAll { !$0.0.hasPrefix("real verifier:") } }
if !realVerifierOnly { registerMigrationChecks() }

// MARK: Runner

var failures = 0
for (name, action) in cases {
    do { try await action(); print("PASS update-installer: \(name)") }
    catch { failures += 1; print("FAIL update-installer: \(name): \(error)") }
}
print("update-installer checks: \(cases.count) cases, \(failures) failures")
exit(failures == 0 ? 0 : 1)
