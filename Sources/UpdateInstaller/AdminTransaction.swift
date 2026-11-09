import Foundation
import Darwin
import UpdateSources

// The experimental admin path's transactions. Same verification as the ordinary path up to and
// including the staged bundle; then, instead of one rename of ours:
//   1. copy the installed app (as the user) into backups and verify the copy as the old app,
//   2. ask macOS (its own prompt) and replace the target with the verified staged bundle,
//   3. verify what is installed (signature, Team ID, bundle ID, version, Gatekeeper),
//   4. on failure put the verified copy back the same way, or stop and say how to do it by hand.
// Recovery never uses admin rights: it judges what is installed and only removes its own files.

extension SwapEngine {
    func privilegedStagingDir(id: String) -> String { locations.downloads + "/.mac-updater-" + id }

    /// Copies the installed app into `backupDir` as the current user, before anything privileged. The copy
    /// must verify as the old app (signature, Team ID, bundle ID, version) and is synced to disk. A same-
    /// version backup already there is set aside (pruned when this transaction finishes).
    func copyInstalledToBackup(_ journal: inout TransactionJournal) throws {
        guard let backupDir = journal.backupDir, let destination = journal.backupBundlePath else {
            throw InstallRefusal.journal("no backup folder chosen")
        }
        let appBackups = (backupDir as NSString).deletingLastPathComponent
        try FileSafety.makePrivateDirectory(appBackups)
        if FileSafety.exists(backupDir) {
            guard rename(backupDir, appBackups + "/.superseded-" + journal.id) == 0 else {
                throw InstallRefusal.io("cannot move aside existing backup \(backupDir)")
            }
        }
        try FileSafety.makePrivateDirectory(backupDir)
        let partial = backupDir + "/.partial-" + UUID().uuidString
        // Recorded before copying, so `recover` can remove a half-made copy.
        journal.backupCopyPartial = partial
        try write(&journal)
        var placed = false
        do {
            try Unpacker.copyBundle(journal.targetPath, to: partial)
            try verifyOld(partial, journal)
            try FileSafety.syncTree(partial)
            try FileSafety.syncDirectory(backupDir)
            guard !FileSafety.exists(destination), rename(partial, destination) == 0 else {
                throw InstallRefusal.io("cannot place the backup copy at \(destination)")
            }
            placed = true
            try FileSafety.syncDirectory(backupDir)
            try verifyOld(destination, journal)
        } catch {
            try? FileSafety.removeTree(partial, within: locations.backups)
            if placed { try? FileSafety.removeTree(destination, within: locations.backups) }
            rmdir(backupDir)
            journal.backupCopyPartial = nil
            try? write(&journal)
            throw error
        }
        journal.backupCopyIdentity = FileSafety.directoryIdentity(destination)
        journal.backupCopyPartial = nil
        try write(&journal)
        try hooks.atCheckpoint("admin.backup.copied")
    }

    /// Is this transaction's verified backup copy still in place?
    func verifiedBackupCopy(_ journal: TransactionJournal) -> String? {
        guard let copy = journal.backupCopyIdentity, let destination = journal.backupBundlePath,
              FileSafety.directoryIdentity(destination) == copy, (try? verifyOld(destination, journal)) != nil else { return nil }
        return destination
    }

    /// Removes this transaction's own backup copy (half-made or placed). Nothing else is touched.
    func discardBackupCopy(_ journal: inout TransactionJournal) {
        if let partial = journal.backupCopyPartial { try? FileSafety.removeTree(partial, within: locations.backups) }
        if let copy = journal.backupCopyIdentity, let destination = journal.backupBundlePath,
           FileSafety.directoryIdentity(destination) == copy {
            try? FileSafety.removeTree(destination, within: locations.backups)
        }
        if let backupDir = journal.backupDir { rmdir(backupDir) } // only if now empty
        journal.backupCopyPartial = nil
        journal.backupCopyIdentity = nil
    }

