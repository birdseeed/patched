import Foundation
import CryptoKit
import Darwin
import UpdateSources
@_spi(Testing) import UpdateInstaller

// Patched updating itself. Everything runs in temporary folders with a throwaway Ed25519 key and a fake
// downloader; the real release key's private half is never used, and nothing is fetched or reopened.

private let patchedID = PatchedReleaseKey.bundleID
private let downloadBase = "https://github.com/birdseeed/patched/releases/download/"

private func release(_ version: String, assets: Bool = true) -> PatchedRelease {
    let base = downloadBase + "v" + version + "/Patched-" + version + ".zip"
    return PatchedRelease(version: version, pageURL: URL(string: "https://github.com/birdseeed/patched/releases/tag/v" + version)!,
                          assets: assets ? PatchedReleaseAssets(zipURL: URL(string: base)!, signatureURL: URL(string: base + ".sig")!) : nil)
}

/// "codesign" for fixtures: refuses a bundle carrying Resources/fake-unsigned, or one at a chosen path.
private final class FakeCodeCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var failAt: Set<String> = []
    var paths: [String] { lock.withLock { _paths } }
    var check: @Sendable (String) throws -> Void {
        { [self] path in
            lock.withLock { _paths.append(path) }
            if failAt.contains(path) { throw InstallRefusal.signatureInvalid("fake: refused at \(path)") }
            if FileManager.default.fileExists(atPath: path + "/Contents/Resources/fake-unsigned") {
                throw InstallRefusal.signatureInvalid("fake: not validly signed")
            }
        }
    }
}

private final class SelfRig {
    let sandbox: Sandbox
    let key = Curve25519.Signing.PrivateKey()
    let downloader = FakeDownloader()
    let code = FakeCodeCheck()
    var appPath: String { sandbox.apps + "/Patched.app" }
    var backups: String { sandbox.state + "/backups" }
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    init(installed: String = "0.1.0") throws {
        sandbox = try Sandbox()
        try makeApp(at: appPath, id: patchedID, short: installed, build: "10", team: nil, payload: "old")
    }

    func updater(running: String = "0.1.0", publicKey: String? = nil) -> SelfUpdater {
        SelfUpdater(appPath: appPath, runningVersion: running, backupsRoot: backups, downloader: downloader,
                    codeCheck: code.check, publicKey: publicKey ?? self.publicKey)
    }

    /// Builds `Patched-<claimed>.zip` holding a Patched.app of `contains`, signs it with `signer` (the rig's key
    /// by default) and serves both files at the release URLs for `claimed`.
    @discardableResult
    func publish(_ claimed: String, contains: String? = nil, id: String = patchedID, signer: Curve25519.Signing.PrivateKey? = nil,
                 signature: String? = nil, serveSignature: Bool = true, tamper: Bool = false, unsigned: Bool = false,
                 extra: ((String) throws -> Void)? = nil) throws -> PatchedRelease {
        let folder = sandbox.fixtures + "/release-" + UUID().uuidString
        let app = folder + "/Patched.app"
        try makeApp(at: app, id: id, short: contains ?? claimed, build: "20", team: nil, payload: "new")
        if unsigned { try Data().write(to: URL(fileURLWithPath: app + "/Contents/Resources/fake-unsigned")) }
        try extra?(app)
        let zipPath = sandbox.fixtures + "/Patched-\(claimed)-\(UUID().uuidString).zip"
        try zip(app, to: zipPath)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: zipPath))
        let computed = try (signer ?? key).signature(for: bytes).base64EncodedString() + "\n"
        let sigText = signature ?? computed
        let sigPath = zipPath + ".sig"
        try Data(sigText.utf8).write(to: URL(fileURLWithPath: sigPath))
        let r = release(claimed)
        downloader.serve(r.assets!.zipURL.absoluteString, from: zipPath, appendBytes: tamper ? 1 : 0)
        if serveSignature { downloader.serve(r.assets!.signatureURL.absoluteString, from: sigPath) }
        return r
    }

    struct Snapshot: Equatable { let identity: FileSafety.Identity?; let version: String?; let executable: Data? }
    func snapshot() -> Snapshot {
        Snapshot(identity: FileSafety.directoryIdentity(appPath), version: try? version(appPath),
                 executable: FileManager.default.contents(atPath: appPath + "/Contents/MacOS/Example"))
    }
    /// The installed Patched is exactly as before and nothing was left beside it or in backups.
    func expectUntouched(_ before: Snapshot, _ what: String) throws {
        try expect(snapshot() == before, "\(what): the installed Patched changed")
        try expect(try version(appPath) == before.version, "\(what): version changed")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: sandbox.apps)) ?? []).filter { $0 != "Patched.app" }
        try expect(leftovers.isEmpty, "\(what): left beside the app: \(leftovers)")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: backups + "/" + patchedID)) ?? []
        try expect(kept.isEmpty, "\(what): a backup was made: \(kept)")
    }
}

