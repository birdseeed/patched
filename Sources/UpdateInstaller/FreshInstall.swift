import Foundation
import Darwin
import UpdateSources

// Self Service fresh installs: a catalogue app that is not installed yet, into ~/Applications. This is the update
// pipeline with no app to replace. Download limits, digests, unpacking, bundle selection, the signature pinned to a
// Team ID, Gatekeeper, the journal and recovery are the same code the update path uses. What differs: the Team ID
// (and bundle ID, when the entry gives one) comes from the catalogue entry instead of the installed app, nothing is
// backed up, and the commit is a rename that refuses to overwrite anything (`RENAME_EXCL`) instead of a swap.

/// What a fresh install did.
public struct FreshInstallReport: Sendable, Equatable {
    /// The bundle's file name, for example "Example.app".
    public let appName: String
    public let bundleID: String
    public let path: String
    /// "2.0 (200)", in the same wording as updates.
    public let version: String
    /// The folder the app was installed in (~/Applications).
    public let folder: String
    /// Temporary files or mounts that could not be removed (the journal is kept for `recover`).
    public var leftovers: [String] = []

    public init(appName: String, bundleID: String, path: String, version: String, folder: String, leftovers: [String] = []) {
        self.appName = appName; self.bundleID = bundleID; self.path = path; self.version = version
        self.folder = folder; self.leftovers = leftovers
    }
}

/// Where Self Service installs: the current user's ~/Applications, and nowhere else in version one.
public enum SelfServiceDestination {
    /// ~/Applications, with the home folder from the account database (never `$HOME`). Refused under the test tripwire,
    /// so a check can never install into the real folder: checks pass a temporary folder instead.
    public static func standard() throws -> String {
        try RealStateTripwire.check("~/Applications for Self Service")
        guard let home = InstallerLocations.accountHome() else { throw InstallRefusal.io("cannot find the current user's home folder") }
        return home + "/Applications"
    }

    /// Creates `root` when it is missing (mode 0700, owned by this user). Refuses a symlink anywhere in its path, something
    /// that is not a folder, and a folder owned by someone else or not writable. An existing folder's permissions are
    /// never changed.
    static func prepare(_ root: String, uid: uid_t) throws {
        guard root.hasPrefix("/"), FileSafety.lexicallyNormalised(root) == root, root != "/" else {
            throw InstallRefusal.unsafePath("\(root) is not a normalised absolute path")
        }
        try FileSafety.requireNoSymlinks((root as NSString).deletingLastPathComponent)
        switch FileSafety.pathState(root) {
        case .absent:
            guard mkdir(root, 0o700) == 0 || errno == EEXIST else {
                throw InstallRefusal.io("could not create \(root): \(String(cString: strerror(errno)))")
            }
        case .unknown(let code):
            throw InstallRefusal.io("cannot tell whether \(root) exists: \(String(cString: strerror(code)))")
        case .present:
            break
        }
        try FileSafety.requireNoSymlinks(root)
        guard let info = FileSafety.lstatInfo(root), FileSafety.isDirectory(info) else {
            throw InstallRefusal.unsafePath("\(root) is not a folder")
        }
        guard info.st_uid == uid else { throw InstallRefusal.unsafePath("\(root) is not owned by the current user") }
        guard access(root, W_OK | X_OK) == 0 else { throw InstallRefusal.needsAdmin("\(root) is not writable by this user") }
    }

    /// A bundle file name Patched will create: ends in .app, not hidden, one path component, no colon.
    static func isPlainAppName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".app") && name.count > 4 && !name.hasPrefix(".") && !name.contains("/")
            && !name.contains(":") && name.utf8.count <= 255
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

extension UpdateInstaller {
    /// The lock every fresh install holds, so only one runs at a time; also the journal's bundle ID until the app in the
    /// download has been identified (when the entry names no bundle ID).
    static let selfServiceLock = "im.patched.self-service"