    /// What to tell the user when the app is left neither verified-new nor verified-old.
    func manualRestoreAdvice(_ journal: TransactionJournal) -> String {
        let folder = (journal.targetPath as NSString).deletingLastPathComponent
        if let backup = verifiedBackupCopy(journal) {
            return "The previous version is kept at \(backup). To put it back by hand, drag it into \(folder) in Finder and choose Replace (macOS asks for an administrator's password), then run `patched recover`."
        }
        return "No verified copy of the previous version is available; reinstall \(journal.targetName) from its developer, then run `patched recover`."
    }

    /// Final step on the admin path: the installed app verifies again; the verified copy of the old version
    /// gets its `backup.json` (older backups are then pruned). With no verified copy, older backups are kept.
    func privilegedFinish(_ journal: inout TransactionJournal) throws -> EngineResult {
        do { try verifyInstalled(journal) } catch let refusal as InstallRefusal {
            return EngineResult(outcome: .unresolved, refusal: .unresolved(
                "installed app failed verification (\(refusal.message)). " + manualRestoreAdvice(journal)))
        }
        if verifiedBackupCopy(journal) != nil {
            try writeBackupRecord(journal)
        } else {
            discardBackupCopy(&journal)
            journal.backupDir = nil
        }
        let left = try settle(&journal, then: .finished)
        return EngineResult(outcome: .installedVerified, refusal: nil, leftovers: left)
    }

    enum PackageVerdict {
        /// The app is exactly the old version and still verifies as it, and Installer is not running.
        case untouched
        /// The offered version, strictly newer, same Team ID, accepted by Gatekeeper.
        case installed(BundleFacts)
        /// Installer changed the app into something that fails those checks.
        case unverified(InstallRefusal)
        /// Cannot tell yet (Installer still running, or the old app no longer verifies as itself).
        case undecided(String)
    }

    /// What Apple's Installer left at the target, judged against the offer recorded in the journal. Shared by
    /// the uninterrupted run and `recover`, so an interruption can never relax a check.
    func judgePackage(_ journal: TransactionJournal) -> PackageVerdict {
        guard let offer = journal.offer?.updateOffer else { return .undecided("the journal does not record the offered version") }
        let target = journal.targetPath
        let old = BundleFacts(bundleID: journal.bundleID, shortVersion: journal.oldShortVersion, build: journal.oldBuild, sparklePublicEDKey: nil)
        let now = try? BundleFacts.read(bundleAt: target)
        let verdict: PackageVerdict
        if let now, now.bundleID == old.bundleID, now.shortVersion == old.shortVersion, now.build == old.build {
            // Same Info.plist values are not proof: the old app must still verify as itself.
            verdict = (try? verifyOld(target, journal)) != nil ? .untouched
                : .undecided("\(target) still says \(InstallTarget.versionText(old.shortVersion, old.build)) but no longer verifies as that version (Installer may have changed part of it)")
        } else {
            do {
                try FileSafety.requireNoSymlinks(target)
                guard let now, FileSafety.directoryIdentity(target) != nil else {
                    throw InstallRefusal.bundleNotFound("\(target) is no longer a readable app")
                }
                guard now.bundleID == journal.bundleID else { throw InstallRefusal.signatureInvalid("\(target) now has bundle ID \(now.bundleID)") }
                try UpdateInstaller.checkVersions(staged: now, installed: old, offer: offer)
                try verifier.verifySignature(ofBundleAt: target, teamID: journal.teamID)
                try verifier.assessGatekeeper(ofBundleAt: target)
                // The offered version, fully verified (its signature covers every file): done, whatever
                // Installer's window still shows.
                return .installed(now)
            } catch let refusal as InstallRefusal {
                verdict = .unverified(refusal)
            } catch {
                verdict = .unverified(.io("\(error)"))
            }
        }
        // Anything short of a verified install is not final while Installer may still be changing the app.
        if installerRunning() {
            return .undecided("Apple's Installer is still running and may still change \(journal.targetName); finish or quit it, then run `patched recover`")
        }
        return verdict
    }

