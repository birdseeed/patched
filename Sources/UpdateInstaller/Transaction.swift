import Foundation
import Darwin

/// Metadata written next to every backup bundle.
public struct BackupRecord: Codable, Sendable, Equatable {
    public let bundleID: String
    public let teamID: String
    public let appName: String
    public let shortVersion: String?
    public let build: String?
    public let originalPath: String
    public let createdAt: String
    /// The update that replaced this version came from an installer package. Such a package can install more
    /// than the app (launch daemons, agents, drivers), so putting back only the old bundle is not a rollback:
    /// these backups are never restored. Absent (nil) in older records and for every other update.
    public var installedByPackage: Bool?
    /// Folder holding `appName` and `backup.json`; filled in when listed, not stored.
    public var folder: String?

    enum CodingKeys: String, CodingKey { case bundleID, teamID, appName, shortVersion, build, originalPath, createdAt, installedByPackage }
    public var bundlePath: String? { folder.map { $0 + "/" + appName } }
}

/// How a transaction that reached the swap ended. Only the first two let the app be relaunched.
public enum TransactionOutcome: String, Sendable, Equatable {
    /// The new bundle is installed and passed signature, Team ID, bundle ID, version and Gatekeeper checks.
    case installedVerified
    /// The old bundle was verified and put back at the target.
    case restoredVerified
    /// Stopped somewhere it could not prove good. Nothing was deleted; `recover` has to look at it.
    case unresolved
}

struct EngineResult: Sendable, Equatable {
    let outcome: TransactionOutcome
    /// Why it did not install, for `restoredVerified` and `unresolved`.
    let refusal: InstallRefusal?
    /// Temporary files or mounts that could not be removed; the journal stays `cleanupPending`.
    var leftovers: [String] = []
}

/// The swap, backup, re-verification and recovery shared by update, rollback and `recover`.
struct SwapEngine: Sendable {
    let locations: InstallerLocations
    let verifier: any CodeVerifying
    let hooks: TransactionHooks
    /// Tests: take the cross-volume copy path for backups even on one volume.
    var forceCopyBackup = false
    /// Throws `appRunning` if the app (bundle ID) runs from any of these paths. Called before any swap
    /// and before an app bundle is deleted.
    var runningCheck: @Sendable (String, [String]) throws -> Void = { _, _ in }
    /// Detaches a disk image; injectable so checks can make it fail.
    var detach: @Sendable (String) -> Bool = { Unpacker.detachDiskImage(at: $0) }
    /// Whether Apple's Installer is running (it may still change an app after Patched stopped watching).
    var installerRunning: @Sendable () -> Bool = { InstallerActivity.isRunning() }
    /// The Self Service folder a fresh-install journal must point into. Called only for fresh-install journals.
    var selfServiceRoot: @Sendable () -> String? = { nil }
    var store: JournalStore { JournalStore(directory: locations.transactions) }

    func write(_ journal: inout TransactionJournal) throws {
        try store.write(&journal)
        try hooks.afterJournalWrite(journal.phase)
    }