    /// Resolves the entry's newest version (the first network request for this entry) and installs it into `root`.
    public func installFromCatalogue(_ entry: SelfServiceEntry, into root: String, fetcher: any HTTPFetching,
                                     environment: HostEnvironment = .current,
                                     progress: UpdateProgressHandler? = nil) async throws -> FreshInstallReport {
        try Task.checkCancellation()
        if entry.needsAdmin { throw InstallRefusal.needsAdmin("\(entry.name) is marked in the catalogue as needing admin rights") }
        let offer: UpdateOffer
        switch await SelfServiceResolver.resolve(entry, fetcher: fetcher, environment: environment) {
        case .success(let found): offer = found
        case .failure(let reason):
            try Task.checkCancellation()
            throw InstallRefusal.notInstallable("could not find the latest version of \(entry.name): \(reason.message)")
        }
        return try await freshInstall(entry, offer: offer, into: root, progress: progress)
    }

    /// Installs `offer` for a catalogue entry into `root` (normally ~/Applications). `progress` and cancellation work as
    /// for an update: the task may be cancelled until `.installing`, and cancelling leaves nothing behind.
    public func freshInstall(_ entry: SelfServiceEntry, offer: UpdateOffer, into root: String,
                             progress: UpdateProgressHandler? = nil) async throws -> FreshInstallReport {
        try Task.checkCancellation()
        if entry.needsAdmin { throw InstallRefusal.needsAdmin("\(entry.name) is marked in the catalogue as needing admin rights") }
        guard TeamIdentifier.isValid(entry.teamID) else {
            throw InstallRefusal.cannotPinIdentity("the catalogue's Team ID \"\(entry.teamID)\" is not a valid Apple Team ID")
        }
        if let wanted = entry.bundleID, !BundleFacts.isSafeBundleID(wanted) {
            throw InstallRefusal.unsafePath("the catalogue's bundle ID \(wanted) is not usable")
        }
        guard offer.source == entry.source.updateSource else {
            throw InstallRefusal.notInstallable("the offer did not come from \(entry.name)'s catalogue source")
        }
        switch offer.format {
        case .zip, .dmg: break
        case .pkg: throw InstallRefusal.unsupportedFormat("installer packages (pkg) are not supported by Self Service")
        default: throw InstallRefusal.unsupportedFormat(offer.format.rawValue)
        }
        if let configured = selfServiceRoot, SwapEngine.canonical(configured) != SwapEngine.canonical(root) {
            throw InstallRefusal.unsafePath("\(root) is not this installer's Self Service folder")
        }
        try SelfServiceDestination.prepare(root, uid: uid)
        guard let rootIdentity = FileSafety.directoryIdentity(root) else { throw InstallRefusal.unsafePath("\(root) is not a folder") }
        try locations.prepare()
        let lock = try AppLock(directory: locations.transactions, bundleID: Self.selfServiceLock)
        defer { withExtendedLifetime(lock) {} }
        try refuseUnfinishedForFreshInstall(bundleID: entry.bundleID, targetPath: nil, excluding: nil)

        let id = UUID().uuidString
        let now = TransactionJournal.now()
        // The destination's name comes from the app in the download, so until that is known the journal names a
        // placeholder in the same folder. Nothing is ever created at the placeholder. The bundle ID is the placeholder
        // too, even when the entry names one: recovery takes the lock named by the journal's bundle ID, and until
        // `place` takes the app's own lock, the only lock this install holds is the placeholder's. So a concurrent
        // `recover` finds this journal locked instead of tearing down a live install.
        var initial = TransactionJournal(
            id: id, kind: .freshInstall, phase: .staging, bundleID: Self.selfServiceLock, teamID: entry.teamID,
            targetPath: root + "/" + id + ".app", stagingDir: root + "/.mac-updater-" + id,
            downloadDir: locations.downloads + "/" + id,
            mountPoint: offer.format == .dmg ? locations.downloads + "/" + id + "/mnt" : nil,
            createdAt: now, updatedAt: now)
        initial.destinationRoot = root
        var appLock: AppLock?
        defer { withExtendedLifetime(appLock) {} }
        return try await cleaningUp(initial) { journal in
            try engine.write(&journal)
            try FileSafety.makeFreshPrivateDirectory(journal.downloadDir!)
            try FileSafety.makeFreshPrivateDirectory(journal.stagingDir)
            guard FileSafety.directoryIdentity(journal.stagingDir)?.device == rootIdentity.device else {
                throw InstallRefusal.unsafePath("staging folder is not on the same volume as \(root)")
            }
            let artifact = try await download(offer, into: journal.downloadDir!, progress: progress)
            progress?(.verifying)
            try Task.checkCancellation()
            let staged = try stageFresh(artifact: artifact.path, entry: entry, offer: offer, root: root, journal: &journal, appLock: &appLock)
            try Task.checkCancellation()
            // Bind what was verified: from here on the staged bundle must keep this identity.
            journal.newIdentity = FileSafety.directoryIdentity(journal.stagedBundlePath)
            journal.newShortVersion = staged.shortVersion
            journal.newBuild = staged.build
            try FileSafety.removeTree(journal.downloadDir!, within: locations.downloads)
            // The commit point. Everything after it is synchronous, so a cancellation from here on is not acted on.
            progress?(.installing)
            return try commitFresh(&journal, root: root, rootIdentity: rootIdentity, staged: staged)
        }
    }

