import Foundation
import Darwin
import UpdateSources

public struct UpdateOptions: Sendable, Equatable {
    public var quitIfRunning: Bool
    public var dryRun: Bool
    public init(quitIfRunning: Bool = false, dryRun: Bool = false) { self.quitIfRunning = quitIfRunning; self.dryRun = dryRun }
}

/// Where one update has got to, for a row to show. Sent from whatever thread the installer is running on.
public enum UpdateProgress: Sendable, Equatable {
    /// Bytes received so far and the size when it is known (the feed's length or the server's Content-Length).
    case downloading(received: Int64, expected: Int64?)
    /// The download is complete: checking its digests and signature, unpacking and verifying the new app.
    case verifying
    /// The commit point: from here the swap is under way and the update can no longer be cancelled.
    case installing
}
public typealias UpdateProgressHandler = @Sendable (UpdateProgress) -> Void

/// Limits how often a progress handler hears about byte counts, always letting the final count through.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    init(interval: TimeInterval = 0.1) { self.interval = interval }
    func shouldEmit(complete: Bool) -> Bool {
        lock.withLock {
            let now = Date()
            if complete || now.timeIntervalSince(last) >= interval { last = now; return true }
            return false
        }
    }
}

public struct InstallReport: Sendable, Equatable {
    public enum Status: String, Sendable { case installed, dryRunPassed = "dry_run_passed", rolledBack = "rolled_back" }
    public let status: Status
    public let bundleID: String
    public let path: String
    public let fromVersion: String
    public let toVersion: String
    public let backupFolder: String?
    public let relaunched: Bool
    /// Temporary files or mounts that could not be removed (the journal is kept for `recover`).
    public var leftovers: [String] = []
    /// Installed through the admin path (macOS's prompt, or Apple's Installer for a pkg).
    public var privileged: Bool = false
    /// Owner (uid) of the installed bundle afterwards, recorded on the admin path.
    public var installedOwner: UInt32? = nil
    /// Anything else the user should know, such as "no backup could be kept".
    public var note: String? = nil
}

public struct RecoveryReport: Sendable, Equatable {
    public let journalID: String
    public let bundleID: String
    public let targetPath: String
    public let result: Result<RecoveryOutcome, InstallRefusal>
    /// What could not be cleaned up this time (the journal stays `cleanupPending`).
    public var leftovers: [String] = []
}

public enum RecoveryOutcome: String, Sendable, Equatable {
    /// Nothing in the target folder had changed; leftovers removed.
    case discarded
    /// The new version is installed and the old one is backed up.
    case completed
    /// The old version is back in place.
    case reverted
    /// An earlier run's leftover temporary files or mounts are now gone.
    case cleanedUp
    /// A Self Service install was interrupted after its copy reached the destination and before it was verified there;
    /// that copy (and only a copy the journal proves Patched put there) was removed, so the app is not installed.
    case removedUnfinishedInstall
    /// A Self Service install was interrupted after its copy reached the destination; the copy passed every check again
    /// there, so the install was finished and the app kept.
    case finishedFreshInstall
}

/// What the installer knows about the app it is about to replace, read from disk.
public struct InstallTarget: Sendable, Equatable {
    public let path: String
    public let facts: BundleFacts
    public let teamID: String
    public let identity: FileSafety.Identity
    /// Why replacing this app needs admin rights; set only when the caller allowed the admin path.
    public internal(set) var adminReason: InstallRefusal? = nil
    public var parent: String { (path as NSString).deletingLastPathComponent }
    public var name: String { (path as NSString).lastPathComponent }
    public var versionText: String { Self.versionText(facts.shortVersion, facts.build) }
    /// "1.0 (100)", "1.0" or the build alone; "?" when neither is known. The one wording used everywhere.
    public static func versionText(_ short: String?, _ build: String?) -> String {
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        case let (nil, b?): return b
        default: return "?"
        }
    }
}

public typealias TeamIDReader = @Sendable (String) -> String?

/// Phase 2a installer: verified, reversible replacement of apps the current user can replace without
/// admin rights, from zip and dmg downloads. Each step is a separate function so it can be tested alone.
public struct UpdateInstaller: Sendable {
    public let locations: InstallerLocations
    let downloader: any ArtifactDownloading
    let verifier: any CodeVerifying
    let runningApps: any RunningAppControlling
    let uid: uid_t
    let teamIDReader: TeamIDReader
    let hooks: TransactionHooks
    let quitTimeout: TimeInterval
    let unpackBudget: UnpackBudget
    let forceCopyBackup: Bool
    let diskImageDetacher: @Sendable (String) -> Bool
    /// Admin path (pkg through Apple's Installer, and experimental root-owned replacement); nil means both are off.
    let adminPath: AdminUpdatePath?
    /// Whether Apple's Installer is running; injectable for checks.
    let installerRunning: @Sendable () -> Bool
    /// The Self Service destination (~/Applications). Nil means the real one, resolved only when a fresh-install
    /// journal is recovered; checks pass a temporary folder.
    let selfServiceRoot: String?