    static func swap(_ a: String, _ b: String) -> Int32 {
        renamex_np(a, b, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }

    // MARK: Paths read back from journals are checked before anything is moved or deleted.

    func validate(_ journal: TransactionJournal) throws {
        let target = journal.targetPath
        let parent = (target as NSString).deletingLastPathComponent
        guard target.hasPrefix("/"), target.lowercased().hasSuffix(".app"), FileSafety.lexicallyNormalised(target) == target else {
            throw InstallRefusal.journal("target path \(target) is not a normalised .app path")
        }
        guard (journal.stagingDir as NSString).deletingLastPathComponent == stagingRoot(journal),
              (journal.stagingDir as NSString).lastPathComponent == ".mac-updater-" + journal.id else {
            throw InstallRefusal.journal("staging folder \(journal.stagingDir) is not where it should be")
        }
        if let download = journal.downloadDir, download != locations.downloads + "/" + journal.id {
            throw InstallRefusal.journal("download folder \(download) is not where it should be")
        }
        if let mount = journal.mountPoint, mount != locations.downloads + "/" + journal.id + "/mnt" {
            throw InstallRefusal.journal("mount point \(mount) is not where it should be")
        }
        guard BundleFacts.isSafeBundleID(journal.bundleID) else { throw InstallRefusal.journal("bad bundle ID") }
        guard TeamIdentifier.isValid(journal.teamID) else { throw InstallRefusal.journal("bad Team ID") }
        let appBackups = locations.backups + "/" + journal.bundleID
        for folder in [journal.backupDir, journal.restoredFrom].compactMap({ $0 }) {
            let name = (folder as NSString).lastPathComponent
            guard (folder as NSString).deletingLastPathComponent == appBackups, !name.hasPrefix("."), name != ".." else {
                throw InstallRefusal.journal("backup folder \(folder) is not where it should be")
            }
        }
        if let partial = journal.backupCopyPartial {
            let name = (partial as NSString).lastPathComponent
            guard let backupDir = journal.backupDir, (partial as NSString).deletingLastPathComponent == backupDir,
                  name.hasPrefix(".partial-"), !name.contains("/") else {
                throw InstallRefusal.journal("backup copy \(partial) is not where it should be")
            }
        }
        if journal.kind == .freshInstall {
            // A fresh install's target must sit directly in the folder the journal recorded, and that folder must be
            // this user's Self Service folder: a journal cannot point recovery at an app anywhere else.
            guard let root = journal.destinationRoot, root.hasPrefix("/"), FileSafety.lexicallyNormalised(root) == root, parent == root else {
                throw InstallRefusal.journal("fresh install target \(target) is not in its recorded destination folder")
            }
            guard let allowed = selfServiceRoot(), Self.canonical(allowed) == Self.canonical(root) else {
                throw InstallRefusal.journal("fresh install folder \(root) is not this user's Self Service folder")
            }
        }
                // The folders we may move or delete in must not sit under a symlink.
        try FileSafety.requireNoSymlinks(parent)
        for root in [locations.downloads, locations.backups] where FileSafety.exists(root) { try FileSafety.requireNoSymlinks(root) }
    }

    /// A path resolved on disk when it exists, otherwise normalised, so two spellings of one folder compare equal.
    static func canonical(_ path: String) -> String { FileSafety.realPath(path) ?? FileSafety.lexicallyNormalised(path) }

    /// The folder holding the staging folder: beside the target for ordinary swaps (one rename), the
    /// private downloads folder on the admin path (the target's folder may not be writable by the user).
    func stagingRoot(_ journal: TransactionJournal) -> String {
        journal.isPrivileged ? locations.downloads : (journal.targetPath as NSString).deletingLastPathComponent
    }

    // MARK: Cleanup (every recursive delete goes through FileSafety.removeTree(_:within:))

    /// Detaches any image and removes the staging and download folders. Never deletes through a mount or
    /// a bundle that is running. Returns what could not be removed (empty when everything is gone).
    func cleanUp(_ journal: TransactionJournal) -> [String] {
        var left: [String] = []
        var stillMounted = false
        if let mount = journal.mountPoint {
            if case .unknown = FileSafety.pathState(mount) {
                left.append("cannot inspect mount point \(mount)")
                stillMounted = true
            } else if Unpacker.isMountPoint(mount), !detach(mount) {
                left.append("disk image still attached at \(mount)")
                stillMounted = true
            }
        }
        // Anything whose existence cannot be established (permission or I/O error) counts as left over.
        if FileSafety.pathState(journal.stagingDir) != .absent {
            do {
                if FileSafety.exists(journal.stagedBundlePath) { try runningCheck(journal.bundleID, [journal.stagedBundlePath]) }
                try FileSafety.removeTree(journal.stagingDir, within: stagingRoot(journal))
            } catch {
                left.append(journal.stagingDir)
            }
        }
        if let download = journal.downloadDir, FileSafety.pathState(download) != .absent {
            if stillMounted { left.append(download) }
            else if (try? FileSafety.removeTree(download, within: locations.downloads)) == nil { left.append(download) }
        }
        return left
    }

    /// Cleans up and moves the journal to its end state (`then`, or deleted when nil). If anything is left
    /// over the journal becomes `cleanupPending` instead, listing it, so `recover` can try again.
    /// A fresh install that reaches an end state (finished or reverted) is deleted rather than kept: there is no backup
    /// to roll back to, so the record has no further use, and keeping it would make an older Patched (which does not
    /// know the `freshInstall` kind) pause all updates over an unreadable journal after a downgrade.
    @discardableResult
    func settle(_ journal: inout TransactionJournal, then requested: TransactionJournal.Phase?) throws -> [String] {
        let then = journal.kind == .freshInstall ? nil : requested
        var left = cleanUp(journal)
        if then == .finished { left += pruneBackups(keeping: journal) }
        if left.isEmpty {
            if let then {
                journal.phase = then; journal.cleanupPending = nil; journal.cleanupThen = nil
                try write(&journal)
            } else {
                store.delete(journal.id)
            }
        } else {
            journal.phase = .cleanupPending; journal.cleanupPending = left; journal.cleanupThen = then
            try write(&journal)
        }
        return left
    }

    /// Removes every other backup of this app. Returns what could not be removed.
    func pruneBackups(keeping journal: TransactionJournal) -> [String] {
        guard let keep = journal.backupDir else { return [] }
        let appBackups = (keep as NSString).deletingLastPathComponent
        let keepName = (keep as NSString).lastPathComponent
        guard (try? FileSafety.requireNoSymlinks(appBackups)) != nil else { return [appBackups] }
        var left: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: appBackups)) ?? [] where name != keepName {
            if (try? FileSafety.removeTree(appBackups + "/" + name, within: locations.backups)) == nil { left.append(appBackups + "/" + name) }
        }
        // Leftover partial copies inside the kept folder.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: keep)) ?? [] where name.hasPrefix(".partial-") {
            if (try? FileSafety.removeTree(keep + "/" + name, within: locations.backups)) == nil { left.append(keep + "/" + name) }
        }
        return left
    }

    // MARK: Verification

    /// Bundle ID and version from disk, then the signature pinned to the Team ID, then (optionally) Gatekeeper.
    func verifyBundle(_ path: String, _ journal: TransactionJournal, short: String?, build: String?, gatekeeper: Bool) throws {
        let facts = try BundleFacts.read(bundleAt: path)
        guard facts.bundleID == journal.bundleID else {
            throw InstallRefusal.signatureInvalid("\(path) has bundle ID \(facts.bundleID), expected \(journal.bundleID)")
        }
        guard facts.shortVersion == short, facts.build == build else {
            throw InstallRefusal.versionMismatch("\(path) is \(facts.shortVersion ?? "?") (\(facts.build ?? "?")), expected \(short ?? "?") (\(build ?? "?"))")
        }
        try verifier.verifySignature(ofBundleAt: path, teamID: journal.teamID)
        if gatekeeper { try verifier.assessGatekeeper(ofBundleAt: path) }
    }

    /// What is now at the target must be the verified new bundle: signature, Team ID, bundle ID, version, Gatekeeper.
    func verifyInstalled(_ journal: TransactionJournal) throws {
        try verifyBundle(journal.targetPath, journal, short: journal.newShortVersion, build: journal.newBuild, gatekeeper: true)
    }

    /// The bundle we would put back (or keep as the backup) must be the old app: signature, Team ID, bundle
    /// ID and version. Not Gatekeeper: it is what the user already had installed.
    func verifyOld(_ path: String, _ journal: TransactionJournal) throws {
        try verifyBundle(path, journal, short: journal.oldShortVersion, build: journal.oldBuild, gatekeeper: false)
    }

    /// Turns refusals after the swap into an `unresolved` result; only a simulated crash escapes.
    func resolving(_ body: () throws -> EngineResult) throws -> EngineResult {
        do { return try body() }
        catch let refusal as InstallRefusal { return EngineResult(outcome: .unresolved, refusal: .unresolved(refusal.message)) }
    }

    // MARK: Commit

    /// From a verified staged bundle to a terminal outcome. Errors thrown before the swap leave the target
    /// untouched (the caller cleans up). After the swap the result says what is installed.
    func commit(_ journal: inout TransactionJournal, preSwapCheck: () throws -> Void) throws -> EngineResult {
        guard let backupDir = journal.backupDir else { throw InstallRefusal.journal("no backup folder chosen") }
        let appBackups = (backupDir as NSString).deletingLastPathComponent
        try FileSafety.makePrivateDirectory(appBackups)
        if FileSafety.exists(backupDir) {
            // An older backup with the same version: set it aside. It is pruned once this transaction finishes,
            // and put back if the swap does not happen.
            guard rename(backupDir, appBackups + "/.superseded-" + journal.id) == 0 else {
                throw InstallRefusal.io("cannot move aside existing backup \(backupDir)")
            }
        }
        do {
            guard journal.oldIdentity == FileSafety.directoryIdentity(journal.targetPath),
                  journal.newIdentity == FileSafety.directoryIdentity(journal.stagedBundlePath) else {
                throw InstallRefusal.io("the installed or staged bundle changed while the update was being prepared")
            }

            journal.phase = .prepared
            try write(&journal)
            try preSwapCheck()
            let swapError = Self.swap(journal.stagedBundlePath, journal.targetPath)
            guard swapError == 0 else {
                throw InstallRefusal.swapFailed("renamex_np: \(String(cString: strerror(swapError)))")
            }
        } catch let crash as SimulatedCrash {
            throw crash   // a crash leaves things as they are; recovery restores the set-aside backup
        } catch {
            // The swap did not happen: the earlier backup must not stay hidden.
            restoreSuperseded(journal)
            throw error
        }
        var swapped = journal
        defer { journal = swapped }
        return try resolving {
            swapped.phase = .swapped
            try write(&swapped)
            return try finishAfterSwap(&swapped)
        }
    }

    /// Puts back the backup `commit` (or the admin path's backup copy) set aside as `.superseded-<id>`, when this
    /// transaction ends without a swap. Does nothing if there is nothing set aside or the backup folder is taken.
    func restoreSuperseded(_ journal: TransactionJournal) {
        guard let backupDir = journal.backupDir else { return }
        let aside = (backupDir as NSString).deletingLastPathComponent + "/.superseded-" + journal.id
        guard FileSafety.pathState(aside) != .absent, FileSafety.pathState(backupDir) == .absent else { return }
        _ = rename(aside, backupDir)
    }

    /// From `swapped`: verify what is installed, then back up the old bundle and finish; or swap back.
    func finishAfterSwap(_ journal: inout TransactionJournal) throws -> EngineResult {
        do {
            try verifyInstalled(journal)
        } catch let refusal as InstallRefusal {
            return try swapBack(&journal, because: refusal)
        }
        journal.phase = .backingUp
        try write(&journal)
        try moveOutgoingToBackup(&journal)
        journal.phase = .backedUp
        try write(&journal)
        return try finish(&journal)
    }

    /// Puts the old bundle back, but only if it still verifies as the old app. Otherwise touches nothing.
    func swapBack(_ journal: inout TransactionJournal, because reason: InstallRefusal) throws -> EngineResult {
        journal.phase = .swapBack
        try write(&journal)
        do {
            try verifyOld(journal.stagedBundlePath, journal)
        } catch let refusal as InstallRefusal {
            return EngineResult(outcome: .unresolved, refusal: .unresolved(
                "the new app failed verification (\(reason.message)) and the old app to put back also failed (\(refusal.message)); both left in place"))
        }
        try runningCheck(journal.bundleID, [journal.targetPath, journal.stagedBundlePath])
        let error = Self.swap(journal.stagedBundlePath, journal.targetPath)
        guard error == 0 else {
            return EngineResult(outcome: .unresolved, refusal: .unresolved("could not swap the old app back: \(String(cString: strerror(error)))"))
        }
        do {
            try verifyOld(journal.targetPath, journal)
        } catch let refusal as InstallRefusal {
            return EngineResult(outcome: .unresolved, refusal: .unresolved("the restored app failed verification: \(refusal.message)"))
        }
        restoreSuperseded(journal)
        let left = try settle(&journal, then: .reverted)
        return EngineResult(outcome: .restoredVerified, refusal: .verificationFailedAfterSwap(reason.message), leftovers: left)
    }

    /// Is what sits at the backup path provably this transaction's old bundle?
    /// Same-volume move: it is the old bundle's own inode. Copy: it is the copy this journal recorded, and it
    /// still verifies as the old app. Anything else is unexplained.
    func backupEvidence(_ journal: TransactionJournal) throws -> Bool {
        guard let destination = journal.backupBundlePath, let found = FileSafety.directoryIdentity(destination) else { return false }
        if found == journal.oldIdentity { return true }
        if let copy = journal.backupCopyIdentity, found == copy {
            try verifyOld(destination, journal)
            return true
        }
        throw InstallRefusal.recoveryAmbiguous("\(destination) exists but is not this transaction's backup; the old app was kept")
    }

    /// Moves the outgoing bundle (now at the staged path) into the backup folder. Same volume: rename, then
    /// check the inode arrived. Other volume: copy to a partial name, verify the copy, sync every file and
    /// folder, full-sync, rename into place, sync the folder, record the copy in the journal, and only then
    /// delete the original. Any failure keeps the original.
    func moveOutgoingToBackup(_ journal: inout TransactionJournal) throws {
        guard let backupDir = journal.backupDir, let destination = journal.backupBundlePath else {
            throw InstallRefusal.journal("no backup folder chosen")
        }
        try FileSafety.makePrivateDirectory(backupDir)
        let staged = journal.stagedBundlePath
        if let copy = journal.backupCopyIdentity {
            let atDestination = FileSafety.directoryIdentity(destination) == copy
            let atPartial = journal.backupCopyPartial.flatMap(FileSafety.directoryIdentity) == copy
            if atDestination || atPartial { return try publishRecordedCopy(&journal) }
            if !FileSafety.exists(destination) {
                // The recorded copy vanished before it was published; the original is still in staging.
                journal.backupCopyIdentity = nil; journal.backupCopyPartial = nil
                try write(&journal)
            }
        }
        if try backupEvidence(journal) {
            if journal.backupCopyIdentity != nil, FileSafety.directoryIdentity(staged) == journal.oldIdentity {
                try runningCheck(journal.bundleID, [staged])
                try FileSafety.removeTree(staged, within: journal.stagingDir)
            }
            return
        }
        guard FileSafety.directoryIdentity(staged) == journal.oldIdentity else {
            throw InstallRefusal.recoveryAmbiguous("the old app is not where the journal says (\(staged))")
        }
        if !forceCopyBackup {
            if rename(staged, destination) == 0 {
                guard FileSafety.directoryIdentity(destination) == journal.oldIdentity else {
                    throw InstallRefusal.recoveryAmbiguous("the moved backup at \(destination) is not the old app")
                }
                try FileSafety.syncDirectory(backupDir)
                try FileSafety.syncDirectory(journal.stagingDir)
                return
            }
            guard errno == EXDEV else {
                throw InstallRefusal.io("cannot move the old app into backups: \(String(cString: strerror(errno)))")
            }
        }
        let partial = backupDir + "/.partial-" + UUID().uuidString
        do {
            try Unpacker.copyBundle(staged, to: partial)
            try verifyOld(partial, journal)
            try FileSafety.syncTree(partial)
            try FileSafety.syncDirectory(backupDir)
        } catch {
            try? FileSafety.removeTree(partial, within: locations.backups)
            throw error
        }
        try hooks.atCheckpoint("backup.copied")
        // Record the verified copy and where it is before publishing it, so a crash on either side of the
        // rename is recognisable.
        journal.backupCopyIdentity = FileSafety.directoryIdentity(partial)
        journal.backupCopyPartial = partial
        try write(&journal)
        try hooks.atCheckpoint("backup.copyRecorded")
        try publishRecordedCopy(&journal)
    }

    /// Renames the recorded partial copy into place (if it is not there yet), then deletes the original.
    func publishRecordedCopy(_ journal: inout TransactionJournal) throws {
        guard let destination = journal.backupBundlePath, let backupDir = journal.backupDir,
              let copy = journal.backupCopyIdentity else { throw InstallRefusal.journal("no recorded backup copy") }
        if FileSafety.directoryIdentity(destination) != copy {
            guard let partial = journal.backupCopyPartial, FileSafety.directoryIdentity(partial) == copy,
                  !FileSafety.exists(destination) else {
                throw InstallRefusal.recoveryAmbiguous("the recorded backup copy is not at \(journal.backupCopyPartial ?? "?") or \(destination)")
            }
            try verifyOld(partial, journal)
            guard rename(partial, destination) == 0 else { throw InstallRefusal.io("cannot place the backup copy") }
            try FileSafety.syncDirectory(backupDir)
            try hooks.atCheckpoint("backup.renamed")
        }
        try verifyOld(destination, journal)
        if FileSafety.directoryIdentity(journal.stagedBundlePath) == journal.oldIdentity {
            try runningCheck(journal.bundleID, [journal.stagedBundlePath])
            try FileSafety.removeTree(journal.stagedBundlePath, within: journal.stagingDir)
        }
    }

    /// Last step on every completion path: the installed bundle must verify again before anything that
    /// could restore the old one (the previous backup, the restored-from folder) is deleted.
    func finish(_ journal: inout TransactionJournal) throws -> EngineResult {
        do {
            try verifyInstalled(journal)
        } catch let refusal as InstallRefusal {
            return EngineResult(outcome: .unresolved, refusal: .unresolved(
                "installed app failed verification (\(refusal.message)); the previous version is kept at \(journal.backupBundlePath ?? "?")"))
        }
        try writeBackupRecord(journal)
        let left = try settle(&journal, then: .finished)
        return EngineResult(outcome: .installedVerified, refusal: nil, leftovers: left)
    }

    /// `backup.json` for the old version, next to its bundle in `backupDir`.
    func writeBackupRecord(_ journal: TransactionJournal) throws {
        guard let backupDir = journal.backupDir else { throw InstallRefusal.journal("no backup folder chosen") }
        let record = BackupRecord(bundleID: journal.bundleID, teamID: journal.teamID, appName: journal.targetName,
                                  shortVersion: journal.oldShortVersion, build: journal.oldBuild,
                                  originalPath: journal.targetPath, createdAt: TransactionJournal.now(),
                                  installedByPackage: journal.viaInstaller == true ? true : nil, folder: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileSafety.writeAtomically(try encoder.encode(record), to: backupDir + "/backup.json")
    }

    // MARK: Recovery

    /// The bundle paths a recovery of this journal may swap or delete, judged from what is on disk now.
    /// A discard only touches the staged copy; only a possible swap-back touches the target.
    func pathsAtRisk(_ journal: TransactionJournal) -> [String] {
        // Recovery never uses admin rights, so on the admin path it only ever deletes its own staged copy.
        if journal.isPrivileged { return [journal.stagedBundlePath] }
        if journal.kind == .freshInstall {
            // Only a copy the journal proves Patched moved to the destination may be removed.
            let ours = journal.newIdentity != nil && FileSafety.directoryIdentity(journal.targetPath) == journal.newIdentity
            return ours && journal.phase != .staging ? [journal.targetPath, journal.stagedBundlePath] : [journal.stagedBundlePath]
        }
        if journal.phase == .staging || journal.phase == .cleanupPending { return [journal.stagedBundlePath] }
        let target = FileSafety.directoryIdentity(journal.targetPath)
        let staged = FileSafety.directoryIdentity(journal.stagedBundlePath)
        switch (target, staged) {
        case (journal.oldIdentity, journal.newIdentity): return [journal.stagedBundlePath]
        case (journal.newIdentity, journal.oldIdentity): return [journal.targetPath, journal.stagedBundlePath]
        default: return []
        }
    }

    /// Drives one unfinished journal to a consistent state. Idempotent: running it again after a crash in
    /// the middle picks up from whatever is on disk. Anything it cannot explain is refused untouched.
    func recover(_ original: TransactionJournal) throws -> (outcome: RecoveryOutcome, leftovers: [String]) {
        var journal = original
        try validate(journal)
        if journal.phase == .cleanupPending {
            if journal.cleanupThen == .finished {
                // Finishing prunes older backups: only once the installed app still verifies.
                do { try verifyInstalled(journal) } catch let refusal as InstallRefusal {
                    throw InstallRefusal.unresolved("installed app failed verification (\(refusal.message)); backups kept")
                }
            }
            let left = try settle(&journal, then: journal.cleanupThen)
            guard left.isEmpty else { throw InstallRefusal.cleanupIncomplete("still cannot remove: " + left.joined(separator: ", ")) }
            return (.cleanedUp, [])
        }
        if journal.isPrivileged { return try recoverPrivileged(journal) }
        if journal.kind == .freshInstall { return try recoverFreshInstall(journal) }
        if journal.phase == .staging {
            restoreSuperseded(journal)
            return (.discarded, try settle(&journal, then: nil))
        }
        let target = FileSafety.directoryIdentity(journal.targetPath)
        let staged = FileSafety.directoryIdentity(journal.stagedBundlePath)
        let backupPresent = journal.backupBundlePath.flatMap(FileSafety.directoryIdentity) != nil
        let old = journal.oldIdentity, new = journal.newIdentity
        guard old != nil, new != nil else { throw InstallRefusal.recoveryAmbiguous("journal \(journal.id) has no bundle identities") }

        func describe() -> String {
            func which(_ id: FileSafety.Identity?) -> String { id == nil ? "missing" : id == old ? "old" : id == new ? "new" : "unknown" }
            return "journal \(journal.id) (\(journal.phase.rawValue)): target is \(which(target)), staged is \(which(staged)), backup \(backupPresent ? "present" : "absent")"
        }
        func outcome(_ result: EngineResult) throws -> (outcome: RecoveryOutcome, leftovers: [String]) {
            switch result.outcome {
            case .installedVerified: return (.completed, result.leftovers)
            case .restoredVerified: return (.reverted, result.leftovers)
            case .unresolved: throw result.refusal ?? InstallRefusal.unresolved(describe())
            }
        }

        switch (target, staged) {
        case (old, new):
            // Never swapped.
            restoreSuperseded(journal)
            return (.discarded, try settle(&journal, then: nil))
        case (old, nil):
            // Swapped back (or never swapped) and the staged copy is already gone.
            try verifyOld(journal.targetPath, journal)
            restoreSuperseded(journal)
            return (.reverted, try settle(&journal, then: .reverted))
        case (new, old):
            if journal.phase == .swapBack {
                return try outcome(try swapBack(&journal, because: .journal("the journal recorded a failed verification")))
            }
            return try outcome(try finishAfterSwap(&journal))
        case (new, nil):
            guard journal.phase == .backingUp || journal.phase == .backedUp, try backupEvidence(journal) else {
                throw InstallRefusal.recoveryAmbiguous(describe() + "; the old version is not in staging or backups")
            }
            return try outcome(try finish(&journal))
        default:
            throw InstallRefusal.recoveryAmbiguous(describe())
        }
    }
}