    /// Installer installed something that failed verification: keep the verified copy of the previous
    /// version with its record (marked as replaced by a package, so it is never rolled back automatically),
    /// clean up our own files, and say so.
    func keepCopyAfterInstaller(_ journal: inout TransactionJournal, because refusal: InstallRefusal) -> InstallRefusal {
        var kept: String?
        if verifiedBackupCopy(journal) != nil, (try? writeBackupRecord(journal)) != nil { kept = journal.backupDir }
        _ = try? settle(&journal, then: nil)
        return .installedUnverified(refusal.message + (kept.map { "; the previous version is kept in \($0), but Roll back isn't supported for installer packages, so reinstall the previous version from its developer if you need it" }
            ?? "; no copy of the previous version could be kept"))
    }

    /// Recovery for an admin-path journal, without admin rights. Before the target was handed to macOS
    /// (`staging`, `backingUp`) everything of ours is discarded. After that the installed app decides:
    /// verified new completes, verified old reverts, anything else is refused untouched with instructions.
    func recoverPrivileged(_ original: TransactionJournal) throws -> (outcome: RecoveryOutcome, leftovers: [String]) {
        var journal = original
        switch journal.phase {
        case .staging, .backingUp:
            discardBackupCopy(&journal)
            return (.discarded, try settle(&journal, then: nil))
        case .prepared, .swapped, .swapBack:
            if journal.viaInstaller == true {
                // Exactly the judgement of the uninterrupted run, against the offer recorded before Installer opened.
                switch judgePackage(journal) {
                case .untouched:
                    discardBackupCopy(&journal)
                    return (.reverted, try settle(&journal, then: .reverted))
                case .installed(let facts):
                    journal.newShortVersion = facts.shortVersion
                    journal.newBuild = facts.build
                    let result = try privilegedFinish(&journal)
                    guard result.outcome == .installedVerified else { throw result.refusal ?? InstallRefusal.unresolved(journal.id) }
                    return (.completed, result.leftovers)
                case .unverified(let refusal):
                    throw keepCopyAfterInstaller(&journal, because: refusal)
                case .undecided(let why):
                    throw InstallRefusal.recoveryAmbiguous("journal \(journal.id): \(why). Nothing was deleted. " + manualRestoreAdvice(journal))
                }
            }
            if (journal.newShortVersion != journal.oldShortVersion || journal.newBuild != journal.oldBuild),
               (try? verifyInstalled(journal)) != nil {
                let result = try privilegedFinish(&journal)
                guard result.outcome == .installedVerified else { throw result.refusal ?? InstallRefusal.unresolved(journal.id) }
                return (.completed, result.leftovers)
            }
            if (try? verifyOld(journal.targetPath, journal)) != nil {
                discardBackupCopy(&journal)
                return (.reverted, try settle(&journal, then: .reverted))
            }
            throw InstallRefusal.recoveryAmbiguous("journal \(journal.id) (\(journal.phase.rawValue)): \(journal.targetPath) verifies neither as the old nor as the new version, and recovery never uses admin rights. " + manualRestoreAdvice(journal))
        default:
            throw InstallRefusal.recoveryAmbiguous("journal \(journal.id) is in phase \(journal.phase.rawValue)")
        }
    }
}

extension UpdateInstaller {
    struct AdminConsent {
        let path: AdminUpdatePath
        let interaction: AdminInteraction
    }

    /// A part of the admin path is open only when its flag is on in this installer's `AdminUpdatePath`
    /// and the caller passed an `AdminInteraction` for this one action.
    func adminConsent(_ interaction: AdminInteraction?, packages: Bool) -> AdminConsent? {
        guard let adminPath, let interaction, packages ? adminPath.allowsPackages : adminPath.allowsReplacement else { return nil }
        return AdminConsent(path: adminPath, interaction: interaction)
    }

    func requireInteractive(_ consent: AdminConsent) throws {
        if let problem = consent.path.session.interactiveProblem() { throw InstallRefusal.needsInteractiveAdmin(problem) }
    }