private func expectSelfRefusal(_ code: String, _ what: String, _ body: () async throws -> Void) async throws {
    do { try await body() } catch let refusal as InstallRefusal {
        try expect(refusal.code == code, "\(what): expected \(code), got \(refusal)")
        return
    }
    throw CheckFailure(description: "\(what): expected \(code), got success")
}

func registerSelfUpdateChecks() {
    check("self update: a signed newer release replaces Patched, keeps the old one as a backup, and leaves nothing behind") {
        let rig = try SelfRig()
        let r = try rig.publish("0.2.0")
        let report = try await rig.updater().install(r)
        try expectEqual(try version(rig.appPath), "0.2.0", "installed")
        try expectEqual(report.toVersion, "0.2.0"); try expectEqual(report.fromVersion, "0.1.0")
        let backup = try report.backupPath.unwrapChecked()
        try expect(backup.hasPrefix(rig.backups + "/im.patched.app/previous-") && backup.hasSuffix("/Patched.app"), "backup at \(backup)")
        try expectEqual(try version(backup), "0.1.0", "backup version")
        try expect(report.note == nil, "note: \(report.note ?? "")")
        let beside = try FileManager.default.contentsOfDirectory(atPath: rig.sandbox.apps)
        try expectEqual(beside, ["Patched.app"], "left beside the app")
        // The signature was checked before anything was unpacked: the code check saw only the staged and installed app.
        try expectEqual(rig.code.paths.count, 2, "code checks: \(rig.code.paths)")
        try expect(rig.code.paths.last == rig.appPath, "the installed app was not re-checked after the swap")
        // A second self-update keeps only the newest backup.
        let next = try rig.publish("0.3.0")
        let second = try await rig.updater(running: "0.2.0").install(next)
        try expectEqual(try version(rig.appPath), "0.3.0")
        let kept = try FileManager.default.contentsOfDirectory(atPath: rig.backups + "/im.patched.app")
        try expect(kept.count == 1 && second.backupPath?.contains(kept[0]) == true, "backups kept: \(kept)")
        try expectEqual(try version(try second.backupPath.unwrapChecked()), "0.2.0")
    }

    check("self update: the signature must verify against the key; wrong key, tampered zip and missing or malformed signatures are refused") {
        let other = Curve25519.Signing.PrivateKey()
        let cases: [(String, (SelfRig) throws -> PatchedRelease)] = [
            ("wrong key", { try $0.publish("0.2.0", signer: other) }),
            ("tampered zip", { try $0.publish("0.2.0", tamper: true) }),
            ("missing signature", { try $0.publish("0.2.0", serveSignature: false) }),
            ("empty signature", { try $0.publish("0.2.0", signature: "") }),
            ("garbage signature", { try $0.publish("0.2.0", signature: "not base64 at all\n") }),
            ("short signature", { try $0.publish("0.2.0", signature: Data(repeating: 1, count: 32).base64EncodedString()) }),
            ("two signatures", { rig in
                let a = Data(repeating: 1, count: 64).base64EncodedString()
                return try rig.publish("0.2.0", signature: a + "\n" + a + "\n")
            }),
        ]
        for (name, make) in cases {
            let rig = try SelfRig()
            let r = try make(rig)
            let before = rig.snapshot()
            try await expectSelfRefusal("release_signature_invalid", name) { _ = try await rig.updater().install(r) }
            try rig.expectUntouched(before, name)
            try expect(rig.code.paths.isEmpty, "\(name): staged checks ran before the signature verified")
        }
        // The same zip verifies with the right key: the fixture itself is sound.
        let rig = try SelfRig()
        _ = try await rig.updater().install(try rig.publish("0.2.0"))
        try expectEqual(try version(rig.appPath), "0.2.0")
    }

    check("self update: production updaters trust only the release key built into Patched") {
        try expectEqual(PatchedReleaseKey.publicKeyBase64, "3pXCQuK7pRsCXKXhXwld3tJw+yisZpSMKef3OjEsk/k=")
        let raw = try Data(base64Encoded: PatchedReleaseKey.publicKeyBase64).unwrapChecked()
        try expect(raw.count == 32 && (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil, "embedded key is not a valid key")
        // A zip signed by any other key (here the throwaway one) is refused by the production initialiser.
        let rig = try SelfRig()
        let r = try rig.publish("0.2.0")
        let before = rig.snapshot()
        let production = SelfUpdater(appPath: rig.appPath, runningVersion: "0.1.0", backupsRoot: rig.backups,
                                     downloader: rig.downloader, codeCheck: rig.code.check)
        try await expectSelfRefusal("release_signature_invalid", "production key") { _ = try await production.install(r) }
        try rig.expectUntouched(before, "production key")
    }

    check("self update: the staged app must be Patched, exactly the release version, and newer; failed codesign is refused") {
        let cases: [(String, String, (SelfRig) throws -> PatchedRelease, String)] = [
            ("wrong bundle ID", "bundle_not_found", { try $0.publish("0.2.0", id: "com.example.other") }, "0.1.0"),
            ("version is not the tag", "version_mismatch", { try $0.publish("0.2.0", contains: "0.3.0") }, "0.1.0"),
            ("older signed zip replayed under a newer tag", "version_mismatch", { try $0.publish("0.2.0", contains: "0.0.9") }, "0.1.0"),
            ("failed code signature", "signature_invalid", { try $0.publish("0.2.0", unsigned: true) }, "0.1.0"),
            ("symlink out of the bundle", "unsafe_symlink", { try $0.publish("0.2.0", extra: { app in
                try FileManager.default.createSymbolicLink(atPath: app + "/Contents/Resources/escape", withDestinationPath: "/etc") }) }, "0.1.0"),
            ("installed copy already newer than the release", "not_newer", { try $0.publish("0.2.0") }, "0.3.0"),
        ]
        for (name, code, make, installed) in cases {
            let rig = try SelfRig(installed: installed)
            let r = try make(rig)
            let before = rig.snapshot()
            try await expectSelfRefusal(code, name) { _ = try await rig.updater().install(r) }
            try rig.expectUntouched(before, name)
        }
        // Equal or older releases are refused before anything is downloaded (replay of an old signed release).
        for (claimed, running) in [("0.1.0", "0.1.0"), ("0.0.9", "0.1.0"), ("0.2.0", "0.2.0")] {
            let rig = try SelfRig(installed: running)
            let r = try rig.publish(claimed)
            let before = rig.snapshot()
            try await expectSelfRefusal("not_newer", "\(claimed) over \(running)") { _ = try await rig.updater(running: running).install(r) }
            try rig.expectUntouched(before, "\(claimed) over \(running)")
            try expectEqual(rig.downloader.calls, 0, "downloaded for \(claimed) over \(running)")
        }
    }

    check("self update: a new app that fails its check after the swap is swapped back") {
        let rig = try SelfRig()
        let r = try rig.publish("0.2.0")
        let before = rig.snapshot()
        rig.code.failAt = [rig.appPath]
        try await expectSelfRefusal("verification_failed_after_swap", "post-swap") { _ = try await rig.updater().install(r) }
        try rig.expectUntouched(before, "post-swap")
    }

    check("self update: Patched that would need admin rights, or is not an installed Patched.app, is refused before any download") {
        let rig = try SelfRig()
        let r = try rig.publish("0.2.0")
        let before = rig.snapshot()
        chmod(rig.sandbox.apps, 0o555)
        try await expectSelfRefusal("needs_admin", "read-only folder") { _ = try await rig.updater().install(r) }
        chmod(rig.sandbox.apps, 0o755)
        chmod(rig.appPath, 0o555)
        try await expectSelfRefusal("needs_admin", "read-only bundle") { _ = try await rig.updater().install(r) }
        chmod(rig.appPath, 0o755)
        try rig.expectUntouched(before, "admin")
        try expectEqual(rig.downloader.calls, 0, "downloaded although it could not be installed")
        // Not a Patched.app at all.
        let other = rig.sandbox.apps + "/Other.app"
        try makeApp(at: other, id: "com.example.other", short: "0.1.0", build: "1", team: nil)
        let wrong = SelfUpdater(appPath: other, runningVersion: "0.1.0", backupsRoot: rig.backups, downloader: rig.downloader,
                                codeCheck: rig.code.check, publicKey: rig.publicKey)
        try await expectSelfRefusal("unsafe_path", "another app") { _ = try await wrong.install(r) }
        for path in ["/tmp/patched-build/debug", "relative/Patched.app"] {
            let odd = SelfUpdater(appPath: path, runningVersion: "0.1.0", backupsRoot: rig.backups, downloader: rig.downloader,
                                  codeCheck: rig.code.check, publicKey: rig.publicKey)
            try await expectSelfRefusal("unsafe_path", path) { _ = try await odd.install(r) }
        }
        let translocated = SelfUpdater(appPath: "/private/var/folders/x/AppTranslocation/ABC/d/Patched.app", runningVersion: "0.1.0",
                                       backupsRoot: rig.backups, downloader: rig.downloader, codeCheck: rig.code.check, publicKey: rig.publicKey)
        try await expectSelfRefusal("needs_admin", "translocated") { _ = try await translocated.install(r) }
        try expectEqual(rig.downloader.calls, 0, "downloaded for an unusable app path")
    }

    check("self update: a release without assets, or with asset URLs off GitHub, is never downloaded") {
        let rig = try SelfRig()
        let before = rig.snapshot()
        try await expectSelfRefusal("not_installable", "no assets") { _ = try await rig.updater().install(release("0.2.0", assets: false)) }
        let page = URL(string: "https://github.com/birdseeed/patched/releases/tag/v0.2.0")!
        let good = release("0.2.0").assets!
        for (zip, sig) in [(URL(string: "https://evil.example/Patched-0.2.0.zip")!, good.signatureURL),
                           (good.zipURL, URL(string: "http://github.com/birdseeed/patched/releases/download/v0.2.0/Patched-0.2.0.zip.sig")!),
                           (URL(string: downloadBase + "v0.2.0/Patched-0.3.0.zip")!, good.signatureURL),
                           (URL(string: downloadBase + "v0.2.0/Patched-0.2.0.zip?x=1")!, good.signatureURL)] {
            let r = PatchedRelease(version: "0.2.0", pageURL: page, assets: PatchedReleaseAssets(zipURL: zip, signatureURL: sig))
            try await expectSelfRefusal("insecure_download", zip.absoluteString + " " + sig.absoluteString) { _ = try await rig.updater().install(r) }
        }
        try rig.expectUntouched(before, "assets")
        try expectEqual(rig.downloader.calls, 0, "downloaded")
    }

    check("self update: the signature download is capped, and the zip cap is a Patched-sized one") {
        let rig = try SelfRig()
        let r = try rig.publish("0.2.0", signature: String(repeating: "A", count: Int(SelfUpdateLimits.signatureBytes) + 1))
        let before = rig.snapshot()
        try await expectSelfRefusal("too_large", "huge signature") { _ = try await rig.updater().install(r) }
        try rig.expectUntouched(before, "huge signature")
        try expect(SelfUpdateLimits.zipBytes == 64 * 1024 * 1024 && SelfUpdateLimits.signatureBytes == 1024, "limits")
    }

    check("self update: downloads stay on GitHub's release hosts, https only") {
        try expectEqual(SelfUpdateLimits.downloadHosts, ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"])
        func redirect(_ url: String) -> Bool {
            HTTPSRedirectPolicy.decide(URLRequest(url: URL(string: url)!), allowedHosts: SelfUpdateLimits.downloadHosts) != nil
        }
        try expect(redirect("https://release-assets.githubusercontent.com/github-production-release-asset/1/x?sp=r"), "current asset host refused")
        try expect(redirect("https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/x"), "older asset host refused")
        for bad in ["http://release-assets.githubusercontent.com/x", "https://evil.example/x", "https://githubusercontent.com/x",
                    "https://release-assets.githubusercontent.com.evil.example/x", "https://raw.githubusercontent.com/x"] {
            try expect(!redirect(bad), "redirect to \(bad) allowed")
        }
        // The real downloader refuses a first URL off the list without making a request.
        let sandbox = try Sandbox()
        let sink = try ArtifactSink(path: sandbox.fixtures + "/blocked", maxBytes: 1024)
        let downloader = URLSessionArtifactDownloader(allowedHosts: SelfUpdateLimits.downloadHosts)
        try await expectRefusal("insecure_download") { try await downloader.download(URL(string: "https://evil.example/Patched.zip")!, into: sink, expectedLength: nil) }
    }

    check("self update: the new app is not left quarantined") {
        let rig = try SelfRig()
        let r = try rig.publish("0.2.0", extra: { app in
            for path in [app, app + "/Contents/MacOS/Example"] {
                let value = "0081;00000000;Safari;"
                guard setxattr(path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0 else {
                    throw CheckFailure(description: "could not set quarantine on \(path)")
                }
            }
        })
        // The fixture really carries the flag through the zip, so its absence afterwards means something.
        let probe = rig.sandbox.fixtures + "/quarantine-probe"
        try FileManager.default.createDirectory(atPath: probe, withIntermediateDirectories: true)
        let served = try FileManager.default.contentsOfDirectory(atPath: rig.sandbox.fixtures).filter { $0.hasPrefix("Patched-0.2.0-") && $0.hasSuffix(".zip") }
        try expectEqual(served.count, 1, "fixture zips")
        try tool("/usr/bin/ditto", ["-x", "-k", rig.sandbox.fixtures + "/" + served[0], probe])
        try expect(getxattr(probe + "/Patched.app/Contents/MacOS/Example", "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0,
                   "the fixture lost its quarantine flag before the update")
        _ = try await rig.updater().install(r)
        for path in [rig.appPath, rig.appPath + "/Contents/MacOS/Example"] {
            try expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0, "\(path) is still quarantined")
        }
    }

    check("self update: the real codesign check needs a strict, valid signature with Patched's identifier") {
        let sandbox = try Sandbox()
        func bundle(_ name: String, identifier: String?) throws -> String {
            let app = sandbox.fixtures + "/" + name + ".app"
            try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": patchedID, "CFBundleExecutable": "Patched", "CFBundlePackageType": "APPL",
                                        "CFBundleShortVersionString": "0.2.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app + "/Contents/MacOS/Patched")
            if let identifier { try tool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app]) }
            return app
        }
        try SelfUpdater.verifyCodeSignature(try bundle("Good", identifier: patchedID))
        try await expectRefusal("signature_invalid") { try SelfUpdater.verifyCodeSignature(try bundle("Unsigned", identifier: nil)) }
        try await expectRefusal("signature_invalid") { try SelfUpdater.verifyCodeSignature(try bundle("Other", identifier: "com.example.other")) }
        let tampered = try bundle("Tampered", identifier: patchedID)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: tampered + "/Contents/Info.plist"), options: .atomic)
        try await expectRefusal("signature_invalid") { try SelfUpdater.verifyCodeSignature(tampered) }
    }

    check("self update: end to end with real ad-hoc signed bundles, real ditto and the real codesign check") {
        let sandbox = try Sandbox()
        func signedPatched(at app: String, version: String) throws {
            try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": patchedID, "CFBundleExecutable": "Patched", "CFBundlePackageType": "APPL",
                                        "CFBundleShortVersionString": version, "CFBundleVersion": version]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app + "/Contents/MacOS/Patched")
            try tool("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", "--identifier", patchedID, app])
        }
        let installed = sandbox.apps + "/Patched.app"
        try signedPatched(at: installed, version: "0.1.0")
        let folder = sandbox.fixtures + "/new"
        try signedPatched(at: folder + "/Patched.app", version: "0.2.0")
        let zipPath = sandbox.fixtures + "/Patched-0.2.0.zip"
        try zip(folder + "/Patched.app", to: zipPath)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: try Data(contentsOf: URL(fileURLWithPath: zipPath))).base64EncodedString() + "\n"
        try Data(signature.utf8).write(to: URL(fileURLWithPath: zipPath + ".sig"))
        let r = release("0.2.0")
        let downloader = FakeDownloader()
        downloader.serve(r.assets!.zipURL.absoluteString, from: zipPath)
        downloader.serve(r.assets!.signatureURL.absoluteString, from: zipPath + ".sig")
        let updater = SelfUpdater(appPath: installed, runningVersion: "0.1.0", backupsRoot: sandbox.state + "/backups", downloader: downloader,
                                  codeCheck: SelfUpdater.verifyCodeSignature, publicKey: key.publicKey.rawRepresentation.base64EncodedString())
        let report = try await updater.install(r)
        try expectEqual(try version(installed), "0.2.0")
        try SelfUpdater.verifyCodeSignature(installed)
        try SelfUpdater.verifyCodeSignature(try report.backupPath.unwrapChecked())
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.apps), ["Patched.app"])
    }

    check("self update: leftover staging folders beside the app are removed at launch, and nothing else is") {
        let rig = try SelfRig()
        let apps = rig.sandbox.apps
        let fm = FileManager.default
        // Crashed before the swap: only a zip and an unpacked folder, no app at the top. Removed.
        let stale = apps + "/" + SelfUpdater.workFolderPrefix + "crashed"
        try fm.createDirectory(atPath: stale + "/unpacked/Patched.app/Contents", withIntermediateDirectories: true)
        try "zip".write(toFile: stale + "/Patched-0.2.0.zip", atomically: true, encoding: .utf8)
        // After the swap (or a failed backup move) the previous Patched is at the top: it may be the only copy. Kept.
        let holding = apps + "/" + SelfUpdater.workFolderPrefix + "holds-previous"
        try makeApp(at: holding + "/Patched.app", id: patchedID, short: "0.0.9", build: "9", team: nil, payload: "old")
        try fm.createDirectory(atPath: apps + "/.patched-other", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: apps + "/Keep.app", withIntermediateDirectories: true)
        // A symlink with the prefix is never followed or removed.
        let outside = rig.sandbox.root + "/outside"
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "x".write(toFile: outside + "/precious", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: apps + "/" + SelfUpdater.workFolderPrefix + "link", withDestinationPath: outside)
        // A plain file with the prefix is left alone too.
        try "x".write(toFile: apps + "/" + SelfUpdater.workFolderPrefix + "file", atomically: true, encoding: .utf8)
        let later = Date().addingTimeInterval(SelfUpdater.staleWorkFolderAge + 60)
        // A fresh folder may belong to an update running in another Patched: nothing goes.
        try expect(SelfUpdater.removeStaleWorkFolders(besideApp: rig.appPath).isEmpty && fm.fileExists(atPath: stale), "removed a fresh folder")
        let removed = SelfUpdater.removeStaleWorkFolders(besideApp: rig.appPath, now: later)
        try expect(removed == [stale], "removed: \(removed)")
        try expect(fm.fileExists(atPath: holding + "/Patched.app"), "deleted the previous Patched")
        try expect(!fm.fileExists(atPath: stale), "stale staging folder kept")
        for kept in [rig.appPath, apps + "/.patched-other", apps + "/Keep.app", apps + "/" + SelfUpdater.workFolderPrefix + "file", outside + "/precious"] {
            try expect(fm.fileExists(atPath: kept), "removed \(kept)")
        }
        try expect((try? fm.destinationOfSymbolicLink(atPath: apps + "/" + SelfUpdater.workFolderPrefix + "link")) == outside, "symlink touched")
        try expect(SelfUpdater.removeStaleWorkFolders(besideApp: rig.sandbox.root + "/not-an-app").isEmpty, "ran for a non-app path")
        let other = apps + "/" + SelfUpdater.workFolderPrefix + "someone-else"
        try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        try expect(SelfUpdater.removeStaleWorkFolders(besideApp: rig.appPath, uid: geteuid() &+ 1, now: later).isEmpty && fm.fileExists(atPath: other),
                   "removed a folder owned by someone else")
    }

    check("self update: a reopened Patched waits only for a plain process number given after its own flag") {
        let flag = SelfRelaunch.argument
        try expectEqual(SelfRelaunch.pidToAwait(in: ["/x/Patched", flag, "4242"], ownPID: 7), 4242)
        for args in [["/x/Patched"], ["/x/Patched", flag], ["/x/Patched", flag, "-1"], ["/x/Patched", flag, "1"], ["/x/Patched", flag, "0"],
                     ["/x/Patched", flag, "12a"], ["/x/Patched", flag, " 12"], ["/x/Patched", flag, "7"], ["/x/Patched", flag, "+12"],
                     ["/x/Patched", "--other", "12"], ["/x/Patched", flag, "99999999999999"]] {
            try expect(SelfRelaunch.pidToAwait(in: args, ownPID: 7) == nil, "accepted \(args)")
        }
        let started = Date()
        try expect(SelfRelaunch.waitForExit(of: 99_999_999, timeout: 2), "a process that does not exist was waited for")
        try expect(Date().timeIntervalSince(started) < 1, "waited for a missing process")
        try expect(!SelfRelaunch.waitForExit(of: getpid(), timeout: 0.3), "own (running) process reported as exited")
    }
}
