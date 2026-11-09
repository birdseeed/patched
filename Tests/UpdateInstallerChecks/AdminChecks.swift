import Foundation
import Darwin
import UpdateSources
import UpdateInstaller

// Experimental admin path (Phase 2b), off by default. Everything here uses fakes for macOS's prompt and
// Apple's Installer, and temporary folders; a "root-owned" app is simulated by giving the installer a
// different uid, exactly as the needs_admin precondition checks do.

// MARK: Fakes

/// Stands in for NSWorkspace authorization + FileManager(authorization:).replaceItemAt. The replacement
/// itself is done as the current user, which works because the sandbox really belongs to us.
final class FakeReplacer: PrivilegedReplacing, @unchecked Sendable {
    enum Grant { case grant, deny, fail }
    /// `breakTarget` leaves a damaged app behind and throws; `removeTarget` leaves nothing there and throws.
    enum Act { case replace, failUntouched, denyUntouched, breakTarget, removeTarget, replaceThenTamper, unavailable }
    let lock = NSLock()
    var grant: Grant = .grant
    /// What each replacement call does, in order; calls beyond the list replace normally.
    var acts: [Act] = []
    private(set) var authorizations = 0
    private(set) var calls: [(target: String, replacement: String)] = []
    /// Runs inside every replacement before it acts, to look at the disk at that moment.
    var beforeReplace: (@Sendable (Int, String, String) throws -> Void)?

    func authorize() async throws -> any PrivilegedReplacementSession {
        let grant = lock.withLock { authorizations += 1; return self.grant }
        switch grant {
        case .grant: return Session(owner: self)
        case .deny: throw InstallRefusal.adminDenied("fake: the user cancelled")
        case .fail: throw InstallRefusal.privilegedReplaceFailed("fake: authorization failed")
        }
    }

    struct Session: PrivilegedReplacementSession, @unchecked Sendable {
        let owner: FakeReplacer
        func replaceItem(at target: String, withItemAt replacement: String) async throws {
            let (n, act, hook) = owner.lock.withLock { () -> (Int, Act, (@Sendable (Int, String, String) throws -> Void)?) in
                owner.calls.append((target, replacement))
                let n = owner.calls.count
                return (n, n <= owner.acts.count ? owner.acts[n - 1] : .replace, owner.beforeReplace)
            }
            try hook?(n, target, replacement)
            let fm = FileManager.default
            // Like FileManager.replaceItemAt, there must be something to replace.
            guard FileSafety.exists(target) else { throw InstallRefusal.privilegedReplaceFailed("fake: nothing at \(target)") }
            switch act {
            case .failUntouched: throw InstallRefusal.privilegedReplaceFailed("fake: helper failed")
            case .denyUntouched: throw InstallRefusal.adminDenied("fake: declined at replace")
            case .unavailable:
                // What the real session maps macOS 27's EIO (seen for ad-hoc builds) to.
                throw WorkspacePrivilegedReplacer.refusal(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))]), stage: "replace")
            case .breakTarget:
                try tamper(target)
                throw InstallRefusal.privilegedReplaceFailed("fake: failed half way")
            case .removeTarget:
                try fm.removeItem(atPath: target)
                throw InstallRefusal.privilegedReplaceFailed("fake: failed and left nothing")
            case .replace, .replaceThenTamper:
                try fm.removeItem(atPath: target)
                try fm.moveItem(atPath: replacement, toPath: target)
                if act == .replaceThenTamper { try tamper(target) }
            }
        }
    }
}

struct FakeSession: InteractiveSessionChecking {
    var problem: String? = nil
    func interactiveProblem() -> String? { problem }
}

/// Simulates Apple's Installer: records the call and, if told, changes the installed app.
final class FakeOpener: PackageInstallerOpening, @unchecked Sendable {
    let lock = NSLock()
    private(set) var opened: [String] = []
    var fail = false
    var onOpen: (@Sendable (String) throws -> Void)?
    func openInstaller(forPackageAt path: String) throws {
        let (hook, fail) = lock.withLock { opened.append(path); return (onOpen, self.fail) }
        if fail { throw InstallRefusal.installerFailed("fake: open failed") }
        try hook?(path)
    }
}

/// The real package parsers, fed fixture output instead of running pkgutil and spctl.
func fixturePackageVerifier(pkgutil: String = "pkgutil-developer-id.txt", pkgutilStatus: Int32 = 0,
                            spctl: String = "spctl-accepted.txt", spctlStatus: Int32 = 0,
                            calls: CallLog? = nil) -> SystemPackageVerifier {
    SystemPackageVerifier(run: { tool, arguments, _ in
        calls?.add(tool)
        let path = arguments.last ?? ""
        let text = (try? packageFixture(tool.hasSuffix("pkgutil") ? pkgutil : spctl)) ?? ""
        return ProcessRunner.Output(status: tool.hasSuffix("pkgutil") ? pkgutilStatus : spctlStatus, timedOut: false,
                                    stdout: text.replacingOccurrences(of: "{PATH}", with: path), stderr: "")
    })
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

func packageFixture(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Fixtures/PackageSignature/" + name), encoding: .utf8)
}

/// A minimal flat package: a version 1 xar header and some bytes.
func makeFlatPackage(at path: String, magic: [UInt8] = Array("xar!".utf8), version: UInt8 = 1) throws {
    var bytes = magic + [0x00, 0x1c, 0x00, version]
    bytes += [UInt8](repeating: 0x42, count: 120)
    try Data(bytes).write(to: URL(fileURLWithPath: path))
}

func adminPath(replacer: FakeReplacer = FakeReplacer(), packages: any PackageVerifying = fixturePackageVerifier(),
               opener: FakeOpener = FakeOpener(),
               waiter: any InstallerCompletionWaiting = VersionPollingWaiter(timeout: 1.5, interval: 0.02, stableReads: 2,
                                                                             settleInterval: 0.05, settleTimeout: 1.5),
               session: FakeSession = FakeSession(), replacement: Bool = true, pkg: Bool = true) -> AdminUpdatePath {
    AdminUpdatePath(replacer: replacer, packages: packages, opener: opener, waiter: waiter, session: session,
                    allowsReplacement: replacement, allowsPackages: pkg)
}

/// An installer whose uid differs from the sandbox owner, so every app in it "needs admin".
func adminInstaller(_ box: Sandbox, admin: AdminUpdatePath?, downloader: FakeDownloader = FakeDownloader(),
                    verifier: FakeVerifier = FakeVerifier(), running: FakeRunningApps = FakeRunningApps(),
                    uid: uid_t = 4242, crashAt: TransactionJournal.Phase? = nil,
                    installerRunning: @escaping @Sendable () -> Bool = { false }) -> UpdateInstaller {
    UpdateInstaller(locations: box.locations, downloader: downloader, verifier: verifier, runningApps: running, uid: uid,
                    teamIDReader: fakeTeamReader,
                    hooks: TransactionHooks(afterJournalWrite: { phase in
                        if phase == crashAt { throw SimulatedCrash(phase: phase.rawValue) }
                    }),
                    quitTimeout: 1, adminPath: admin, installerRunning: installerRunning)
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

func installableOutcome(_ target: String, _ offer: UpdateOffer) -> AppCheckOutcome {
    AppCheckOutcome(app: InstalledApp(name: "Example", path: target, bundleID: bundleID, shortVersion: "1.0", build: "100"),
                    teamID: teamA, source: offer.source, lowConfidence: false, installable: true, result: .updateAvailable(offer))
}

let backupBundle = "/" + bundleID + "/1.0-100/Example.app"

let v2zip = "https://example.test/v2.zip"
let v2pkg = "https://example.test/v2.pkg"

/// Installed v1 and a v2 flat package served at v2pkg.
func packageWorld() throws -> World {
    let box = try Sandbox()
    let target = try makeApp(at: box.apps + "/Example.app", short: "1.0", build: "100")
    let pkg = box.fixtures + "/v2.pkg"
    try makeFlatPackage(at: pkg)
    let downloader = FakeDownloader()
    downloader.serve(v2pkg, from: pkg)
    return World(box: box, target: target, downloader: downloader, archive: pkg)
}

/// What Apple's Installer would leave behind: version `short` of the app at `target`.
func installByInstaller(_ target: String, short: String = "2.0", build: String = "200", team: String = teamA) throws {
    try FileManager.default.removeItem(atPath: target)
    try makeApp(at: target, short: short, build: build, team: team)
}

func backupsFolder(_ box: Sandbox) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: box.locations.backups + "/" + bundleID)) ?? []).sorted()
}