    func privilegedJournal(_ kind: TransactionJournal.Kind, target: InstallTarget, format: ArtifactFormat?,
                           restoredFrom: String? = nil) -> TransactionJournal {
        let id = UUID().uuidString
        let now = TransactionJournal.now()
        var journal = TransactionJournal(
            id: id, kind: kind, phase: .staging, bundleID: target.facts.bundleID, teamID: target.teamID,
            targetPath: target.path, stagingDir: engine.privilegedStagingDir(id: id),
            downloadDir: kind == .update ? locations.downloads + "/" + id : nil,
            mountPoint: format == .dmg ? locations.downloads + "/" + id + "/mnt" : nil, restoredFrom: restoredFrom,
            oldIdentity: target.identity, oldShortVersion: target.facts.shortVersion, oldBuild: target.facts.build,
            backupDir: backupFolder(for: target), createdAt: now, updatedAt: now)
        journal.privileged = true
        return journal
    }

    /// Fresh private staging folder, which must be on the target's volume so macOS moves rather than copies.
    func makePrivilegedStaging(_ journal: TransactionJournal, target: InstallTarget) throws {
        try FileSafety.makeFreshPrivateDirectory(journal.stagingDir)
        guard FileSafety.directoryIdentity(journal.stagingDir)?.device == target.identity.device else {
            throw InstallRefusal.unsafePath("the staging folder \(journal.stagingDir) is not on the same volume as \(target.path)")
        }
    }

    func relaunchIfStillOld(_ wasRunning: Bool, _ target: InstallTarget, _ journal: TransactionJournal) async {
        if wasRunning, (try? engine.verifyOld(target.path, journal)) != nil { await runningApps.relaunch(path: target.path) }
    }

    func ownerOf(_ path: String) -> UInt32? { FileSafety.lstatInfo(path).map { UInt32($0.st_uid) } }

    // MARK: Root-owned (or otherwise not user-replaceable) apps from zip and dmg

    func privilegedUpdate(_ target: InstallTarget, offer: UpdateOffer, options: UpdateOptions,
                          consent: AdminConsent) async throws -> InstallReport {
        if !options.dryRun { try requireInteractive(consent) }
        let lock = try begin(target)
        defer { withExtendedLifetime(lock) {} }
        if !options.dryRun && !options.quitIfRunning { _ = try await ensureNotRunning(target, quit: false) }
        return try await cleaningUp(privilegedJournal(.update, target: target, format: offer.format)) { journal in
            try engine.write(&journal)
            try FileSafety.makeFreshPrivateDirectory(journal.downloadDir!)
            try makePrivilegedStaging(journal, target: target)
            let artifact = try await download(offer, into: journal.downloadDir!)
            try SparkleSignature.check(publicKey: target.facts.sparklePublicEDKey, signature: offer.edSignature,
                                       archivePath: artifact.path)
            let staged = try stageAndVerify(artifact: artifact.path, format: offer.format, target: target, offer: offer,
                                            stagingDir: journal.stagingDir, mountPoint: journal.mountPoint)
            if options.dryRun {
                let left = try engine.settle(&journal, then: nil)
                if !left.isEmpty {
                    throw InstallRefusal.cleanupIncomplete("dry run passed, but left behind: " + left.joined(separator: ", "))
                }
                return InstallReport(status: .dryRunPassed, bundleID: target.facts.bundleID, path: target.path,
                                     fromVersion: target.versionText,
                                     toVersion: InstallTarget.versionText(staged.shortVersion, staged.build),
                                     backupFolder: nil, relaunched: false, privileged: true)
            }
            journal.newIdentity = FileSafety.directoryIdentity(journal.stagedBundlePath)
            journal.newShortVersion = staged.shortVersion
            journal.newBuild = staged.build
            try FileSafety.removeTree(journal.downloadDir!, within: locations.downloads)
            return try await privilegedCommit(&journal, target: target, staged: staged, status: .installed,
                                              quit: options.quitIfRunning, consent: consent)
        }
    }

