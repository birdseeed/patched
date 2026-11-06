import Foundation
import Darwin
import UpdateInstaller

func registerMigrationChecks() {
    check("migration preserves backup rollback paths, exact prefixes, permissions and idempotence") {
        let box = try Sandbox()
        let home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        let cache = home + "/Library/Caches/mac-updater"
        let new = home + "/Library/Application Support/Patched/Updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(cache + "/downloads")
        let backup = old + "/backups/" + bundleID + "/1-1"
        try FileSafety.makePrivateDirectory(backup)
        let target = try makeApp(at: box.apps + "/Example.app", short: "2.0", build: "2")
        try makeApp(at: backup + "/Example.app", short: "1.0", build: "1")
        var journal = TransactionJournal(id: "done", kind: .update, phase: .finished, bundleID: bundleID, teamID: teamA,
            targetPath: target, stagingDir: box.apps + "/.mac-updater-staging", downloadDir: cache + "/downloads/done",
            restoredFrom: old + "-other/backups", backupDir: backup, createdAt: "2026-11-05", updatedAt: "2026-11-05")
        journal.backupCopyPartial = backup + "/.partial"
        try JournalStore(directory: old + "/transactions").write(&journal)
        let record: [String: String] = ["bundleID": bundleID, "teamID": teamA, "appName": "Example.app", "shortVersion": "1.0", "build": "1", "originalPath": target, "createdAt": "2026-11-05"]
        try FileSafety.writeAtomically(JSONSerialization.data(withJSONObject: record), to: backup + "/backup.json")
        let selected = try InstallerLocations.standard(home: home)
        try expectEqual(selected.supportRoot, new)
        try expectEqual(FileSafety.mode(home + "/Library/Application Support/Patched"), 0o700)
        try expectEqual(FileSafety.mode(home + "/Library/Caches/Patched"), 0o700)
        try expect(!FileSafety.exists(old) && !FileSafety.exists(cache), "legacy roots remain after rename")
        let moved = JournalStore(directory: selected.transactions).all().journals.first!
        try expectEqual(moved.targetPath, target)
        try expectEqual(moved.stagingDir, journal.stagingDir)
        try expectEqual(moved.downloadDir, home + "/Library/Caches/Patched/Updater/downloads/done")
        try expectEqual(moved.restoredFrom, journal.restoredFrom, "prefix boundary changed")
        try expectEqual(moved.backupDir, new + "/backups/" + bundleID + "/1-1")
        try expectEqual(FileSafety.mode(selected.transactions + "/done.json"), 0o600)
        try expectEqual(try InstallerLocations.standard(home: home), selected)
        let updater = UpdateInstaller(locations: selected, verifier: FakeVerifier(), runningApps: FakeRunningApps(), teamIDReader: fakeTeamReader)
        let listed = updater.backups(bundleID: bundleID)
        try expectEqual(listed.count, 1)
        try expect(FileSafety.exists(listed[0].bundlePath!), "rollback bundle path did not resolve")
        let report = try await updater.rollback(appAt: target)
        try expectEqual(report.status, .rolledBack)
        try expectEqual(try BundleFacts.read(bundleAt: target).shortVersion, "1.0")
    }

    check("after migration, a held shared lease (running app) never blocks later commands") {
        let box = try Sandbox(), home = box.root + "/home"
        try FileSafety.makePrivateDirectory(home + "/Library/Application Support/mac-updater/transactions")
        try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
        let first = try InstallerLocations.standard(home: home)
        // Stand in for the open app: hold the lease file shared and the admission lock exclusive.
        let parent = home + "/Library/Application Support"
        let lease = open(parent + "/.patched-state-migration.lease", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        let admission = open(parent + "/.patched-state-migration.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { close(lease); close(admission) }
        guard lease >= 0, admission >= 0, flock(lease, LOCK_SH | LOCK_NB) == 0, flock(admission, LOCK_EX | LOCK_NB) == 0 else {
            throw CheckFailure(description: "fixture could not take the locks")
        }
        let later = try InstallerLocations.standard(home: home)
        try expectEqual(later, first, "a finished migration must return the migrated folders without locking")
    }

    check("migration preserves existing Patched siblings and parent permissions") {
        let box = try Sandbox(), home = box.root + "/home"
        let patched = home + "/Library/Application Support/Patched"
        let patchedCache = home + "/Library/Caches/Patched"
        for root in [patched, patchedCache] {
            try FileSafety.makePrivateDirectory(root + "/Activity")
            try FileSafety.makePrivateDirectory(root + "/PrivateBackups")
            try FileSafety.writeAtomically(Data("preferences".utf8), to: root + "/preferences.json")
            guard chmod(root, 0o750) == 0 else { throw CheckFailure(description: "fixture chmod failed") }
        }
        try FileSafety.makePrivateDirectory(home + "/Library/Application Support/mac-updater/transactions")
        try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
        let selected = try InstallerLocations.standard(home: home)
        try expectEqual(selected.supportRoot, patched + "/Updater")
        for root in [patched, patchedCache] {
            try expect(FileSafety.exists(root + "/Activity") && FileSafety.exists(root + "/PrivateBackups"), "Patched sibling folders changed")
            try expectEqual(FileSafety.readSmallFile(root + "/preferences.json"), Data("preferences".utf8))
            try expectEqual(FileSafety.mode(root), 0o750, "existing Patched parent mode changed")
        }
    }
    check("completed migration never merges recreated legacy journals") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        let migrated = try InstallerLocations.standard(home: home)
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.writeAtomically(Data("legacy-journal".utf8), to: old + "/transactions/late.json")
        let selected = try InstallerLocations.standard(home: home)
        try expectEqual(selected.supportRoot, migrated.supportRoot)
        try expect(selected.migrationNotice?.contains("old binary") == true, "old-state recovery instructions missing")
        try expectEqual(FileSafety.readSmallFile(old + "/transactions/late.json"), Data("legacy-journal".utf8))
        try expect(!FileSafety.exists(selected.transactions + "/late.json"), "recreated journal was merged")
    }
    check("completed migration never merges recreated legacy backups without journals") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        let migrated = try InstallerLocations.standard(home: home)
        let backup = old + "/backups/" + bundleID + "/1-1"
        try FileSafety.makePrivateDirectory(backup)
        try FileSafety.writeAtomically(Data("legacy-backup".utf8), to: backup + "/backup.json")
        let selected = try InstallerLocations.standard(home: home)
        try expectEqual(selected.supportRoot, migrated.supportRoot)
        try expect(selected.migrationNotice?.contains("old binary") == true, "backup-only legacy state recovery instructions missing")
        try expectEqual(FileSafety.readSmallFile(backup + "/backup.json"), Data("legacy-backup".utf8))
        try expect(!FileSafety.exists(selected.backups + "/" + bundleID + "/1-1"), "recreated backup was merged")
    }
    check("unmarked legacy and Updater conflict requires manual resolution") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        let current = home + "/Library/Application Support/Patched/Updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(current + "/transactions")
        try FileSafety.writeAtomically(Data("legacy".utf8), to: old + "/legacy.txt")
        try FileSafety.writeAtomically(Data("current".utf8), to: current + "/current.txt")
        let selected = try InstallerLocations.standard(home: home)
        try expectEqual(selected.supportRoot, old)
        try expect(selected.migrationNotice?.contains("resolve the folder conflict manually") == true, "manual conflict instruction missing")
        try expect(selected.migrationNotice?.contains("patched recover") == false, "conflict incorrectly presented as recoverable")
        try expectEqual(FileSafety.readSmallFile(old + "/legacy.txt"), Data("legacy".utf8))
        try expectEqual(FileSafety.readSmallFile(current + "/current.txt"), Data("current".utf8))
        try expect(!FileSafety.exists(home + "/Library/Application Support/.patched-state-migration.json"), "conflict created a migration marker")
    }
    for phase in [TransactionJournal.Phase.staging, .cleanupPending] {
        check("migration keeps legacy roots for \(phase.rawValue) journal") {
            let box = try Sandbox(), home = box.root + "/home"
            let old = home + "/Library/Application Support/mac-updater"
            try FileSafety.makePrivateDirectory(old + "/transactions")
            try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
            var journal = TransactionJournal(id: "pending", kind: .update, phase: phase, bundleID: bundleID, teamID: teamA,
                targetPath: box.apps + "/Example.app", stagingDir: box.apps + "/.mac-updater-staging", createdAt: "x", updatedAt: "x")
            try JournalStore(directory: old + "/transactions").write(&journal)
            let selected = try InstallerLocations.standard(home: home)
            try expectEqual(selected.supportRoot, old)
            try expect(!FileSafety.exists(home + "/Library/Application Support/Patched/Updater"), "blocked state renamed")
        }
    }
    check("unreadable legacy journal refuses migration without hiding recovery state") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
        try FileSafety.writeAtomically(Data("broken".utf8), to: old + "/transactions/broken.json")
        try expectEqual(try InstallerLocations.standard(home: home).supportRoot, old)
        try expectEqual(JournalStore(directory: old + "/transactions").all().unreadable, ["broken.json"])
    }
    for interruption in ["marker-written", "root-renamed", "metadata-written"] {
        check("migration resumes interruption at \(interruption)") {
            let box = try Sandbox(), home = box.root + "/home"
            let old = home + "/Library/Application Support/mac-updater"
            try FileSafety.makePrivateDirectory(old + "/transactions")
            try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
            for id in ["first", "second"] {
                var journal = TransactionJournal(id: id, kind: .update, phase: .reverted, bundleID: bundleID, teamID: teamA,
                    targetPath: box.apps + "/Example.app", stagingDir: old + "/staging/" + id,
                    createdAt: "x", updatedAt: "x")
                try JournalStore(directory: old + "/transactions").write(&journal)
            }
            do {
                _ = try InstallerLocations.standard(home: home, migrationCheckpoint: { point in
                    if point == interruption { throw SimulatedCrash(phase: point) }
                })
                throw CheckFailure(description: "expected simulated crash")
            } catch is SimulatedCrash { }
            let selected = try InstallerLocations.standard(home: home)
            let records = JournalStore(directory: selected.transactions).all().journals
            try expectEqual(records.count, 2)
            try expect(records.allSatisfy { $0.stagingDir.hasPrefix(selected.supportRoot + "/staging/") }, "partly rewritten paths remain")
            try expectEqual(try InstallerLocations.standard(home: home), selected)
            let done = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: home + "/Library/Application Support/.patched-state-migration.json"))) as! [String: Any]
            try expectEqual(done["done"] as? Bool, true, "durable completion marker missing")
        }
    }
    for lateState in ["staging", "cleanupPending", "unreadable"] {
        check("marker-only resume preserves legacy recovery for late \(lateState) journal") {
            let box = try Sandbox(), home = box.root + "/home"
            let old = home + "/Library/Application Support/mac-updater"
            let cache = home + "/Library/Caches/mac-updater"
            let marker = home + "/Library/Application Support/.patched-state-migration.json"
            try FileSafety.makePrivateDirectory(old + "/transactions")
            try FileSafety.makePrivateDirectory(cache + "/downloads")
            do {
                _ = try InstallerLocations.standard(home: home, migrationCheckpoint: { point in
                    if point == "marker-written" { throw SimulatedCrash(phase: point) }
                })
                throw CheckFailure(description: "expected marker interruption")
            } catch is SimulatedCrash { }
            let journalPath = old + "/transactions/late.json"
            if lateState == "unreadable" {
                try FileSafety.writeAtomically(Data("broken".utf8), to: journalPath)
            } else {
                var journal = TransactionJournal(id: "late", kind: .update,
                    phase: lateState == "staging" ? .staging : .cleanupPending, bundleID: bundleID, teamID: teamA,
                    targetPath: box.apps + "/Example.app", stagingDir: box.apps + "/.mac-updater-late",
                    downloadDir: cache + "/downloads/late", createdAt: "x", updatedAt: "x")
                if lateState == "cleanupPending" { journal.cleanupThen = .reverted }
                try JournalStore(directory: old + "/transactions").write(&journal)
            }
            var selected: InstallerLocations? = try InstallerLocations.standard(home: home)
            try expectEqual(selected?.supportRoot, old)
            try expect(selected?.migrationNotice?.contains("patched recover") == true, "missing recovery notice")
            try expect(FileSafety.exists(marker), "resumable marker was discarded")
            try expect(FileSafety.exists(old) && FileSafety.exists(cache), "legacy roots moved before recovery")
            try expect(!FileSafety.exists(home + "/Library/Application Support/Patched/Updater"), "new support root exposed")
            let outcome = await UpdateInstaller(locations: selected!, verifier: FakeVerifier(), runningApps: FakeRunningApps(), teamIDReader: fakeTeamReader).recover()
            if lateState == "unreadable" {
                try expectEqual(outcome.unreadable, ["late.json"])
                try expect(FileSafety.exists(journalPath), "unreadable journal was discarded")
                // An unreadable journal requires inspection; remove only this synthetic fixture.
                try FileManager.default.removeItem(atPath: journalPath)
            } else {
                try expectEqual(outcome.reports.count, 1)
                if case .failure(let error) = outcome.reports[0].result { throw error }
                try expectEqual(outcome.unreadable, [])
            }
            selected = nil
            let migrated = try InstallerLocations.standard(home: home)
            try expectEqual(migrated.supportRoot, home + "/Library/Application Support/Patched/Updater")
            let done = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: marker))) as! [String: Any]
            try expectEqual(done["done"] as? Bool, true, "migration did not finish after recovery")
        }
    }
    check("partial resume selects moved support and existing cache for recover") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        let cache = home + "/Library/Caches/mac-updater"
        let moved = home + "/Library/Application Support/Patched/Updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(cache + "/downloads")
        do {
            _ = try InstallerLocations.standard(home: home, migrationCheckpoint: { point in
                if point == "root-renamed" { throw SimulatedCrash(phase: point) }
            })
            throw CheckFailure(description: "expected root interruption")
        } catch is SimulatedCrash { }
        var journal = TransactionJournal(id: "late", kind: .update, phase: .staging, bundleID: bundleID, teamID: teamA,
            targetPath: box.apps + "/Example.app", stagingDir: box.apps + "/.mac-updater-late",
            downloadDir: cache + "/downloads/late", createdAt: "x", updatedAt: "x")
        try FileSafety.makePrivateDirectory(journal.downloadDir!)
        try JournalStore(directory: moved + "/transactions").write(&journal)
        var selected: InstallerLocations? = try InstallerLocations.standard(home: home)
        try expectEqual(selected?.supportRoot, moved)
        try expectEqual(selected?.downloads, cache + "/downloads")
        try expect(selected?.migrationNotice?.contains("patched recover") == true, "missing partial recovery notice")
        try expect(FileSafety.exists(moved + "/transactions/late.json"), "late journal was lost before recovery")
        let recovery = await UpdateInstaller(locations: selected!, verifier: FakeVerifier(), runningApps: FakeRunningApps(), teamIDReader: fakeTeamReader).recover()
        try expectEqual(recovery.reports.count, 1)
        if case .failure(let error) = recovery.reports[0].result { throw error }
        try expect(!FileSafety.exists(journal.downloadDir!), "legacy cache cleanup was not recovered")
        try expect(FileSafety.exists(cache), "another root moved despite unfinished metadata")
        try expect(!FileSafety.exists(home + "/Library/Caches/Patched/Updater"), "cache destination exposed")
        if case .success(let outcome) = recovery.reports[0].result { try expectEqual(outcome, .discarded) }
        try expect(!FileSafety.exists(moved + "/transactions/late.json"), "successfully discarded journal was not retired")
        selected = nil
        let completed = try InstallerLocations.standard(home: home)
        try expectEqual(completed.downloads, home + "/Library/Caches/Patched/Updater/downloads")
        try expect(!FileSafety.exists(cache), "cache migration did not finish after recovery")
    }
    check("partial metadata recovery rewrites paths when both roots already moved") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        let cache = home + "/Library/Caches/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(cache + "/downloads/late")
        var renames = 0
        do {
            _ = try InstallerLocations.standard(home: home, migrationCheckpoint: { point in
                if point == "root-renamed" {
                    renames += 1
                    if renames == 2 { throw SimulatedCrash(phase: point) }
                }
            })
            throw CheckFailure(description: "expected second root interruption")
        } catch is SimulatedCrash { }
        let support = home + "/Library/Application Support/Patched/Updater"
        var journal = TransactionJournal(id: "late", kind: .update, phase: .staging, bundleID: bundleID, teamID: teamA,
            targetPath: box.apps + "/Example.app", stagingDir: box.apps + "/.mac-updater-late",
            downloadDir: cache + "/downloads/late", createdAt: "x", updatedAt: "x")
        try JournalStore(directory: support + "/transactions").write(&journal)
        var selected: InstallerLocations? = try InstallerLocations.standard(home: home)
        try expectEqual(selected?.supportRoot, support)
        try expectEqual(selected?.downloads, home + "/Library/Caches/Patched/Updater/downloads")
        try expectEqual(JournalStore(directory: selected!.transactions).all().journals[0].downloadDir, selected!.downloads + "/late")
        let recovery = await UpdateInstaller(locations: selected!, verifier: FakeVerifier(), runningApps: FakeRunningApps(), teamIDReader: fakeTeamReader).recover()
        try expectEqual(recovery.reports.count, 1)
        if case .failure(let error) = recovery.reports[0].result { throw error }
        selected = nil
        try expectEqual(try InstallerLocations.standard(home: home).migrationNotice, nil)
    }
    check("migration rewrites every persisted absolute path only within moved roots") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        let cache = home + "/Library/Caches/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(cache + "/downloads")
        let backup = old + "/backups/" + bundleID + "/1-1"
        try FileSafety.makePrivateDirectory(backup)
        var journal = TransactionJournal(id: "paths", kind: .rollback, phase: .finished, bundleID: bundleID, teamID: teamA,
            targetPath: old + "/target.app", stagingDir: old + "/../outside/staging", downloadDir: cache + "/downloads/file",
            mountPoint: cache + "/mount", restoredFrom: backup, backupDir: backup,
            createdAt: "x", updatedAt: "x")
        journal.backupCopyPartial = backup + "/.partial"
        try JournalStore(directory: old + "/transactions").write(&journal)
        let record = ["bundleID": bundleID, "teamID": teamA, "appName": "Example.app", "originalPath": old + "/target.app", "createdAt": "x"]
        try FileSafety.writeAtomically(JSONSerialization.data(withJSONObject: record), to: backup + "/backup.json")
        let selected = try InstallerLocations.standard(home: home)
        let moved = JournalStore(directory: selected.transactions).all().journals[0]
        try expectEqual(moved.targetPath, selected.supportRoot + "/target.app")
        try expectEqual(moved.stagingDir, journal.stagingDir)
        try expectEqual(moved.mountPoint, home + "/Library/Caches/Patched/Updater/mount")
        try expectEqual(moved.restoredFrom, selected.backups + "/" + bundleID + "/1-1")
        try expectEqual(moved.backupCopyPartial, moved.backupDir! + "/.partial")
        let data = FileSafety.readSmallFile(moved.backupDir! + "/backup.json")!
        let migrated = try JSONDecoder().decode(BackupRecord.self, from: data)
        try expectEqual(migrated.originalPath, moved.targetPath)
    }
    check("terminal journal with cleanup leftovers still keeps legacy state") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
        var journal = TransactionJournal(id: "pending", kind: .update, phase: .finished, bundleID: bundleID, teamID: teamA,
            targetPath: box.apps + "/Example.app", stagingDir: old + "/staging", createdAt: "x", updatedAt: "x")
        journal.cleanupPending = [old + "/staging"]
        try JournalStore(directory: old + "/transactions").write(&journal)
        let selected = try InstallerLocations.standard(home: home)
        try expectEqual(selected.supportRoot, old)
        try expect(selected.migrationNotice?.contains("patched recover") == true, "missing recovery notice")
    }
    check("cache-only migration completes durably and ignores empty recreated legacy state") {
        let box = try Sandbox(), home = box.root + "/home"
        let cache = home + "/Library/Caches/mac-updater"
        try FileSafety.makePrivateDirectory(cache + "/downloads")
        let selected = try InstallerLocations.standard(home: home)
        try expectEqual(selected.downloads, home + "/Library/Caches/Patched/Updater/downloads")
        try expect(!FileSafety.exists(cache), "legacy cache not renamed")
        let old = home + "/Library/Application Support/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(selected.supportRoot + "/transactions")
        let conflict = try InstallerLocations.standard(home: home)
        try expectEqual(conflict.supportRoot, selected.supportRoot)
        try expectEqual(conflict.migrationNotice, nil, "ignored empty legacy folder should only print a one-line notice")
    }
    check("retained legacy selection prevents migration before a later app lock") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
        try FileSafety.writeAtomically(Data("broken".utf8), to: old + "/transactions/broken.json")
        var selected: InstallerLocations? = try InstallerLocations.standard(home: home)
        try expect(selected?.migrationNotice != nil, "legacy selection was not retained")
        try FileManager.default.removeItem(atPath: old + "/transactions/broken.json")
        try await expectRefusal("io_error") { _ = try InstallerLocations.standard(home: home) }
        try expect(FileSafety.exists(old), "legacy selection was migrated while still in use")
        selected = nil
        try expectEqual(try InstallerLocations.standard(home: home).supportRoot, home + "/Library/Application Support/Patched/Updater")
    }
    check("unreadable backup metadata keeps old roots and recovery notice") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        let backup = old + "/backups/" + bundleID + "/1-1"
        try FileSafety.makePrivateDirectory(backup)
        try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
        try FileSafety.writeAtomically(Data("broken".utf8), to: backup + "/backup.json")
        let selected = try InstallerLocations.standard(home: home)
        try expectEqual(selected.supportRoot, old)
        try expect(selected.migrationNotice?.contains("repair the backup metadata manually") == true, "missing backup metadata warning")
    }
    check("held legacy app lock blocks migration") {
        let box = try Sandbox(), home = box.root + "/home"
        let old = home + "/Library/Application Support/mac-updater"
        try FileSafety.makePrivateDirectory(old + "/transactions")
        try FileSafety.makePrivateDirectory(home + "/Library/Caches/mac-updater/downloads")
        let lock = try AppLock(directory: old + "/transactions", bundleID: bundleID)
        try await expectRefusal("io_error") { _ = try InstallerLocations.standard(home: home) }
        withExtendedLifetime(lock) { }
        try expect(FileSafety.exists(old), "active state moved")
    }
}