    /// Refuses while a journal cannot be read, or an unfinished one could be about the same app or another fresh install.
    func refuseUnfinishedForFreshInstall(bundleID: String?, targetPath: String?, excluding: String?) throws {
        let listing = store.all()
        if let unreadable = listing.unreadable.first {
            throw InstallRefusal.unfinishedTransaction("journal \(unreadable) cannot be read; inspect or remove it")
        }
        if let pending = listing.journals.first(where: {
            !$0.isTerminal && $0.id != excluding && ($0.kind == .freshInstall || $0.bundleID == bundleID || $0.targetPath == targetPath)
        }) {
            throw InstallRefusal.unfinishedTransaction("journal \(pending.id) (\(pending.phase.rawValue))")
        }
    }

    /// Unpacks, picks the one app (by the entry's bundle ID when it gives one), fixes the destination, and leaves exactly
    /// one verified bundle at the staged path. The destination must not exist.
    func stageFresh(artifact: String, entry: SelfServiceEntry, offer: UpdateOffer, root: String,
                    journal: inout TransactionJournal, appLock: inout AppLock?) throws -> BundleFacts {
        let downloadBytes = Int64(FileSafety.lstatInfo(artifact)?.st_size ?? 0)
        try unpackBudget.preflight(volume: journal.stagingDir, downloadBytes: downloadBytes)
        /// Records the real destination and bundle ID in the journal before the app is moved into staging under its name.
        func place(_ chosen: String, _ journal: inout TransactionJournal) throws {
            let name = (chosen as NSString).lastPathComponent
            guard SelfServiceDestination.isPlainAppName(name) else { throw InstallRefusal.unsafePath("the app in the download is called \(name)") }
            let destination = root + "/" + name
            guard FileSafety.pathState(destination) == .absent else {
                throw InstallRefusal.destinationExists("\(destination) already exists")
            }
            let facts = try BundleFacts.read(bundleAt: chosen)
            if facts.bundleID != Self.selfServiceLock {
                appLock = try AppLock(directory: locations.transactions, bundleID: facts.bundleID)
            }
            try refuseUnfinishedForFreshInstall(bundleID: facts.bundleID, targetPath: destination, excluding: journal.id)
            journal.targetPath = destination
            journal.bundleID = facts.bundleID
            try engine.write(&journal)
        }
        switch offer.format {
        case .zip:
            let unpacked = journal.stagingDir + "/unpacked"
            try FileSafety.makeFreshPrivateDirectory(unpacked)
            try Unpacker.extractZip(artifact, into: unpacked, budget: unpackBudget, downloadBytes: downloadBytes)
            let chosen = try BundleSelector.select(in: unpacked, bundleID: entry.bundleID)
            try place(chosen, &journal)
            guard rename(chosen, journal.stagedBundlePath) == 0 else { throw InstallRefusal.io("cannot move the unpacked app into place") }
            try FileSafety.removeTree(unpacked, within: journal.stagingDir)
        case .dmg:
            guard let mountPoint = journal.mountPoint else { throw InstallRefusal.unpackFailed("no mount point") }
            try FileSafety.makeFreshPrivateDirectory(mountPoint)
            try Unpacker.attachDiskImage(artifact, at: mountPoint)
            var copyError: Error?
            do {
                let chosen = try BundleSelector.select(in: mountPoint, bundleID: entry.bundleID)
                try place(chosen, &journal)
                try Unpacker.copyBundle(chosen, to: journal.stagedBundlePath, budget: unpackBudget, downloadBytes: downloadBytes)
            } catch { copyError = error }
            guard Unpacker.detachDiskImage(at: mountPoint) else {
                throw InstallRefusal.unpackFailed("could not detach the disk image at \(mountPoint)")
            }
            if let copyError { throw copyError }
        default:
            throw InstallRefusal.unsupportedFormat(offer.format.rawValue)
        }
        return try verifyFresh(journal.stagedBundlePath, entry: entry, offer: offer, bundleID: journal.bundleID)
    }