    func privilegedRollback(_ target: InstallTarget, quitIfRunning: Bool, consent: AdminConsent) async throws -> InstallReport {
        try requireInteractive(consent)
        let lock = try begin(target)
        defer { withExtendedLifetime(lock) {} }
        let (backup, backupBundle, backupFolder) = try rollbackSource(for: target)
        return try await cleaningUp(privilegedJournal(.rollback, target: target, format: nil, restoredFrom: backupFolder)) { journal in
            try engine.write(&journal)
            try makePrivilegedStaging(journal, target: target)
            try FileSafety.requireContainedSymlinks(backupBundle)
            try Unpacker.copyBundle(backupBundle, to: journal.stagedBundlePath)
            let staged = try verifyStaged(journal.stagedBundlePath, target: target, offer: nil)
            journal.newIdentity = FileSafety.directoryIdentity(journal.stagedBundlePath)
            guard staged.shortVersion == backup.shortVersion, staged.build == backup.build else {
                throw InstallRefusal.versionMismatch("backup bundle is \(staged.shortVersion ?? "?"), metadata says \(backup.shortVersion ?? "?")")
            }
            journal.newShortVersion = staged.shortVersion
            journal.newBuild = staged.build
            return try await privilegedCommit(&journal, target: target, staged: staged, status: .rolledBack,
                                              quit: quitIfRunning, consent: consent)
        }
    }

    /// From a verified staged bundle to a verified result, using admin rights only for the replacement
    /// itself (and, if the result fails its checks, for putting the verified backup copy back).
    func privilegedCommit(_ journal: inout TransactionJournal, target: InstallTarget, staged: BundleFacts,
                          status: InstallReport.Status, quit: Bool, consent: AdminConsent) async throws -> InstallReport {
        let wasRunning = try await ensureNotRunning(target, quit: quit)
        let session: any PrivilegedReplacementSession
        do {
            // 1. Backup first, as the user. Nothing privileged has happened yet.
            journal.phase = .backingUp
            try engine.write(&journal)
            try engine.copyInstalledToBackup(&journal)
            guard journal.oldIdentity == FileSafety.directoryIdentity(target.path),
                  journal.newIdentity == FileSafety.directoryIdentity(journal.stagedBundlePath) else {
                throw InstallRefusal.io("the installed or staged bundle changed while the update was being prepared")
            }
            journal.phase = .prepared
            try engine.write(&journal)
            // 2. Only now, with everything verified, ask macOS.
            session = try await consent.path.replacer.authorize()
            // Last look, immediately before the replacement.
            try engine.runningCheck(target.facts.bundleID, [target.path])
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            // The target was never handed to macOS: drop our copy and let the caller clean up.
            engine.discardBackupCopy(&journal)
            journal.phase = .staging
            await relaunchIfStillOld(wasRunning, target, journal)
            throw error
        }
        var replaceError: InstallRefusal?
        do {
            try await session.replaceItem(at: target.path, withItemAt: journal.stagedBundlePath)
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            let refusal = error as? InstallRefusal ?? .privilegedReplaceFailed("\(error)")
            if (try? engine.verifyOld(target.path, journal)) != nil {
                // Nothing changed at the target.
                engine.discardBackupCopy(&journal)
                journal.phase = .staging
                await relaunchIfStillOld(wasRunning, target, journal)
                throw refusal
            }
            replaceError = refusal
        }
        journal.phase = .swapped
        journal.installedOwner = ownerOf(target.path)
        try engine.write(&journal)
        // 3. Verify what is installed now.
        do {
            if let replaceError { throw replaceError }
            try engine.verifyInstalled(journal)
        } catch let refusal as InstallRefusal {
            return try await privilegedRestore(&journal, target: target, session: session, because: refusal, wasRunning: wasRunning)
        }
        // 4. Record the backup, prune older ones, clean up.
        let result = try engine.privilegedFinish(&journal)
        guard result.outcome == .installedVerified else { throw result.refusal ?? InstallRefusal.unresolved("journal \(journal.id)") }
        if wasRunning { await runningApps.relaunch(path: target.path) }
        return InstallReport(status: status, bundleID: target.facts.bundleID, path: target.path,
                             fromVersion: target.versionText,
                             toVersion: InstallTarget.versionText(staged.shortVersion, staged.build),
                             backupFolder: journal.backupDir, relaunched: wasRunning, leftovers: result.leftovers,
                             privileged: true, installedOwner: journal.installedOwner,
                             note: "installed with admin rights; the app is now owned by uid \(journal.installedOwner.map(String.init) ?? "?")")
    }