    public init(locations: InstallerLocations,
                downloader: any ArtifactDownloading = URLSessionArtifactDownloader(),
                verifier: any CodeVerifying = SystemCodeVerifier(),
                runningApps: any RunningAppControlling = WorkspaceRunningApps(),
                uid: uid_t = geteuid(),
                teamIDReader: @escaping TeamIDReader = { CodeSigningIdentity.teamID(ofBundleAt: URL(fileURLWithPath: $0)) },
                hooks: TransactionHooks = .none,
                quitTimeout: TimeInterval = 30,
                unpackBudget: UnpackBudget = .standard,
                forceCopyBackup: Bool = false,
                diskImageDetacher: @escaping @Sendable (String) -> Bool = { Unpacker.detachDiskImage(at: $0) },
                adminPath: AdminUpdatePath? = nil,
                installerRunning: @escaping @Sendable () -> Bool = { InstallerActivity.isRunning() },
                selfServiceRoot: String? = nil) {
        self.locations = locations; self.downloader = downloader; self.verifier = verifier
        self.runningApps = runningApps; self.uid = uid; self.teamIDReader = teamIDReader
        self.hooks = hooks; self.quitTimeout = quitTimeout
        self.unpackBudget = unpackBudget; self.forceCopyBackup = forceCopyBackup
        self.diskImageDetacher = diskImageDetacher
        self.adminPath = adminPath
        self.installerRunning = installerRunning
        self.selfServiceRoot = selfServiceRoot
    }

    /// Whether each part of the admin path is switched on (each still needs an `AdminInteraction` per call).
    public var adminUpdatesEnabled: Bool { adminPath?.allowsReplacement == true }
    public var packageUpdatesEnabled: Bool { adminPath?.allowsPackages == true }

    var engine: SwapEngine {
        let apps = runningApps
        return SwapEngine(locations: locations, verifier: verifier, hooks: hooks, forceCopyBackup: forceCopyBackup,
                          runningCheck: { bundleID, paths in
                              for path in paths {
                                  let pids = apps.runningInstances(bundleID: bundleID, path: path)
                                  if !pids.isEmpty {
                                      throw InstallRefusal.appRunning("\((path as NSString).lastPathComponent) is running from \(path) (pid \(pids.map(String.init).joined(separator: ", ")))")
                                  }
                                  // Helpers inside the bundle (login items, XPC services, tools) are not app instances.
                                  let helpers = apps.bundleProcesses(path: path)
                                  if !helpers.isEmpty { throw Self.helperRefusal(name: (path as NSString).lastPathComponent, path: path, helpers) }
                              }
                          },
                          detach: diskImageDetacher, installerRunning: installerRunning,
                          selfServiceRoot: { [selfServiceRoot] in selfServiceRoot ?? (try? SelfServiceDestination.standard()) })
    }
    var store: JournalStore { JournalStore(directory: locations.transactions) }

    /// A process running from inside the bundle that cannot be asked to quit (it is not an app instance).
    /// Patched refuses and names it; it never kills anything.
    static func helperRefusal(name: String, path: String, _ helpers: [BundleProcess]) -> InstallRefusal {
        .helperRunning("\(name) has a helper process running from inside it that Patched can't ask to quit: "
                    + helpers.map { $0.description(inBundle: path) }.joined(separator: "; ")
                    + ". Quit it yourself, then try again")
    }

    // MARK: Step 1: preconditions

    /// Identity pin, path safety, user-replaceability and format. Read-only.
    public func checkPreconditions(appPath: String, format: ArtifactFormat?) throws -> InstallTarget {
        try inspect(appPath: appPath, format: format, allowAdmin: false)
    }

    /// `checkPreconditions`, optionally letting the admin path take what needs admin rights. With
    /// `allowAdmin` false every check throws exactly as it always did. With it true, ownership and folder
    /// permissions become `adminReason` instead, a `.pkg` is accepted, and file flags (immutable,
    /// append-only, SIP-restricted) are still refused because admin rights cannot replace those either.
    func inspect(appPath: String, format: ArtifactFormat?, allowAdmin: Bool) throws -> InstallTarget {
        guard appPath.lowercased().hasSuffix(".app") else { throw InstallRefusal.unsafePath("\(appPath) is not an .app bundle") }
        try FileSafety.requireNoSymlinks(appPath)
        guard let info = FileSafety.lstatInfo(appPath), FileSafety.isDirectory(info),
              let identity = FileSafety.directoryIdentity(appPath) else {
            throw InstallRefusal.unsafePath("\(appPath) is not a directory")
        }
        let facts = try BundleFacts.read(bundleAt: appPath)
        guard let team = teamIDReader(appPath), !team.isEmpty else {
            throw InstallRefusal.cannotPinIdentity("\(appPath) is unsigned or ad-hoc signed (no Team ID)")
        }
        guard TeamIdentifier.isValid(team) else { throw InstallRefusal.cannotPinIdentity("Team ID \"\(team)\" is malformed") }
        if let format {
            switch format {
            case .zip, .dmg: break
            case .pkg where !allowAdmin: throw InstallRefusal.unsupportedFormat("pkg installers need admin rights (Phase 2b)")
            case .pkg: break
            default: throw InstallRefusal.unsupportedFormat(format.rawValue)
            }
        }
        // Replaceable without admin: the whole bundle is ours, the folder it sits in is writable.
        if info.st_flags & UInt32(SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE) != 0 {
            throw InstallRefusal.needsAdmin("\(appPath) is protected by file flags")
        }
        var target = InstallTarget(path: appPath, facts: facts, teamID: team, identity: identity)
        if allowAdmin && format == .pkg {
            // Apple's Installer, not Patched, replaces the app; ownership does not matter, flags still do.
            try FileSafety.requireNoImmutableFlags(appPath)
            return target
        }
        /// Throws as always, unless the admin path may take it.
        func needsAdmin(_ refusal: InstallRefusal) throws {
            guard allowAdmin else { throw refusal }
            if target.adminReason == nil { target.adminReason = refusal }
        }
        do { try FileSafety.requireTreeOwned(by: uid, appPath) }
        catch let refusal as InstallRefusal where allowAdmin && refusal.code == "needs_admin" { try needsAdmin(refusal) }
        if info.st_mode & 0o200 == 0 { try needsAdmin(InstallRefusal.needsAdmin("\(appPath) is not writable by its owner")) }
        let parent = (appPath as NSString).deletingLastPathComponent
        guard let parentInfo = FileSafety.lstatInfo(parent), FileSafety.isDirectory(parentInfo) else {
            throw InstallRefusal.unsafePath("\(parent) is not a directory")
        }
        if access(parent, W_OK | X_OK) != 0 { try needsAdmin(InstallRefusal.needsAdmin("\(parent) is not writable by this user")) }
        if parentInfo.st_mode & S_ISVTX != 0 && parentInfo.st_uid != uid && info.st_uid != uid {
            try needsAdmin(InstallRefusal.needsAdmin("\(parent) is sticky and the app belongs to someone else"))
        }
        // Someone else's files are expected on the admin path; flags that would stop a replacement are not.
        if target.adminReason != nil { try FileSafety.requireNoImmutableFlags(appPath) }
        return target
    }