func registerAdminChecks() {
    // MARK: Flag

    check("admin flag: only PATCHED_ENABLE_ADMIN_UPDATES=1 turns it on") {
        try expect(!AdminUpdateFlag.isEnabled(environment: [:]), "unset")
        for value in ["0", "true", "yes", "", " 1", "1 "] {
            try expect(!AdminUpdateFlag.isEnabled(environment: ["PATCHED_ENABLE_ADMIN_UPDATES": value]), "\"\(value)\" turned it on")
        }
        try expect(AdminUpdateFlag.isEnabled(environment: ["PATCHED_ENABLE_ADMIN_UPDATES": "1"]), "1 did not turn it on")
        let pkgOff = ["PATCHED_ENABLE_PKG_UPDATES": "0"]
        try expect(AdminUpdatePath.ifEnabled(environment: pkgOff) == nil, "path built with both parts off")
        let byDefault = AdminUpdatePath.ifEnabled(environment: [:])
        try expect(byDefault?.allowsPackages == true && byDefault?.allowsReplacement == false,
                   "by default only pkg updates are on, never replacement")
        for value in ["1", "", "true", "yes", "00"] {
            try expect(AdminUpdateFlag.isPackageEnabled(environment: ["PATCHED_ENABLE_PKG_UPDATES": value]), "\"\(value)\" turned pkg off")
        }
        try expect(!AdminUpdateFlag.isPackageEnabled(environment: pkgOff), "0 did not turn pkg off")
        let cli = AdminUpdatePath.ifEnabled(adminFlag: true, environment: pkgOff)
        try expect(cli?.allowsReplacement == true && cli?.allowsPackages == false, "admin CLI flag must not enable pkg")
        let pkgOnly = AdminUpdatePath.ifEnabled(environment: ["PATCHED_ENABLE_PKG_UPDATES": "1"])
        try expect(pkgOnly?.allowsPackages == true && pkgOnly?.allowsReplacement == false, "pkg flag must not enable replacement")
        let adminEnv = AdminUpdatePath.ifEnabled(environment: ["PATCHED_ENABLE_ADMIN_UPDATES": "1", "PATCHED_ENABLE_PKG_UPDATES": "0"])
        try expect(adminEnv?.allowsReplacement == true && adminEnv?.allowsPackages == false, "admin env must not enable pkg")
        try expectEqual(AdminUpdateFlag.commandLineFlag, "--enable-admin-updates")
        try expectEqual(AdminUpdateFlag.packageCommandLineFlag, "--enable-pkg-updates")
    }

    check("admin flag off: root-owned and pkg updates refuse exactly as before, whatever the caller passes") {
        let w = try world()
        let interaction = AdminInteraction()
        // No admin path (flag off), even with a consent token.
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(w.box, admin: nil, downloader: w.downloader).update(appAt: w.target, offer: offer(v2zip), installable: true, admin: interaction)
        }
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(w.box, admin: nil).rollback(appAt: w.target, admin: interaction)
        }
        try await expectRefusal("unsupported_format") {
            _ = try await installer(w.box, downloader: w.downloader).update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: interaction)
        }
        // Admin path present (flag on) but no consent for this call (Update All, scheduled code).
        let replacer = FakeReplacer(), opener = FakeOpener()
        let path = adminPath(replacer: replacer, opener: opener)
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(w.box, admin: path, downloader: w.downloader).update(appAt: w.target, offer: offer(v2zip), installable: true)
        }
        try await expectRefusal("unsupported_format") {
            _ = try await adminInstaller(w.box, admin: path, downloader: w.downloader).update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true)
        }
        // The very same messages as the ordinary preconditions.
        let plain = { () throws -> InstallRefusal in
            do { _ = try adminInstaller(w.box, admin: path).checkPreconditions(appPath: w.target, format: .zip) } catch let r as InstallRefusal { return r }
            throw CheckFailure(description: "no refusal")
        }
        try expectEqual(try plain(), .needsAdmin("\(w.target) is owned by uid \(geteuid())"))
        try expectEqual(replacer.authorizations, 0, "authorized")
        try expectEqual(opener.opened.count, 0, "opened Installer")
        try expectEqual(w.downloader.calls, 0, "downloaded")
        try expectEqual(try version(w.target), "1.0")
        try expectClean(w.box)
    }

    check("admin flags are separate: the pkg flag never replaces a root-owned app, the admin flag never opens Installer") {
        let w = try world()
        let replacer = FakeReplacer(), opener = FakeOpener()
        let pkgOnly = adminPath(replacer: replacer, opener: opener, replacement: false, pkg: true)
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(w.box, admin: pkgOnly, downloader: w.downloader).update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        }
        try await expectRefusal("needs_admin") { _ = try await adminInstaller(w.box, admin: pkgOnly).rollback(appAt: w.target, admin: AdminInteraction()) }
        let p = try packageWorld()
        let adminOnly = adminPath(replacer: replacer, opener: opener, replacement: true, pkg: false)
        try await expectRefusal("unsupported_format") {
            _ = try await adminInstaller(p.box, admin: adminOnly, downloader: p.downloader).update(appAt: p.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
        }
        try expectEqual(replacer.authorizations, 0)
        try expectEqual(opener.opened.count, 0)
        // With only the pkg flag, a pkg still works (it does not depend on Patched's own signing).
        let target = p.target
        opener.onOpen = { _ in try installByInstaller(target) }
        let report = try await adminInstaller(p.box, admin: pkgOnly, downloader: p.downloader, uid: geteuid())
            .update(appAt: p.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
        try expectEqual(report.status, .installed)
        try expectEqual(replacer.authorizations, 0, "pkg update asked for a privileged replacement")
    }

    check("admin: EIO from macOS's privileged helper is admin_replace_unavailable and changes nothing") {
        let eio = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))])
        try expectEqual(WorkspacePrivilegedReplacer.refusal(eio, stage: "replace").code, "admin_replace_unavailable")
        try expectEqual(WorkspacePrivilegedReplacer.refusal(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)), stage: "replace").code,
                        "admin_replace_unavailable")
        // Other failures keep their meaning.
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        try expectEqual(WorkspacePrivilegedReplacer.refusal(other, stage: "replace").code, "privileged_replace_failed")
        try expectEqual(WorkspacePrivilegedReplacer.refusal(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError), stage: "x").code, "admin_denied")
        try expect(InstallRefusal.adminReplaceUnavailable("x").message.contains("update this app manually"), "message")
        let w = try world()
        let replacer = FakeReplacer(); replacer.acts = [.unavailable]
        try await expectRefusal("admin_replace_unavailable") {
            _ = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        }
        try expectEqual(replacer.calls.count, 1, "retried or restored over an untouched app")
        try expectConsistent(w, new: false)
        try expect(backupsFolder(w.box).isEmpty, "backup copy left")
    }

    check("CLI update --all never asks for admin rights or opens Installer, even with both switches on") {
        let replacer = FakeReplacer(), opener = FakeOpener()
        let both = adminPath(replacer: replacer, opener: opener, replacement: true, pkg: true)
        let zipWorld = try world(), pkgWorld = try packageWorld()
        let worlds: [(World, UpdateOffer)] = [(zipWorld, offer(v2zip)), (pkgWorld, offer(v2pkg, format: .pkg))]
        for (w, o) in worlds {
            let cli = adminInstaller(w.box, admin: both, downloader: w.downloader)
            do {
                _ = try await CommandLineUpdates.update(installableOutcome(w.target, o), installer: cli, options: UpdateOptions(),
                                                        scope: .all, notice: { _ in })
                throw CheckFailure(description: "--all installed \(o.format)")
            } catch let refusal as InstallRefusal {
                try expectEqual(refusal.code, "needs_admin_approval", "\(o.format)")
                try expect(refusal.message.contains("run `patched update \(w.target)` to approve"), refusal.message)
            }
            try expect(CommandLineUpdates.consent(.all, installer: cli, notice: { _ in }) == nil, "--all made consent")
            try expectConsistent(w, new: false)
        }
        try expectEqual(replacer.authorizations, 0, "--all asked for admin rights")
        try expectEqual(opener.opened.count, 0, "--all opened Installer")
        // Naming the one app is consent.
        let named = adminInstaller(zipWorld.box, admin: both, downloader: zipWorld.downloader)
        let report = try await CommandLineUpdates.update(installableOutcome(zipWorld.target, offer(v2zip)), installer: named,
                                                         options: UpdateOptions(), scope: .oneApp, notice: { _ in })
        try expect(report.privileged && replacer.authorizations == 1, "single-app update did not use the admin path")
        // Switches off: --all and single-app refuse exactly as before, and no consent exists.
        let off = try world(), offPkg = try packageWorld()
        let plain = adminInstaller(off.box, admin: nil, downloader: off.downloader)
        for scope in [CommandLineUpdates.Scope.all, .oneApp] {
            try await expectRefusal("needs_admin") {
                _ = try await CommandLineUpdates.update(installableOutcome(off.target, offer(v2zip)), installer: plain, options: UpdateOptions(), scope: scope, notice: { _ in })
            }
            try await expectRefusal("unsupported_format") {
                _ = try await CommandLineUpdates.update(installableOutcome(offPkg.target, offer(v2pkg, format: .pkg)),
                    installer: adminInstaller(offPkg.box, admin: nil, downloader: offPkg.downloader), options: UpdateOptions(), scope: scope, notice: { _ in })
            }
            try expect(CommandLineUpdates.consent(scope, installer: plain, notice: { _ in }) == nil, "consent with switches off")
        }
    }

    // MARK: Root-owned apps

    check("admin: backup is copied and verified before the one privileged replacement, then everything is verified") {
        let w = try world()
        let replacer = FakeReplacer()
        let box = (locations: w.box.locations, apps: w.box.apps)
        replacer.beforeReplace = { n, target, replacement in
            // The verified copy of the old app and its journal entry exist before anything privileged.
            let backup = box.locations.backups + "/" + bundleID + "/1.0-100/Example.app"
            guard (try? BundleFacts.read(bundleAt: backup).shortVersion) == "1.0" else { throw CheckFailure(description: "no backup at replace \(n)") }
            guard (try? FakeVerifier().verifySignature(ofBundleAt: backup, teamID: teamA)) != nil else { throw CheckFailure(description: "backup does not verify") }
            let journal = JournalStore(directory: box.locations.transactions).unfinished().first
            guard journal?.phase == .prepared, journal?.backupCopyIdentity != nil, journal?.isPrivileged == true else {
                throw CheckFailure(description: "journal not prepared with a recorded backup: \(String(describing: journal?.phase))")
            }
            guard (try? BundleFacts.read(bundleAt: replacement).shortVersion) == "2.0", target == box.apps + "/Example.app" else {
                throw CheckFailure(description: "wrong replacement")
            }
            guard replacement.hasPrefix(box.locations.downloads + "/.mac-updater-") else { throw CheckFailure(description: "staged outside downloads: \(replacement)") }
        }
        let report = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader)
            .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        try expectEqual(report.status, .installed)
        try expect(report.privileged && report.installedOwner == geteuid(), "ownership not recorded: \(report)")
        try expect(report.note?.contains("admin rights") == true, "note: \(String(describing: report.note))")
        try expectEqual(replacer.authorizations, 1, "asked more than once")
        try expectEqual(replacer.calls.count, 1, "replacements")
        try expectConsistent(w, new: true)
        try expectEqual(journals(w.box).last?.phase, .finished)
    }

    check("admin: denied or failed authorization changes nothing and keeps no backup") {
        for grant in [FakeReplacer.Grant.deny, .fail] {
            let w = try world()
            let replacer = FakeReplacer(); replacer.grant = grant
            try await expectRefusal(grant == .deny ? "admin_denied" : "privileged_replace_failed") {
                _ = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader)
                    .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
            }
            try expectEqual(replacer.calls.count, 0)
            try expectConsistent(w, new: false)
            try expect(backupsFolder(w.box).isEmpty, "backup copy left: \(backupsFolder(w.box))")
        }
    }

    check("admin: a replacement that fails or is declined without touching the target is refused cleanly") {
        for act in [FakeReplacer.Act.failUntouched, .denyUntouched] {
            let w = try world()
            let replacer = FakeReplacer(); replacer.acts = [act]
            try await expectRefusal(act == .failUntouched ? "privileged_replace_failed" : "admin_denied") {
                _ = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader)
                    .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
            }
            try expectEqual(replacer.calls.count, 1, "the old app was put back over itself")
            try expectConsistent(w, new: false)
            try expect(backupsFolder(w.box).isEmpty, "backup copy left")
        }
    }

    check("admin: a backup copy that does not verify stops before macOS is asked") {
        let w = try world()
        let replacer = FakeReplacer()
        try await expectRefusal("signature_invalid") {
            _ = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader,
                                         verifier: FakeVerifier(failPartialCopies: true))
                .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        }
        try expectEqual(replacer.authorizations, 0, "asked for admin rights without a verified backup")
        try expectConsistent(w, new: false)
    }

    check("admin: verification failure after the replacement puts the verified backup back with the same grant") {
        for failure in ["tampered", "gatekeeper"] {
            let w = try world()
            let replacer = FakeReplacer()
            var verifier = FakeVerifier()
            if failure == "tampered" { replacer.acts = [.replaceThenTamper] }
            else { verifier.failGatekeeperAt = [w.target]; verifier.onlyVersion = "2.0" }
            try await expectRefusal("verification_failed_after_swap") {
                _ = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader, verifier: verifier)
                    .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
            }
            try expectEqual(replacer.authorizations, 1, "\(failure): asked twice")
            try expectEqual(replacer.calls.count, 2, "\(failure): no privileged restore")
            try expect(replacer.calls[1].replacement.hasSuffix("/restore/Example.app"), "restored from \(replacer.calls[1].replacement)")
            try expectConsistent(w, new: false)
            try expect(backupsFolder(w.box).isEmpty, "\(failure): copy of the reinstalled version kept as a backup")
            try expectEqual(journals(w.box).last?.phase, .reverted)
        }
    }

    check("admin: when the restore fails too, nothing is deleted and the way back is spelled out") {
        let w = try world()
        let replacer = FakeReplacer(); replacer.acts = [.replaceThenTamper, .failUntouched]
        do {
            _ = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
            throw CheckFailure(description: "accepted")
        } catch let refusal as InstallRefusal {
            try expectEqual(refusal.code, "unresolved")
            let backup = w.box.locations.backups + "/" + bundleID + "/1.0-100/Example.app"
            try expect(refusal.message.contains(backup) && refusal.message.contains("drag it into \(w.box.apps)"), refusal.message)
        }
        try expectEqual(unfinished(w.box).map(\.phase), [.swapBack])
        let backup = w.box.locations.backups + "/" + bundleID + "/1.0-100/Example.app"
        try expectEqual(try version(backup), "1.0")
        // Recovery uses no admin rights: it refuses to guess while the target is the tampered new app...
        let first = await adminInstaller(w.box, admin: nil).recover()
        try expectEqual(first.reports.map { (try? $0.result.get()) == nil }, [true])
        if case .failure(let refusal) = first.reports[0].result { try expectEqual(refusal.code, "recovery_ambiguous") }
        try expectEqual(try version(backup), "1.0", "recovery touched the backup")
        // ...and once the owner has put the backup back by hand, it settles as reverted.
        try FileManager.default.removeItem(atPath: w.target)
        try tool("/usr/bin/ditto", [backup, w.target])
        let second = await adminInstaller(w.box, admin: nil).recover()
        try expectEqual(second.reports.map { try? $0.result.get() }, [.reverted])
        try expectConsistent(w, new: false)
        try expectEqual(replacer.authorizations, 1)
    }

    check("admin: a replacement that fails half way is treated as changed and restored") {
        let w = try world()
        let replacer = FakeReplacer(); replacer.acts = [.breakTarget]
        try await expectRefusal("verification_failed_after_swap") {
            _ = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        }
        try expectEqual(replacer.calls.count, 2)
        try expectConsistent(w, new: false)
        // With nothing left at the target there is nothing to replace: stop, keep the backup, explain.
        let gone = try world()
        let second = FakeReplacer(); second.acts = [.removeTarget]
        try await expectRefusal("unresolved") {
            _ = try await adminInstaller(gone.box, admin: adminPath(replacer: second), downloader: gone.downloader)
                .update(appAt: gone.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        }
        try expectEqual(try version(gone.box.locations.backups + "/" + bundleID + "/1.0-100/Example.app"), "1.0", "backup lost")
        try expectEqual(unfinished(gone.box).map(\.phase), [.swapBack])
    }

    check("admin: nobody at the screen means needs_interactive_admin before anything is downloaded") {
        let w = try world()
        let replacer = FakeReplacer()
        let path = adminPath(replacer: replacer, session: FakeSession(problem: "this session has no screen"))
        try await expectRefusal("needs_interactive_admin") {
            _ = try await adminInstaller(w.box, admin: path, downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        }
        try await expectRefusal("needs_interactive_admin") {
            _ = try await adminInstaller(w.box, admin: path).rollback(appAt: w.target, admin: AdminInteraction())
        }
        try expectEqual(w.downloader.calls, 0)
        try expectEqual(replacer.authorizations, 0)
        // A dry run needs no prompt and verifies everything.
        let dry = try await adminInstaller(w.box, admin: path, downloader: w.downloader)
            .update(appAt: w.target, offer: offer(v2zip), installable: true, options: UpdateOptions(dryRun: true), admin: AdminInteraction())
        try expectEqual(dry.status, .dryRunPassed)
        try expectEqual(replacer.authorizations, 0, "dry run asked for admin rights")
        try expectConsistent(w, new: false)
    }

    check("admin: a user-replaceable app never uses the admin path, even with consent") {
        let w = try world()
        let replacer = FakeReplacer()
        let report = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader, uid: geteuid())
            .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        try expect(!report.privileged, "took the admin path")
        try expectEqual(replacer.authorizations, 0)
        try expectConsistent(w, new: true)
    }

    check("admin: immutable files are refused even with admin rights") {
        let w = try world()
        let file = w.target + "/Contents/Info.plist"
        try expectEqual(chflags(file, UInt32(UF_IMMUTABLE)), 0, "chflags")
        defer { chflags(file, 0) }
        let replacer = FakeReplacer()
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        }
        try expectEqual(replacer.authorizations, 0)
    }

    check("admin: an admin-owned app rolls back through the same privileged path") {
        let w = try world()
        let replacer = FakeReplacer()
        let admin = adminInstaller(w.box, admin: adminPath(replacer: replacer), downloader: w.downloader)
        _ = try await admin.update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
        try await expectRefusal("needs_admin") { _ = try await admin.rollback(appAt: w.target) }
        let report = try await admin.rollback(appAt: w.target, admin: AdminInteraction())
        try expectEqual(report.status, .rolledBack)
        try expect(report.privileged, "not privileged")
        try expectEqual(replacer.authorizations, 2, "one prompt per action")
        try expectEqual(try version(w.target), "1.0")
        try expectEqual(admin.backups().map(\.shortVersion), ["2.0"], "replaced version kept as the backup")
        try expectClean(w.box)
    }

    check("admin: crashes before and after the replacement recover without admin rights") {
        // Before macOS was asked: the copy is discarded and the app is untouched.
        for phase in [TransactionJournal.Phase.backingUp, .prepared] {
            let w = try world()
            do {
                _ = try await adminInstaller(w.box, admin: adminPath(), downloader: w.downloader, crashAt: phase)
                    .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
                throw CheckFailure(description: "no crash")
            } catch is SimulatedCrash {}
            let result = await adminInstaller(w.box, admin: nil).recover()
            try expectEqual(result.reports.map { try? $0.result.get() }, [phase == .backingUp ? .discarded : .reverted], "\(phase)")
            try expectConsistent(w, new: false)
            try expect(backupsFolder(w.box).isEmpty, "\(phase): copy left")
        }
        // After the replacement: the verified new app completes, with its backup recorded.
        let w = try world()
        do {
            _ = try await adminInstaller(w.box, admin: adminPath(), downloader: w.downloader, crashAt: .swapped)
                .update(appAt: w.target, offer: offer(v2zip), installable: true, admin: AdminInteraction())
            throw CheckFailure(description: "no crash")
        } catch is SimulatedCrash {}
        let result = await adminInstaller(w.box, admin: nil).recover()
        try expectEqual(result.reports.map { try? $0.result.get() }, [.completed])
        try expectConsistent(w, new: true)
    }

    // MARK: Package signature parsing

    check("pkgutil: only a Developer ID Installer chain from the installed app's team is accepted") {
        let path = "/private/tmp/somewhere/artifact.pkg"
        func verdict(_ fixture: String, status: Int32 = 0, team: String = teamA) throws -> String {
            do {
                try PackageSignature.interpretCheckSignature(status: status, output: try packageFixture(fixture), path: path, teamID: team)
                return "ok"
            } catch let refusal as InstallRefusal { return refusal.code + ": " + refusal.message }
        }
        try expectEqual(try verdict("pkgutil-developer-id.txt"), "ok")
        try expect(try verdict("pkgutil-developer-id.txt", team: teamB).contains("signed by Team ID AAAAAAAAAA"), "wrong team accepted")
        try expect(try verdict("pkgutil-other-team.txt").contains("Team ID BBBBBBBBBB"), "other team accepted")
        try expect(try verdict("pkgutil-team-in-name.txt").contains("BBBBBBBBBB"), "team hidden in the name accepted")
        try expect(try verdict("pkgutil-unsigned.txt", status: 1).hasPrefix("package_signature_invalid"), "unsigned accepted")
        try expect(try verdict("pkgutil-unsigned.txt", status: 0).contains("no signature"), "unsigned with exit 0 accepted")
        try expect(try verdict("pkgutil-apple-signed.txt").contains("signed by Apple, not with a Developer ID Installer"), "Apple-signed accepted")
        try expect(try verdict("pkgutil-application-certificate.txt").contains("not a Developer ID Installer"), "application certificate accepted")
        try expect(try verdict("pkgutil-untrusted.txt").contains("untrusted"), "untrusted accepted")
        for malformed in ["pkgutil-malformed-short-chain.txt", "pkgutil-malformed-order.txt", "pkgutil-malformed-extra-line.txt",
                          "pkgutil-malformed-two-status.txt", "pkgutil-malformed-no-chain.txt"] {
            try expect(try verdict(malformed).hasPrefix("package_signature_invalid"), "\(malformed) accepted")
        }
        // A listing for a different file, empty output and a bad Team ID argument.
        try expect(try PackageSignatureProbe.refuses(output: try packageFixture("pkgutil-developer-id.txt"), path: "/x/other.pkg"), "other file's listing accepted")
        try expect(try PackageSignatureProbe.refuses(output: "", path: path), "empty output accepted")
        try expect(try verdict("pkgutil-developer-id.txt", team: "AAAA\") or (1").hasPrefix("package_signature_invalid"), "malformed team accepted")
    }

    check("spctl install: accepted, notarised Developer ID, same team, not overridden") {
        let path = "/private/tmp/somewhere/artifact.pkg"
        func verdict(_ fixture: String, status: Int32 = 0) throws -> String {
            let text = try packageFixture(fixture).replacingOccurrences(of: "{PATH}", with: path)
            do { try PackageSignature.interpretInstallAssessment(status: status, output: text, path: path, teamID: teamA); return "ok" }
            catch let refusal as InstallRefusal { return refusal.code }
        }
        try expectEqual(try verdict("spctl-accepted.txt"), "ok")
        try expectEqual(try verdict("spctl-accepted.txt", status: 3), "notarisation_rejected")
        for fixture in ["spctl-rejected.txt", "spctl-not-notarised.txt", "spctl-no-origin.txt", "spctl-other-team.txt",
                        "spctl-override.txt", "spctl-apple-installer.txt"] {
            try expectEqual(try verdict(fixture), "notarisation_rejected", fixture)
        }
    }

    check("flat package: bundle-style folders, symlinks and non-xar files are refused") {
        let box = try Sandbox()
        let good = box.fixtures + "/good.pkg"
        try makeFlatPackage(at: good)
        try PackageFile.requireFlat(good)
        try makeFlatPackage(at: box.fixtures + "/zip.pkg", magic: [0x50, 0x4b, 0x03, 0x04])
        try makeFlatPackage(at: box.fixtures + "/v2.pkg", version: 2)
        try FileManager.default.createDirectory(atPath: box.fixtures + "/Bundle.pkg/Contents", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: box.fixtures + "/link.pkg", withDestinationPath: good)
        try Data("xar!".utf8).write(to: URL(fileURLWithPath: box.fixtures + "/short.pkg"))
        for name in ["zip.pkg", "v2.pkg", "Bundle.pkg", "link.pkg", "short.pkg"] {
            try await expectRefusal("package_malformed") { try PackageFile.requireFlat(box.fixtures + "/" + name) }
        }
        // The real verifier checks the format before running anything.
        let calls = CallLog()
        try await expectRefusal("package_malformed") {
            try fixturePackageVerifier(calls: calls).verifyPackage(at: box.fixtures + "/zip.pkg", teamID: teamA)
        }
        try expect(calls.all.isEmpty, "ran \(calls.all) on a malformed package")
    }

    // MARK: Installer packages

    check("pkg: verified package opens Apple's Installer after a verified backup, then the result is verified") {
        let w = try packageWorld()
        let opener = FakeOpener()
        let box = (locations: w.box.locations, apps: w.box.apps), target = w.target
        opener.onOpen = { pkg in
            guard (try? BundleFacts.read(bundleAt: box.locations.backups + "/" + bundleID + "/1.0-100/Example.app").shortVersion) == "1.0" else {
                throw CheckFailure(description: "Installer opened before the backup was taken")
            }
            guard FileSafety.mode(pkg) == 0o400, pkg.hasPrefix(box.locations.downloads + "/") else { throw CheckFailure(description: "package not locked: \(pkg)") }
            try installByInstaller(target)
        }
        let messages = CallLog()
        let interaction = AdminInteraction(onInstallerOpened: { messages.add($0) })
        let report = try await adminInstaller(w.box, admin: adminPath(opener: opener), downloader: w.downloader, uid: geteuid())
            .update(appAt: w.target, offer: offer(v2pkg, format: .pkg, sha256: try sha256Hex(w.archive)), installable: true, admin: interaction)
        try expectEqual(report.status, .installed)
        try expectEqual(report.toVersion, "2.0 (200)")
        try expect(report.privileged && report.note?.contains("Apple's Installer") == true, "\(report)")
        try expectEqual(opener.opened.count, 1)
        try expect(messages.all.first?.contains("Apple's Installer has opened") == true, "no notice: \(messages.all)")
        try expectConsistent(w, new: true)
        // The kept copy of 1.0 is marked as replaced by a package and is never rolled back.
        let kept = try installer(w.box).backups()
        try expect(kept.map(\.shortVersion) == ["1.0"] && kept.allSatisfy { $0.installedByPackage == true }, "\(kept)")
        try await expectRefusal("rollback_unsupported") {
            _ = try await adminInstaller(w.box, admin: adminPath(opener: FakeOpener()), uid: geteuid()).rollback(appAt: w.target, admin: AdminInteraction())
        }
        try expectEqual(try BundleFacts.read(bundleAt: w.target).shortVersion, "2.0", "rollback changed the app")
    }

    check("pkg: a package that fails any check never reaches Apple's Installer") {
        let cases: [(String, any PackageVerifying, String)] = [
            ("wrong team", fixturePackageVerifier(pkgutil: "pkgutil-other-team.txt"), "package_signature_invalid"),
            ("unsigned", fixturePackageVerifier(pkgutil: "pkgutil-unsigned.txt", pkgutilStatus: 1), "package_signature_invalid"),
            ("Apple-signed", fixturePackageVerifier(pkgutil: "pkgutil-apple-signed.txt"), "package_signature_invalid"),
            ("not notarised", fixturePackageVerifier(spctl: "spctl-rejected.txt", spctlStatus: 3), "notarisation_rejected"),
        ]
        for (name, packages, code) in cases {
            let w = try packageWorld()
            let opener = FakeOpener()
            try await expectRefusal(code) {
                _ = try await adminInstaller(w.box, admin: adminPath(packages: packages, opener: opener), downloader: w.downloader)
                    .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
            }
            try expectEqual(opener.opened.count, 0, "\(name): Installer opened")
            try expectConsistent(w, new: false)
        }
        // Hash mismatch and a malformed (non-xar) download are refused before the signature is even read.
        let w = try packageWorld()
        let calls = CallLog(), opener = FakeOpener()
        try await expectRefusal("hash_mismatch") {
            _ = try await adminInstaller(w.box, admin: adminPath(packages: fixturePackageVerifier(calls: calls), opener: opener), downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2pkg, format: .pkg, sha256: String(repeating: "0", count: 64)), installable: true, admin: AdminInteraction())
        }
        try makeFlatPackage(at: w.archive, magic: [0x50, 0x4b, 0x03, 0x04])
        try await expectRefusal("package_malformed") {
            _ = try await adminInstaller(w.box, admin: adminPath(packages: fixturePackageVerifier(calls: calls), opener: opener), downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
        }
        try expect(calls.all.isEmpty && opener.opened.isEmpty, "went on: \(calls.all) \(opener.opened)")
        try expectConsistent(w, new: false)
    }

    check("pkg: a package changed after it was verified never reaches Apple's Installer") {
        let w = try packageWorld()
        let opener = FakeOpener()
        let swapped = AfterVerify(inner: fixturePackageVerifier()) { path in
            chmod(path, 0o600)
            let handle = FileHandle(forWritingAtPath: path)!
            handle.seekToEndOfFile(); handle.write(Data("x".utf8)); try handle.close()
        }
        try await expectRefusal("hash_mismatch") {
            _ = try await adminInstaller(w.box, admin: adminPath(packages: swapped, opener: opener), downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
        }
        try expectEqual(opener.opened.count, 0, "Installer opened with changed bytes")
        try expectConsistent(w, new: false)
        try expect(backupsFolder(w.box).isEmpty, "copy kept")
    }

    check("pkg: Installer left unfinished (timeout or Done with no change) verifies nothing and keeps no copy") {
        for pressDone in [false, true] {
            let w = try packageWorld()
            let interaction = AdminInteraction(onInstallerOpened: { _ in })
            let opener = FakeOpener()
            if pressDone { opener.onOpen = { _ in interaction.userFinishedInstaller() } }
            let waiter = VersionPollingWaiter(timeout: pressDone ? 30 : 0.3, interval: 0.02, stableReads: 2)
            try await expectRefusal("installer_not_finished") {
                _ = try await adminInstaller(w.box, admin: adminPath(opener: opener, waiter: waiter), downloader: w.downloader)
                    .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: interaction)
            }
            try expectEqual(opener.opened.count, 1)
            try expectConsistent(w, new: false)
            try expect(backupsFolder(w.box).isEmpty, "copy kept: \(backupsFolder(w.box))")
        }
    }

    check("pkg: Installer installing the wrong version, or a different team, is installed_unverified with a rollback copy") {
        for (short, team) in [("3.0", teamA), ("2.0", teamB)] {
            let w = try packageWorld()
            let opener = FakeOpener()
            let target = w.target
            opener.onOpen = { _ in try installByInstaller(target, short: short, build: short == "3.0" ? "300" : "200", team: team) }
            do {
                _ = try await adminInstaller(w.box, admin: adminPath(opener: opener), downloader: w.downloader)
                    .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
                throw CheckFailure(description: "accepted \(short) \(team)")
            } catch let refusal as InstallRefusal {
                try expectEqual(refusal.code, "installed_unverified")
                try expect(refusal.message.contains("Roll back isn't supported for installer packages"), refusal.message)
            }
            try expectEqual(installer(w.box).backups().map(\.shortVersion), ["1.0"], "no copy kept")
            try expect(installer(w.box).backups().allSatisfy { $0.installedByPackage == true }, "copy not marked as replaced by a package")
            try expectClean(w.box)
        }
    }

    check("pkg: an interrupted install recovers only to the offered, strictly newer, same-team version") {
        let cases: [(String, String, String, String)] = [("0.9", "90", teamA, "installed_unverified"), ("3.0", "300", teamA, "installed_unverified"),
                                                         ("2.0", "200", teamB, "installed_unverified"), ("2.0", "200", teamA, "completed")]
        for (short, build, team, expected) in cases {
            let w = try packageWorld()
            let opener = FakeOpener()
            let target = w.target
            opener.onOpen = { _ in
                try installByInstaller(target, short: short, build: build, team: team)
                throw SimulatedCrash(phase: "installer open")
            }
            do {
                _ = try await adminInstaller(w.box, admin: adminPath(opener: opener), downloader: w.downloader)
                    .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
                throw CheckFailure(description: "no crash")
            } catch is SimulatedCrash {}
            try expectEqual(unfinished(w.box).first?.offer?.displayVersion, "2.0", "offer not recorded before Installer opened")
            let result = await adminInstaller(w.box, admin: nil).recover()
            try expectEqual(result.reports.count, 1)
            switch result.reports[0].result {
            case .success(let outcome): try expectEqual(expected, "completed", "\(short) \(team) recovered as \(outcome)")
            case .failure(let refusal): try expectEqual(refusal.code, expected, "\(short) \(team): \(refusal)")
            }
            if expected == "completed" { try expectConsistent(w, new: true) }
            else {
                try expectEqual(installer(w.box).backups().map(\.shortVersion), ["1.0"], "\(short): backup not kept")
                try expectClean(w.box)
            }
        }
    }

    check("pkg: a changed payload behind unchanged Info.plist keeps the backup and an unresolved journal") {
        let w = try packageWorld()
        let opener = FakeOpener()
        let target = w.target
        opener.onOpen = { _ in try tamper(target) }
        let waiter = VersionPollingWaiter(timeout: 0.3, interval: 0.02, stableReads: 2)
        try await expectRefusal("unresolved") {
            _ = try await adminInstaller(w.box, admin: adminPath(opener: opener, waiter: waiter), downloader: w.downloader)
                .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
        }
        try expectEqual(try version(w.box.locations.backups + backupBundle), "1.0", "verified backup deleted")
        try expectEqual(unfinished(w.box).count, 1, "journal not kept")
        let result = await adminInstaller(w.box, admin: nil).recover()
        if case .failure(let refusal) = result.reports.first?.result { try expectEqual(refusal.code, "recovery_ambiguous") }
        else { throw CheckFailure(description: "recovery accepted a corrupted app: \(result.reports)") }
        try expectEqual(try version(w.box.locations.backups + backupBundle), "1.0", "recovery deleted the backup")
    }

    check("pkg: Installer still writing after the version changed is waited out, not reported as a failure") {
        let w = try packageWorld()
        let opener = FakeOpener()
        let running = Flag(true)
        let target = w.target
        let exe = target + "/Contents/MacOS/Example"
        opener.onOpen = { _ in
            // Info.plist lands first; the executable is still half-written (fails its signature check).
            try installByInstaller(target)
            try "TAMPERED half-written".write(toFile: exe, atomically: false, encoding: .utf8)
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                try? "2.0 executable".write(toFile: exe, atomically: false, encoding: .utf8)
            }
        }
        let report = try await adminInstaller(w.box, admin: adminPath(opener: opener), downloader: w.downloader, uid: geteuid(),
                                              installerRunning: { running.value })
            .update(appAt: w.target, offer: offer(v2pkg, format: .pkg, sha256: try sha256Hex(w.archive)), installable: true, admin: AdminInteraction())
        try expectEqual(report.status, .installed)
        try expectEqual(report.toVersion, "2.0 (200)")
        try expect(unfinished(w.box).isEmpty, "journal left behind")
    }

    check("pkg: Installer that quits with the app still half-written is installed_unverified, after waiting") {
        let w = try packageWorld()
        let opener = FakeOpener()
        let running = Flag(true)
        let target = w.target
        opener.onOpen = { _ in
            try installByInstaller(target)
            try "TAMPERED half-written".write(toFile: target + "/Contents/MacOS/Example", atomically: false, encoding: .utf8)
            Task { try? await Task.sleep(nanoseconds: 300_000_000); running.value = false }
        }
        let started = Date()
        try await expectRefusal("installed_unverified") {
            _ = try await adminInstaller(w.box, admin: adminPath(opener: opener), downloader: w.downloader, uid: geteuid(),
                                         installerRunning: { running.value })
                .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
        }
        try expect(Date().timeIntervalSince(started) >= 0.3, "gave up before Installer quit")
    }

    check("pkg: the wait for a half-written app ends at Done or after the settle limit, never holding a failure open") {
        for pressDone in [true, false] {
            let w = try packageWorld()
            let opener = FakeOpener()
            let target = w.target
            let interaction = AdminInteraction()
            opener.onOpen = { _ in
                try installByInstaller(target)
                try "TAMPERED half-written".write(toFile: target + "/Contents/MacOS/Example", atomically: false, encoding: .utf8)
                if pressDone { Task { try? await Task.sleep(nanoseconds: 200_000_000); interaction.userFinishedInstaller() } }
            }
            let waiter = VersionPollingWaiter(timeout: 5, interval: 0.02, stableReads: 2, settleInterval: 0.05, settleTimeout: pressDone ? 30 : 0.4)
            let started = Date()
            try await expectRefusal("unresolved") {
                _ = try await adminInstaller(w.box, admin: adminPath(opener: opener, waiter: waiter), downloader: w.downloader,
                                             uid: geteuid(), installerRunning: { true })
                    .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: interaction)
            }
            let took = Date().timeIntervalSince(started)
            try expect(took < 3, "\(pressDone ? "Done" : "settle limit") did not end the wait (\(took) s)")
        }
    }

    check("pkg: a timeout while Installer is still running keeps everything until Installer has quit") {
        let w = try packageWorld()
        let running = Flag(true)
        let waiter = VersionPollingWaiter(timeout: 0.3, interval: 0.02, stableReads: 2)
        try await expectRefusal("unresolved") {
            _ = try await adminInstaller(w.box, admin: adminPath(waiter: waiter), downloader: w.downloader, installerRunning: { running.value })
                .update(appAt: w.target, offer: offer(v2pkg, format: .pkg), installable: true, admin: AdminInteraction())
        }
        try expectEqual(try version(w.box.locations.backups + backupBundle), "1.0", "backup deleted while Installer runs")
        let early = await adminInstaller(w.box, admin: nil, installerRunning: { running.value }).recover()
        if case .failure(let refusal) = early.reports.first?.result { try expectEqual(refusal.code, "recovery_ambiguous") }
        else { throw CheckFailure(description: "recovered while Installer runs: \(early.reports)") }
        running.value = false
        let later = await adminInstaller(w.box, admin: nil, installerRunning: { running.value }).recover()
        try expectEqual(later.reports.map { try? $0.result.get() }, [.reverted])
        try expectConsistent(w, new: false)
        try expect(backupsFolder(w.box).isEmpty, "copy kept after a verified revert")
    }

    check("pkg: the waiter needs the change to settle before it reports it") {
        let box = try Sandbox()
        let target = try makeApp(at: box.apps + "/Example.app", short: "1.0", build: "100")
        let installed = try BundleFacts.read(bundleAt: target)
        let waiter = VersionPollingWaiter(timeout: 5, interval: 0.02, stableReads: 3)
        let started = Date()
        async let result = waiter.waitForInstaller(appAt: target, installed: installed, interaction: AdminInteraction())
        try await Task.sleep(nanoseconds: 100_000_000)
        try installByInstaller(target)
        try await expectEqualAsync(await result, .changed)
        try expect(Date().timeIntervalSince(started) < 4, "took too long")
        let quick = VersionPollingWaiter(timeout: 0.1, interval: 0.02, stableReads: 1)
        try await expectEqualAsync(await quick.waitForInstaller(appAt: target, installed: try BundleFacts.read(bundleAt: target), interaction: AdminInteraction()), .timedOut)
    }

    // MARK: Real pieces stay out of the checks

    check("the real admin prompt and Apple's Installer refuse under the real-state tripwire") {
        guard RealStateTripwire.isActive else { return }
        try await expectRefusal("admin_denied") { _ = try await WorkspacePrivilegedReplacer().authorize() }
        try await expectRefusal("installer_failed") { try SystemInstallerOpener().openInstaller(forPackageAt: "/nonexistent.pkg") }
    }

    check("the admin path uses no helper, sudo, installer command or AuthorizationExecuteWithPrivileges") {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String]) ?? []
        for relative in files where relative.hasSuffix(".swift") {
            let text = try String(contentsOfFile: sources.path + "/" + relative, encoding: .utf8)
            for forbidden in ["AuthorizationExecuteWithPrivileges", "/usr/bin/sudo", "\"sudo\"", "/usr/sbin/installer",
                              "SMJobBless", "SMAppService.daemon", "setuid("] {
                try expect(!text.contains(forbidden), "\(relative) mentions \(forbidden)")
            }
        }
    }
}

/// Verifies with `inner`, then changes the file, as malware racing the check would.
struct AfterVerify: PackageVerifying {
    let inner: any PackageVerifying
    let then: @Sendable (String) throws -> Void
    func verifyPackage(at path: String, teamID: String) throws {
        try inner.verifyPackage(at: path, teamID: teamID)
        try then(path)
    }
}

enum PackageSignatureProbe {
    static func refuses(output: String, path: String) throws -> Bool {
        do { try PackageSignature.interpretCheckSignature(status: 0, output: output, path: path, teamID: teamA); return false }
        catch is InstallRefusal { return true }
    }
}

func expectEqualAsync<T: Equatable>(_ a: T, _ b: T, line: Int = #line) async throws { try expectEqual(a, b, line: line) }