    /// The new app failed its checks after the replacement: put the verified copy of the old app back
    /// with the same session (no second prompt). Throws `verificationFailedAfterSwap` when the old app is
    /// back and verified, otherwise `unresolved` with instructions; the journal then stays for `recover`.
    func privilegedRestore(_ journal: inout TransactionJournal, target: InstallTarget, session: any PrivilegedReplacementSession,
                           because reason: InstallRefusal, wasRunning: Bool) async throws -> InstallReport {
        journal.phase = .swapBack
        try engine.write(&journal)
        func unresolved(_ why: String) -> InstallRefusal {
            .unresolved("the new app failed verification (\(reason.message)) and \(why). " + engine.manualRestoreAdvice(journal))
        }
        guard let backup = engine.verifiedBackupCopy(journal) else { throw unresolved("no verified copy of the old app is available") }
        let restoreDir = journal.stagingDir + "/restore"
        let restore = restoreDir + "/" + journal.targetName
        do {
            if FileSafety.pathState(restoreDir) != .absent { try FileSafety.removeTree(restoreDir, within: journal.stagingDir) }
            try FileSafety.makeFreshPrivateDirectory(restoreDir)
            try Unpacker.copyBundle(backup, to: restore)
            try engine.verifyOld(restore, journal)
            try engine.runningCheck(journal.bundleID, [target.path])
        } catch let refusal as InstallRefusal {
            throw unresolved("the copy to put back could not be prepared (\(refusal.message))")
        }
        do {
            try await session.replaceItem(at: target.path, withItemAt: restore)
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            throw unresolved("putting the old app back failed (\((error as? InstallRefusal)?.message ?? "\(error)"))")
        }
        do { try engine.verifyOld(target.path, journal) } catch let refusal as InstallRefusal {
            throw unresolved("the restored app failed verification (\(refusal.message))")
        }
        // The old version is installed again, so its copy in backups is no longer a backup.
        engine.discardBackupCopy(&journal)
        let left = try engine.settle(&journal, then: .reverted)
        await relaunchIfStillOld(wasRunning, target, journal)
        let leftNote = left.isEmpty ? "" : "; could not remove: " + left.joined(separator: ", ")
        throw InstallRefusal.verificationFailedAfterSwap(reason.message + leftNote)
    }

    // MARK: Installer packages (.pkg)