    // MARK: Step 2: download

    public func download(_ offer: UpdateOffer, into directory: String, progress: UpdateProgressHandler? = nil) async throws -> DownloadedArtifact {
        guard offer.downloadURL.scheme?.lowercased() == "https" else {
            throw InstallRefusal.insecureDownload(offer.downloadURL.absoluteString)
        }
        let expected = offer.length.map(Int64.init)
        if let expected, expected > DownloadLimits.maxBytes || expected <= 0 {
            throw InstallRefusal.tooLarge("feed length \(expected) is outside 1...\(DownloadLimits.maxBytes)")
        }
        let path = directory + "/artifact." + offer.format.rawValue
        let sink = try ArtifactSink(path: path, maxBytes: expected ?? DownloadLimits.maxBytes)
        sink.expectedTotal = expected
        if let progress {
            let throttle = ProgressThrottle()
            sink.onProgress = { received, total in
                if throttle.shouldEmit(complete: total.map { received >= $0 } ?? false) {
                    progress(.downloading(received: received, expected: total))
                }
            }
            progress(.downloading(received: 0, expected: expected))
        }
        do {
            try await downloader.download(offer.downloadURL, into: sink, expectedLength: expected)
        } catch InstallRefusal.tooLarge(let detail) where expected != nil {
            throw InstallRefusal.lengthMismatch("feed says \(expected!) bytes but the server sent more (\(detail))")
        } catch {
            // A cancelled download surfaces as a network error; report it as the cancellation it is.
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        let artifact = try sink.finish()
        try DigestCheck.verify(artifact, against: offer)
        return artifact
    }

    // MARK: Steps 4-6: unpack, select, verify

    /// Unpacks into `stagingDir`, leaves exactly one verified bundle at `stagingDir/<target name>`.
    public func stageAndVerify(artifact: String, format: ArtifactFormat, target: InstallTarget, offer: UpdateOffer?,
                               stagingDir: String, mountPoint: String?) throws -> BundleFacts {
        let staged = stagingDir + "/" + target.name
        let downloadBytes = Int64(FileSafety.lstatInfo(artifact)?.st_size ?? 0)
        try unpackBudget.preflight(volume: stagingDir, downloadBytes: downloadBytes)
        switch format {
        case .zip:
            let unpacked = stagingDir + "/unpacked"
            try FileSafety.makeFreshPrivateDirectory(unpacked)
            try Unpacker.extractZip(artifact, into: unpacked, budget: unpackBudget, downloadBytes: downloadBytes)
            let chosen = try BundleSelector.select(in: unpacked, bundleID: target.facts.bundleID)
            guard rename(chosen, staged) == 0 else { throw InstallRefusal.io("cannot move the unpacked app into place") }
            try FileSafety.removeTree(unpacked, within: stagingDir)
        case .dmg:
            guard let mountPoint else { throw InstallRefusal.unpackFailed("no mount point") }
            try FileSafety.makeFreshPrivateDirectory(mountPoint)
            try Unpacker.attachDiskImage(artifact, at: mountPoint)
            var copyError: Error?
            do {
                let chosen = try BundleSelector.select(in: mountPoint, bundleID: target.facts.bundleID)
                try Unpacker.copyBundle(chosen, to: staged, budget: unpackBudget, downloadBytes: downloadBytes)
            } catch { copyError = error }
            guard Unpacker.detachDiskImage(at: mountPoint) else {
                throw InstallRefusal.unpackFailed("could not detach the disk image at \(mountPoint)")
            }
            if let copyError { throw copyError }
        default:
            throw InstallRefusal.unsupportedFormat(format.rawValue)
        }
        return try verifyStaged(staged, target: target, offer: offer)
    }

    /// Bundle ID, symlinks, versions, then the code signature pinned to the installed Team ID and Gatekeeper.
    /// Gatekeeper applies to updates and rollbacks alike: a backup that is not notarised is refused.
    func verifyStaged(_ staged: String, target: InstallTarget, offer: UpdateOffer?) throws -> BundleFacts {
        guard let info = FileSafety.lstatInfo(staged), FileSafety.isDirectory(info) else {
            throw InstallRefusal.unsafePath("staged app is not a directory")
        }
        let facts = try BundleFacts.read(bundleAt: staged)
        guard facts.bundleID == target.facts.bundleID else {
            throw InstallRefusal.bundleNotFound("staged bundle ID \(facts.bundleID) is not \(target.facts.bundleID)")
        }
        try FileSafety.requireContainedSymlinks(staged)
        if let offer {
            try Self.checkVersions(staged: facts, installed: target.facts, offer: offer)
        }
        try verifier.verifySignature(ofBundleAt: staged, teamID: target.teamID)
        try verifier.assessGatekeeper(ofBundleAt: staged)
        return facts
    }

    /// The staged app must be the version the feed promised and strictly newer than what is installed.
    /// Uses `SourceVersioning`, the same source-aware rules Phase 1 used to offer the update.
    public static func checkVersions(staged: BundleFacts, installed: BundleFacts, offer: UpdateOffer) throws {
        guard SourceVersioning.matchesOffer(offer, short: staged.shortVersion, build: staged.build) else {
            throw InstallRefusal.versionMismatch("feed offers \(InstallTarget.versionText(offer.displayVersion, offer.buildVersion)), download contains \(InstallTarget.versionText(staged.shortVersion, staged.build))")
        }
        // When the download only matches because its build stands in for its short version (Homebrew,
        // Opera-style), the installed app's versions must be canonical numeric too, and ordering uses exact
        // digit comparison. Anything Patched cannot compare safely is refused rather than guessed.
        if let stagedVersion = SourceVersioning.bundleVersion(short: staged.shortVersion, build: staged.build,
                                                              against: offer.displayVersion, source: offer.source),
           stagedVersion != staged.shortVersion {
            guard let oldShort = installed.shortVersion, SourceVersioning.numericCompare(oldShort, oldShort) != nil,
                  installed.build.map({ SourceVersioning.numericCompare($0, $0) != nil }) ?? true,
                  let installedVersion = SourceVersioning.bundleVersion(short: oldShort, build: installed.build,
                                                                        against: offer.displayVersion, source: offer.source) else {
                throw InstallRefusal.notNewer("cannot compare \(InstallTarget.versionText(staged.shortVersion, staged.build)) with installed \(InstallTarget.versionText(installed.shortVersion, installed.build)) safely")
            }
            var floor = installedVersion
            if let oldBuild = installed.build, SourceVersioning.fullOrRefined(oldBuild, of: oldShort),
               SourceVersioning.numericCompare(oldBuild, floor) == .orderedDescending { floor = oldBuild }
            guard SourceVersioning.numericCompare(stagedVersion, floor) == .orderedDescending else {
                throw InstallRefusal.notNewer("\(InstallTarget.versionText(staged.shortVersion, staged.build)) is not newer than installed \(InstallTarget.versionText(installed.shortVersion, installed.build))")
            }
        }
        // Never a downgrade by display version, whatever the build numbers say.
        if let new = SourceVersioning.bundleVersion(short: staged.shortVersion, build: staged.build, against: offer.displayVersion, source: offer.source),
           let old = SourceVersioning.bundleVersion(short: installed.shortVersion, build: installed.build, against: offer.displayVersion, source: offer.source),
           SourceVersioning.compareDisplay(new, old, source: offer.source) == .orderedAscending {
            throw InstallRefusal.notNewer("\(new) is older than installed \(old)")
        }
        // Homebrew safety net, independent of how the versions were promoted: when the two short versions are
        // the same version family (one is a component prefix of the other, e.g. 139.0 and 139.0.6053) and both
        // builds are full dotted versions extending the shorter one (Opera-style), the download's build must be
        // strictly higher. A genuine short-version advance (1.2 -> 1.3) or plain build counters skip this.
        if case .homebrewCask = offer.source, let newShort = staged.shortVersion, let oldShort = installed.shortVersion,
           let newBuild = staged.build, let oldBuild = installed.build {
            let base = SourceVersioning.fullOrRefined(newShort, of: oldShort) ? oldShort
                : (SourceVersioning.fullOrRefined(oldShort, of: newShort) ? newShort
                   : (SourceVersioning.sameNumeric(newShort, oldShort) ? newShort : nil))
            if let base, SourceVersioning.fullOrRefined(newBuild, of: base), SourceVersioning.fullOrRefined(oldBuild, of: base),
               SourceVersioning.numericCompare(newBuild, oldBuild) != .orderedDescending {
                throw InstallRefusal.notNewer("build \(newBuild) is not newer than installed \(oldBuild)")
            }
        }
        if case .sparkle = offer.source, let newBuild = staged.build, let oldBuild = installed.build,
           VersionComparator.compare(newBuild, oldBuild) == .orderedAscending {
            throw InstallRefusal.notNewer("build \(newBuild) is older than installed \(oldBuild)")
        }
        guard let stagedShort = staged.shortVersion ?? staged.build else { throw InstallRefusal.notNewer("cannot compare versions") }
        switch SourceVersioning.isNewer(candidateShort: stagedShort, candidateBuild: staged.build,
                                        installedShort: installed.shortVersion, installedBuild: installed.build, source: offer.source,
                                        offered: offer.displayVersion) {
        case .success(true): return
        case .success(false), .failure:
            throw InstallRefusal.notNewer("\(InstallTarget.versionText(staged.shortVersion, staged.build)) is not newer than installed \(InstallTarget.versionText(installed.shortVersion, installed.build))")
        }
    }

    // MARK: Step 7: running app

    /// Returns whether the app was running (and has now quit).
    func ensureNotRunning(_ target: InstallTarget, quit: Bool) async throws -> Bool {
        let running = runningApps.runningInstances(bundleID: target.facts.bundleID, path: target.path)
        if !running.isEmpty {
            guard quit else { throw InstallRefusal.appRunning("\(target.name) (pid \(running.map(String.init).joined(separator: ", ")))") }
            guard await runningApps.quit(bundleID: target.facts.bundleID, path: target.path, timeout: quitTimeout) else {
                throw InstallRefusal.appWouldNotQuit("\(target.name) is still running after \(Int(quitTimeout)) s")
            }
        }
        do {
            try await ensureNoHelpers(name: target.name, path: target.path, grace: running.isEmpty ? 0 : min(quitTimeout, 3))
        } catch {
            // The app was quit for this update, but a helper (a login item, say) is still running from inside the
            // bundle, so nothing will be installed: reopen the app rather than leave it closed. The bundle has not
            // been touched yet.
            if !running.isEmpty { await runningApps.relaunch(path: target.path) }
            throw error
        }
        return !running.isEmpty
    }

    /// Refuses while any process runs from inside the bundle. After the app itself was asked to quit, its helpers
    /// get `grace` seconds to follow it out before they count.
    func ensureNoHelpers(name: String, path: String, grace: TimeInterval) async throws {
        var helpers = runningApps.bundleProcesses(path: path)
        let deadline = Date().addingTimeInterval(grace)
        while !helpers.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            helpers = runningApps.bundleProcesses(path: path)
        }
        if !helpers.isEmpty { throw Self.helperRefusal(name: name, path: path, helpers) }
    }