    /// The update path's staged checks, against the catalogue entry instead of an installed app: bundle ID, contained
    /// symlinks, the version the feed promised, the signature pinned to the entry's Team ID, and Gatekeeper.
    func verifyFresh(_ staged: String, entry: SelfServiceEntry, offer: UpdateOffer, bundleID: String) throws -> BundleFacts {
        guard let info = FileSafety.lstatInfo(staged), FileSafety.isDirectory(info) else {
            throw InstallRefusal.unsafePath("staged app is not a directory")
        }
        let facts = try BundleFacts.read(bundleAt: staged)
        guard facts.bundleID == bundleID, entry.bundleID.map({ $0 == facts.bundleID }) ?? true else {
            throw InstallRefusal.bundleNotFound("staged bundle ID \(facts.bundleID) is not \(entry.bundleID ?? bundleID)")
        }
        try FileSafety.requireContainedSymlinks(staged)
        guard SourceVersioning.matchesOffer(offer, short: facts.shortVersion, build: facts.build) else {
            throw InstallRefusal.versionMismatch("feed offers \(InstallTarget.versionText(offer.displayVersion, offer.buildVersion)), download contains \(InstallTarget.versionText(facts.shortVersion, facts.build))")
        }
        try verifier.verifySignature(ofBundleAt: staged, teamID: entry.teamID)
        try verifier.assessGatekeeper(ofBundleAt: staged)
        return facts
    }