    /// Verifies the package (hash, size, EdDSA, flat format, Developer ID Installer Team ID, notarisation),
    /// keeps a copy of the installed app when it can, then hands the package to Apple's Installer and
    /// waits for the user. Afterwards the installed app must verify like any other update.
    func packageUpdate(_ target: InstallTarget, offer: UpdateOffer, options: UpdateOptions,
                       consent: AdminConsent) async throws -> InstallReport {
        if !options.dryRun { try requireInteractive(consent) }
        let lock = try begin(target)
        defer { withExtendedLifetime(lock) {} }
        if !options.dryRun && !options.quitIfRunning { _ = try await ensureNotRunning(target, quit: false) }
        var initial = privilegedJournal(.update, target: target, format: .pkg)
        initial.viaInstaller = true
        initial.offer = StoredOffer(offer)
        return try await cleaningUp(initial) { journal in
            try engine.write(&journal)
            try FileSafety.makeFreshPrivateDirectory(journal.downloadDir!)
            try makePrivilegedStaging(journal, target: target)
            let artifact = try await download(offer, into: journal.downloadDir!)
            try SparkleSignature.check(publicKey: target.facts.sparklePublicEDKey, signature: offer.edSignature,
                                       archivePath: artifact.path)
            // The bytes about to be checked are made read-only, and checked again just before Installer opens.
            guard chmod(artifact.path, 0o400) == 0 else { throw InstallRefusal.io("cannot make the package read-only") }
            try consent.path.packages.verifyPackage(at: artifact.path, teamID: target.teamID)
            let offered = InstallTarget.versionText(offer.displayVersion, offer.buildVersion)
            if options.dryRun {
                let left = try engine.settle(&journal, then: nil)
                if !left.isEmpty {
                    throw InstallRefusal.cleanupIncomplete("dry run passed, but left behind: " + left.joined(separator: ", "))
                }
                return InstallReport(status: .dryRunPassed, bundleID: target.facts.bundleID, path: target.path,
                                     fromVersion: target.versionText, toVersion: offered, backupFolder: nil,
                                     relaunched: false, privileged: true)
            }
            let wasRunning = try await ensureNotRunning(target, quit: options.quitIfRunning)
            var backupProblem: String?
            do {
                journal.phase = .backingUp
                try engine.write(&journal)
                do {
                    try engine.copyInstalledToBackup(&journal)
                } catch let crash as SimulatedCrash {
                    throw crash
                } catch {
                    // A pkg update cannot be undone without this copy, but it is not a reason to refuse.
                    backupProblem = (error as? InstallRefusal)?.message ?? "\(error)"
                    engine.discardBackupCopy(&journal)
                }
                guard (try? PackageFile.sha256Hex(artifact.path)) == artifact.sha256Hex else {
                    throw InstallRefusal.hashMismatch("the package changed after it was verified")
                }
                try engine.runningCheck(target.facts.bundleID, [target.path])
                journal.phase = .prepared
                try engine.write(&journal)
                try consent.path.opener.openInstaller(forPackageAt: artifact.path)
            } catch let crash as SimulatedCrash {
                throw crash
            } catch {
                engine.discardBackupCopy(&journal)
                journal.phase = .staging
                await relaunchIfStillOld(wasRunning, target, journal)
                throw error
            }
            consent.interaction.installerOpened(
                "Apple's Installer has opened for \(target.name) \(offered). Finish the installation there; Patched waits, then checks what was installed.")
            let waited = await consent.path.waiter.waitForInstaller(appAt: target.path, installed: target.facts,
                                                                    interaction: consent.interaction)
            let now: BundleFacts
            switch engine.judgePackage(journal) {
            case .untouched:
                // The old app verifies fully as itself and Installer has quit: nothing happened.
                engine.discardBackupCopy(&journal)
                journal.phase = .staging
                await relaunchIfStillOld(wasRunning, target, journal)
                throw InstallRefusal.installerNotFinished(waited == .timedOut
                    ? "\(target.name) did not change before the wait ran out; if you finish later, check again"
                    : "\(target.name) has not changed; if Installer is still open, finish there and check again")
            case .undecided(let why):
                // Installer may still be working, or it changed part of the app. Keep the copy of the
                // previous version, the package and the journal; `recover` decides once it can.
                throw InstallRefusal.unresolved(why + ". " + engine.manualRestoreAdvice(journal))
            case .unverified(let refusal):
                // Apple's Installer has already changed the app; there is nothing else of ours to undo.
                throw engine.keepCopyAfterInstaller(&journal, because: refusal)
            case .installed(let facts):
                now = facts
                journal.newShortVersion = facts.shortVersion
                journal.newBuild = facts.build
            }
            journal.newIdentity = FileSafety.directoryIdentity(target.path)
            journal.installedOwner = ownerOf(target.path)
            let result = try engine.privilegedFinish(&journal)
            guard result.outcome == .installedVerified else { throw result.refusal ?? InstallRefusal.unresolved("journal \(journal.id)") }
            if wasRunning { await runningApps.relaunch(path: target.path) }
            return InstallReport(status: .installed, bundleID: target.facts.bundleID, path: target.path,
                                 fromVersion: target.versionText,
                                 toVersion: InstallTarget.versionText(now.shortVersion, now.build),
                                 backupFolder: journal.backupDir, relaunched: wasRunning, leftovers: result.leftovers,
                                 privileged: true, installedOwner: journal.installedOwner,
                                 note: "installed by Apple's Installer" + (backupProblem.map { "; no backup could be kept (\($0)), so it cannot be rolled back" } ?? ""))
        }
    }
}