    // MARK: Guards shared by update and rollback

    func begin(_ target: InstallTarget) throws -> AppLock {
        try locations.prepare()
        let lock = try AppLock(directory: locations.transactions, bundleID: target.facts.bundleID)
        let listing = store.all()
        if let unreadable = listing.unreadable.first {
            // It could be about this app; never guess.
            throw InstallRefusal.unfinishedTransaction("journal \(unreadable) cannot be read; inspect or remove it")
        }
        if let pending = listing.journals.first(where: { !$0.isTerminal && ($0.targetPath == target.path || $0.bundleID == target.facts.bundleID) }) {
            throw InstallRefusal.unfinishedTransaction("journal \(pending.id) (\(pending.phase.rawValue))")
        }
        return lock
    }

    func backupFolder(for target: InstallTarget) -> String {
        locations.backups + "/" + target.facts.bundleID + "/" + target.facts.backupFolderName
    }

    /// Runs `body` with cleanup on every failure except a simulated crash (which must look like a kill).
    func cleaningUp<T>(_ journal: TransactionJournal, _ body: (inout TransactionJournal) async throws -> T) async throws -> T {
        var journal = journal
        do {
            return try await body(&journal)
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            // On the admin path `prepared` means the target may already have been handed to macOS, so only
            // `staging` is settled here; later failures are settled where they happen.
            if journal.phase == .staging || (journal.phase == .prepared && !journal.isPrivileged) {
                let left = try engine.settle(&journal, then: nil)
                if !left.isEmpty {
                    let reason = (error as? InstallRefusal)?.description ?? "\(error)"
                    throw InstallRefusal.cleanupIncomplete("\(reason); left behind: " + left.joined(separator: ", "))
                }
            }
            throw error
        }
    }