    /// Moves the verified copy to the destination with a rename that never overwrites, then verifies it there. A copy that
    /// fails that last check is removed again (only that copy), so nothing unverified stays installed.
    func commitFresh(_ journal: inout TransactionJournal, root: String, rootIdentity: FileSafety.Identity,
                     staged: BundleFacts) throws -> FreshInstallReport {
        guard let recorded = journal.newIdentity, FileSafety.directoryIdentity(journal.stagedBundlePath) == recorded else {
            throw InstallRefusal.io("the staged app changed while the install was being prepared")
        }
        // The destination folder must still be the very folder that was checked at the start (device and inode), not a
        // folder or symlink swapped in since.
        try FileSafety.requireNoSymlinks(root)
        guard FileSafety.directoryIdentity(root) == rootIdentity else {
            throw InstallRefusal.unsafePath("\(root) changed while the install was being prepared")
        }
        journal.phase = .prepared
        try engine.write(&journal)
        guard FileSafety.pathState(journal.targetPath) == .absent else {
            throw InstallRefusal.destinationExists("\(journal.targetPath) appeared while the install was being prepared")
        }
        guard renamex_np(journal.stagedBundlePath, journal.targetPath, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw InstallRefusal.destinationExists("\(journal.targetPath) appeared just before the move") }
            throw InstallRefusal.swapFailed("renamex_np: \(String(cString: strerror(code)))")
        }
        // From here the destination holds our copy: the journal must never again be settled as if nothing changed.
        journal.phase = .swapped
        try hooks.atCheckpoint("freshInstall.moved")
        try FileSafety.syncDirectory(root)
        try engine.write(&journal)
        do {
            try engine.verifyInstalled(journal)
        } catch let refusal as InstallRefusal {
            let removed: Bool
            do {
                removed = try engine.removeFreshCopy(journal)
            } catch {
                // Running, or otherwise not removable. Patched never quits or kills it; the journal stays open for Recover.
                let reason = (error as? InstallRefusal)?.message ?? "\(error)"
                throw InstallRefusal.unresolved("the copy at \(journal.targetPath) failed verification (\(refusal.message)) and is not trusted; "
                    + "Patched could not remove it (\(reason)). Quit it if it is open, delete it, then run Recover")
            }
            let left = try engine.settle(&journal, then: .reverted)
            if !removed {
                throw InstallRefusal.recoveryAmbiguous("\(refusal.message); the item now at \(journal.targetPath) was not put there by Patched, so it was left alone")
            }
            guard left.isEmpty else {
                throw InstallRefusal.cleanupIncomplete("\(refusal.message); left behind: " + left.joined(separator: ", "))
            }
            throw refusal
        }
        let left = try engine.settle(&journal, then: .finished)
        return FreshInstallReport(appName: journal.targetName, bundleID: journal.bundleID, path: journal.targetPath,
                                  version: InstallTarget.versionText(staged.shortVersion, staged.build), folder: root, leftovers: left)
    }
}

extension SwapEngine {
    /// Recovery for an interrupted fresh install. Before the move: the staging area is discarded. After the move but
    /// before the journal recorded success, when the destination is the very copy this journal recorded (same device
    /// and inode): it is verified again (signature, Team ID, bundle ID, version, Gatekeeper); if that passes the install
    /// is finished and the app kept, otherwise the copy is removed, provided it still has the journal's bundle ID and
    /// nothing runs from it. Anything else at the destination is left alone. A finished install has nothing to undo
    /// (finished journals are never recovered).
    func recoverFreshInstall(_ original: TransactionJournal) throws -> (outcome: RecoveryOutcome, leftovers: [String]) {
        var journal = original
        switch journal.phase {
        case .staging:
            return (.discarded, try settle(&journal, then: nil))
        case .prepared, .swapped:
            if let recorded = journal.newIdentity, FileSafety.directoryIdentity(journal.targetPath) == recorded,
               (try? verifyInstalled(journal)) != nil {
                return (.finishedFreshInstall, try settle(&journal, then: .finished))
            }
            if try removeFreshCopy(journal) {
                return (.removedUnfinishedInstall, try settle(&journal, then: .reverted))
            }
            return (.discarded, try settle(&journal, then: nil))
        default:
            throw InstallRefusal.recoveryAmbiguous("journal \(journal.id) (\(journal.phase.rawValue)) is not a phase a fresh install uses")
        }
    }

    /// Removes the destination only when the journal proves Patched put it there. Returns false (touching nothing) when
    /// the destination is absent or is something else.
    func removeFreshCopy(_ journal: TransactionJournal) throws -> Bool {
        guard journal.kind == .freshInstall, let recorded = journal.newIdentity,
              FileSafety.directoryIdentity(journal.targetPath) == recorded else { return false }
        guard (try? BundleFacts.read(bundleAt: journal.targetPath))?.bundleID == journal.bundleID else {
            throw InstallRefusal.recoveryAmbiguous("\(journal.targetPath) is not the app this install put there (bundle ID differs); left in place")
        }
        try runningCheck(journal.bundleID, [journal.targetPath])
        let folder = (journal.targetPath as NSString).deletingLastPathComponent
        try FileSafety.removeTree(journal.targetPath, within: folder)
        try FileSafety.syncDirectory(folder)
        return true
    }
}