    // MARK: The whole update

    /// Installs the update a Phase 1 check found. Refuses anything that is not an available update or that
    /// the check marked not installable (for example a Homebrew cask matched by app filename only).
    /// `admin` is the consent for the experimental admin path: pass one only for an explicit user action.
    /// It is ignored (and admin-only updates are refused as before) unless this installer has an `AdminUpdatePath`.
    public func update(_ outcome: AppCheckOutcome, options: UpdateOptions = UpdateOptions(),
                       admin: AdminInteraction? = nil, progress: UpdateProgressHandler? = nil) async throws -> InstallReport {
        guard case .updateAvailable(let offer) = outcome.result else {
            throw InstallRefusal.notInstallable("\(outcome.app.name) has no available update")
        }
        if outcome.app.isWrappedIOSApp {
            throw InstallRefusal.appStoreManaged("\(outcome.app.path) is an iPhone or iPad app from the App Store")
        }
        return try await update(appAt: outcome.app.path, offer: offer, installable: outcome.installable, options: options, admin: admin,
                                progress: progress)
    }

    /// Lower-level entry point; the caller must say whether the offer is installable (no default, so it
    /// cannot be skipped by accident). `progress` hears about the download, then verifying, then the commit point;
    /// the task running this may be cancelled until `.installing`, and cancelling leaves the app and the state
    /// folders as they were. Only the ordinary zip and dmg path reports progress or can be cancelled.
    public func update(appAt appPath: String, offer: UpdateOffer, installable: Bool,
                       options: UpdateOptions = UpdateOptions(), admin: AdminInteraction? = nil,
                       progress: UpdateProgressHandler? = nil) async throws -> InstallReport {
        try Task.checkCancellation()
        // Before anything is downloaded: an App Store app is never replaced by Patched, whatever source offered an update.
        if FileManager.default.fileExists(atPath: appPath + "/Contents/_MASReceipt") {
            throw InstallRefusal.appStoreManaged("\(appPath) has a Mac App Store receipt")
        }
        // An iPhone/iPad app from the App Store has no Contents folder, only Wrapper/iTunesMetadata.plist.
        var wrapped = stat()
        if lstat(appPath + "/Wrapper/iTunesMetadata.plist", &wrapped) == 0 {
            throw InstallRefusal.appStoreManaged("\(appPath) is an iPhone or iPad app from the App Store")
        }
        guard installable else {
            throw InstallRefusal.notInstallable("the update source for \(appPath) is not confirmed (for example a Homebrew cask matched by filename only); add a catalogue entry")
        }
        let consent = adminConsent(admin, packages: offer.format == .pkg)
        let target = try inspect(appPath: appPath, format: offer.format, allowAdmin: consent != nil)
        if let consent, offer.format == .pkg {
            return try await packageUpdate(target, offer: offer, options: options, consent: consent)
        }
        if let consent, target.adminReason != nil {
            return try await privilegedUpdate(target, offer: offer, options: options, consent: consent)
        }
        let lock = try begin(target)
        defer { withExtendedLifetime(lock) {} }
        if !options.dryRun && !options.quitIfRunning {
            // Fail fast before downloading anything; checked again just before the swap.
            _ = try await ensureNotRunning(target, quit: false)
        } else if !options.dryRun && runningApps.runningInstances(bundleID: target.facts.bundleID, path: target.path).isEmpty {
            // Quitting is allowed, but the app is not open: a helper running now won't go away when the app
            // quits, so refuse before downloading anything.
            try await ensureNoHelpers(name: target.name, path: target.path, grace: 0)
        }

        let id = UUID().uuidString
        let now = TransactionJournal.now()
        let initial = TransactionJournal(
            id: id, kind: .update, phase: .staging, bundleID: target.facts.bundleID, teamID: target.teamID,
            targetPath: target.path, stagingDir: target.parent + "/.mac-updater-" + id,
            downloadDir: locations.downloads + "/" + id,
            mountPoint: offer.format == .dmg ? locations.downloads + "/" + id + "/mnt" : nil,
            oldIdentity: target.identity, oldShortVersion: target.facts.shortVersion, oldBuild: target.facts.build,
            backupDir: backupFolder(for: target), createdAt: now, updatedAt: now)
        return try await cleaningUp(initial) { journal in
            try engine.write(&journal)
            try FileSafety.makeFreshPrivateDirectory(journal.downloadDir!)
            try FileSafety.makeFreshPrivateDirectory(journal.stagingDir)
            guard FileSafety.directoryIdentity(journal.stagingDir)?.device == target.identity.device else {
                throw InstallRefusal.unsafePath("staging folder is not on the same volume as \(target.path)")
            }
            let artifact = try await download(offer, into: journal.downloadDir!, progress: progress)
            progress?(.verifying)
            try SparkleSignature.check(publicKey: target.facts.sparklePublicEDKey, signature: offer.edSignature,
                                       archivePath: artifact.path)
            try Task.checkCancellation()
            let staged = try stageAndVerify(artifact: artifact.path, format: offer.format, target: target, offer: offer,
                                            stagingDir: journal.stagingDir, mountPoint: journal.mountPoint)
            try Task.checkCancellation()
            if options.dryRun {
                let left = try engine.settle(&journal, then: nil)
                if !left.isEmpty {
                    throw InstallRefusal.cleanupIncomplete("dry run passed, but left behind: " + left.joined(separator: ", "))
                }
                return InstallReport(status: .dryRunPassed, bundleID: target.facts.bundleID, path: target.path,
                                     fromVersion: target.versionText,
                                     toVersion: InstallTarget.versionText(staged.shortVersion, staged.build),
                                     backupFolder: nil, relaunched: false)
            }
            // Bind what was verified: from here on the staged bundle must keep this identity.
            journal.newIdentity = FileSafety.directoryIdentity(journal.stagedBundlePath)
            journal.newShortVersion = staged.shortVersion
            journal.newBuild = staged.build
            // The download is no longer needed once staged; free the space before the swap.
            try FileSafety.removeTree(journal.downloadDir!, within: locations.downloads)
            // The commit point. A cancellation that arrives from here on is not acted on: the quit, the swap and
            // the checks after it run in their own task, so they finish (or roll back) as they would uncancelled.
            progress?(.installing)
            let (after, outcome) = await commitOutsideCancellation(journal, target: target, staged: staged, quit: options.quitIfRunning)
            journal = after
            return try outcome.get()
        }
    }

    /// Runs `commitAndRelaunch` in a task of its own, which a cancellation of the caller does not reach.
    private func commitOutsideCancellation(_ journal: TransactionJournal, target: InstallTarget, staged: BundleFacts,
                                           quit: Bool) async -> (TransactionJournal, Result<InstallReport, Error>) {
        await Task {
            var journal = journal
            let result: Result<InstallReport, Error>
            do { result = .success(try await commitAndRelaunch(&journal, target: target, staged: staged, status: .installed, quit: quit)) }
            catch { result = .failure(error) }
            return (journal, result)
        }.value
    }

    // MARK: Rollback

    /// `admin` as for `update`: an admin-owned app is rolled back through the same privileged path.
    public func rollback(appAt appPath: String, quitIfRunning: Bool = false, admin: AdminInteraction? = nil) async throws -> InstallReport {
        let consent = adminConsent(admin, packages: false)
        let target = try inspect(appPath: appPath, format: nil, allowAdmin: consent != nil)
        if let consent, target.adminReason != nil {
            return try await privilegedRollback(target, quitIfRunning: quitIfRunning, consent: consent)
        }
        let lock = try begin(target)
        defer { withExtendedLifetime(lock) {} }
        let (backup, backupBundle, backupFolder) = try rollbackSource(for: target)
        let id = UUID().uuidString
        let now = TransactionJournal.now()
        let initial = TransactionJournal(
            id: id, kind: .rollback, phase: .staging, bundleID: target.facts.bundleID, teamID: target.teamID,
            targetPath: target.path, stagingDir: target.parent + "/.mac-updater-" + id, restoredFrom: backupFolder,
            oldIdentity: target.identity, oldShortVersion: target.facts.shortVersion, oldBuild: target.facts.build,
            backupDir: backupFolderPath(for: target), createdAt: now, updatedAt: now)
        return try await cleaningUp(initial) { journal in
            try engine.write(&journal)
            try FileSafety.makeFreshPrivateDirectory(journal.stagingDir)
            guard FileSafety.directoryIdentity(journal.stagingDir)?.device == target.identity.device else {
                throw InstallRefusal.unsafePath("staging folder is not on the same volume as \(target.path)")
            }
            try FileSafety.requireContainedSymlinks(backupBundle)
            try Unpacker.copyBundle(backupBundle, to: journal.stagedBundlePath)
            let staged = try verifyStaged(journal.stagedBundlePath, target: target, offer: nil)
            journal.newIdentity = FileSafety.directoryIdentity(journal.stagedBundlePath)
            guard staged.shortVersion == backup.shortVersion, staged.build == backup.build else {
                throw InstallRefusal.versionMismatch("backup bundle is \(staged.shortVersion ?? "?"), metadata says \(backup.shortVersion ?? "?")")
            }
            journal.newShortVersion = staged.shortVersion
            journal.newBuild = staged.build
            return try await commitAndRelaunch(&journal, target: target, staged: staged, status: .rolledBack, quit: quitIfRunning)
        }
    }

    /// Quits the app if allowed, commits, and relaunches only after a verified terminal outcome. An
    /// unresolved transaction leaves the app stopped and says to run `recover`.
    func commitAndRelaunch(_ journal: inout TransactionJournal, target: InstallTarget, staged: BundleFacts,
                           status: InstallReport.Status, quit: Bool) async throws -> InstallReport {
        let wasRunning = try await ensureNotRunning(target, quit: quit)
        let result: EngineResult
        do {
            result = try engine.commit(&journal) {
                // Last look, immediately before the swap: a replacement instance may have been launched.
                let running = runningApps.runningInstances(bundleID: target.facts.bundleID, path: target.path)
                if !running.isEmpty {
                    throw InstallRefusal.appRunning("\(target.name) was started again (pid \(running.map(String.init).joined(separator: ", ")))")
                }
                let helpers = runningApps.bundleProcesses(path: target.path)
                if !helpers.isEmpty { throw Self.helperRefusal(name: target.name, path: target.path, helpers) }
            }
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            // Thrown before the swap: the target was never touched. Relaunch only if it still verifies.
            if wasRunning, (try? engine.verifyOld(target.path, journal)) != nil { await runningApps.relaunch(path: target.path) }
            throw error
        }
        switch result.outcome {
        case .installedVerified:
            if wasRunning { await runningApps.relaunch(path: target.path) }
            return InstallReport(status: status, bundleID: target.facts.bundleID, path: target.path,
                                 fromVersion: target.versionText,
                                 toVersion: InstallTarget.versionText(staged.shortVersion, staged.build),
                                 backupFolder: journal.backupDir, relaunched: wasRunning, leftovers: result.leftovers)
        case .restoredVerified:
            if wasRunning { await runningApps.relaunch(path: target.path) }
            throw result.refusal ?? InstallRefusal.verificationFailedAfterSwap("restored")
        case .unresolved:
            throw result.refusal ?? InstallRefusal.unresolved("journal \(journal.id)")
        }
    }

    /// `backupFolder(for:)` under a name that a local `backupFolder` in the callers cannot shadow.
    func backupFolderPath(for target: InstallTarget) -> String { backupFolder(for: target) }

    /// The newest backup, provided it is for this app and team, a different version, and not the folder the
    /// installed version's own backup is about to take.
    func rollbackSource(for target: InstallTarget) throws -> (record: BackupRecord, bundle: String, folder: String) {
        guard let backup = newestBackup(bundleID: target.facts.bundleID), let backupBundle = backup.bundlePath,
              let backupFolder = backup.folder else {
            throw InstallRefusal.noBackup("no backup for \(target.facts.bundleID)")
        }
        guard backup.installedByPackage != true else {
            throw InstallRefusal.rollbackUnsupported(
                "\(target.name) was updated by an installer package, which can install more than the app; reinstall the older version's package to go back")
        }
        guard backup.bundleID == target.facts.bundleID, backup.teamID == target.teamID else {
            throw InstallRefusal.signatureInvalid("backup metadata is for \(backup.bundleID) / \(backup.teamID)")
        }
        guard backup.shortVersion != target.facts.shortVersion || backup.build != target.facts.build else {
            throw InstallRefusal.versionMismatch("backup is the same version as the installed app")
        }
        guard backupFolder != backupFolderPath(for: target) else {
            throw InstallRefusal.versionMismatch("backup folder would be replaced by the installed version's backup")
        }
        return (backup, backupBundle, backupFolder)
    }

    // MARK: Recovery and backups

    /// Finishes or undoes interrupted transactions. Before anything that swaps or removes an app bundle it
    /// checks for instances running from the target or staged path; those are refused unless
    /// `quitIfRunning` (then asked to quit, never force-killed), and checked again right before any swap.
    public func recover(quitIfRunning: Bool = false) async -> (reports: [RecoveryReport], unreadable: [String]) {
        do { try locations.prepare() } catch let refusal as InstallRefusal {
            return ([RecoveryReport(journalID: "-", bundleID: "-", targetPath: "-", result: .failure(refusal))], [])
        } catch { return ([], []) }
        let listing = store.all()
        var reports: [RecoveryReport] = []
        for journal in listing.journals where !journal.isTerminal {
            var result: Result<RecoveryOutcome, InstallRefusal>
            var leftovers: [String] = []
            do {
                let lock = try AppLock(directory: locations.transactions, bundleID: journal.bundleID)
                defer { withExtendedLifetime(lock) {} }
                var quitTarget = false
                // Only bundles this recovery may actually swap or delete; an untouched running app is left alone.
                if (try? engine.validate(journal)) != nil {
                    for path in engine.pathsAtRisk(journal) {
                        let pids = runningApps.runningInstances(bundleID: journal.bundleID, path: path)
                        if !pids.isEmpty {
                            guard quitIfRunning else {
                                throw InstallRefusal.appRunning("\(journal.targetName) is running from \(path) (pid \(pids.map(String.init).joined(separator: ", "))); pass --quit")
                            }
                            guard await runningApps.quit(bundleID: journal.bundleID, path: path, timeout: quitTimeout) else {
                                throw InstallRefusal.appWouldNotQuit("\(journal.targetName) is still running from \(path) after \(Int(quitTimeout)) s")
                            }
                            if path == journal.targetPath { quitTarget = true }
                        }
                        try await ensureNoHelpers(name: journal.targetName, path: path, grace: pids.isEmpty ? 0 : min(quitTimeout, 3))
                    }
                }
                let recovered = try engine.recover(journal)
                leftovers = recovered.leftovers
                result = .success(recovered.outcome)
                // Relaunch what we quit only once the result is verified (completed and reverted verify the target).
                if quitTarget && (recovered.outcome == .completed || recovered.outcome == .reverted) {
                    await runningApps.relaunch(path: journal.targetPath)
                }
            } catch let refusal as InstallRefusal {
                result = .failure(refusal)
            } catch {
                result = .failure(.io("\(error)"))
            }
            reports.append(RecoveryReport(journalID: journal.id, bundleID: journal.bundleID, targetPath: journal.targetPath,
                                          result: result, leftovers: leftovers))
        }
        return (reports, listing.unreadable)
    }

    /// All backups, newest first.
    public func backups(bundleID: String? = nil) -> [BackupRecord] {
        let ids = bundleID.map { [$0] } ?? ((try? FileManager.default.contentsOfDirectory(atPath: locations.backups)) ?? []).sorted()
        var records: [BackupRecord] = []
        for id in ids where BundleFacts.isSafeBundleID(id) {
            let appBackups = locations.backups + "/" + id
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: appBackups)) ?? []) where !name.hasPrefix(".") {
                let folder = appBackups + "/" + name
                guard let data = FileSafety.readSmallFile(folder + "/backup.json", limit: 64 * 1024),
                      var record = try? JSONDecoder().decode(BackupRecord.self, from: data),
                      record.bundleID == id, !record.appName.contains("/"), record.appName.hasSuffix(".app"),
                      FileSafety.directoryIdentity(folder + "/" + record.appName) != nil else { continue }
                record.folder = folder
                records.append(record)
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    /// Full paths of journal files that cannot be read; every update is refused while one exists.
    public func unreadableJournalPaths() -> [String] {
        store.all().unreadable.map { locations.transactions + "/" + $0 }
    }

    public func newestBackup(bundleID: String) -> BackupRecord? { backups(bundleID: bundleID).first }
}
