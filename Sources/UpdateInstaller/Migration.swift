import Foundation
import Darwin

/// A retained shared lease prevents another process migrating a legacy selection while its
/// installer is still alive, including time before it takes a per-app lock.
final class MigrationLease: @unchecked Sendable {
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// A resumable rename, never a copy/delete. The marker is durable before either root moves;
/// its inode pins distinguish our interrupted rename from an unrelated existing destination.
enum LegacyStateMigration {
    struct Move: Codable {
        let old: String
        let new: String
        let identity: FileSafety.Identity
    }
    struct Marker: Codable {
        let version: Int
        let moves: [Move]
        var done: Bool? = nil
    }

    static func locations(home: String, checkpoint: (String) throws -> Void) throws -> InstallerLocations {
        guard FileSafety.lexicallyNormalised(home) == home else { throw InstallRefusal.unsafePath("home is not normalised") }
        try FileSafety.requireNoSymlinks(home)
        let supportParent = home + "/Library/Application Support"
        let oldSupport = supportParent + "/mac-updater", newSupport = supportParent + "/Patched/Updater"
        let oldCache = home + "/Library/Caches/mac-updater", newCache = home + "/Library/Caches/Patched/Updater"
        func locations(_ support: String, _ cache: String) -> InstallerLocations {
            InstallerLocations(downloads: cache + "/downloads", transactions: support + "/transactions", backups: support + "/backups")
        }
        let legacy = locations(FileSafety.pathState(oldSupport) == .absent ? newSupport : oldSupport,
                               FileSafety.pathState(oldCache) == .absent ? newCache : oldCache)
        let current = locations(newSupport, newCache)
        let markerPath = supportParent + "/.patched-state-migration.json"
        let expectedPairs = [(oldSupport, newSupport), (oldCache, newCache)]
        // No previous state: normal startup must not create or change the user's Library folders.
        if FileSafety.pathState(markerPath) == .absent && FileSafety.pathState(oldSupport) == .absent
            && FileSafety.pathState(oldCache) == .absent { return current }
        // Migration finished and no legacy folders have reappeared: the migrated folders are
        // authoritative, so return them without taking the exclusive admission lock. Otherwise a
        // running app (which holds a shared lease) or a scheduled check would make every later
        // command fail as if a migration were in progress.
        if FileSafety.pathState(oldSupport) == .absent && FileSafety.pathState(oldCache) == .absent,
           let info = FileSafety.lstatInfo(markerPath), FileSafety.isRegular(info), info.st_uid == geteuid(),
           let data = FileSafety.readSmallFile(markerPath, limit: 64 * 1024),
           let saved = try? JSONDecoder().decode(Marker.self, from: data), saved.version == 1, saved.done == true {
            return current
        }
        if FileSafety.pathState(supportParent) == .absent { try FileSafety.makePrivateDirectory(supportParent) }
        try FileSafety.requireNoSymlinks(supportParent)
        let lockPath = supportParent + "/.patched-state-migration.lock"
        let lock = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw InstallRefusal.io("cannot open state migration lock") }
        defer { flock(lock, LOCK_UN); close(lock) }
        try requireRegularLock(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw InstallRefusal.io("another command is using legacy state or migrating it; close that command before running patched recover") }
        // A separate lease file avoids flock's non-atomic EX-to-SH conversion. The
        // admission lock remains exclusive until a shared lease is safely established.
        let leasePath = supportParent + "/.patched-state-migration.lease"
        let leaseGate = open(leasePath, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard leaseGate >= 0 else { throw InstallRefusal.io("cannot open state migration lease") }
        defer { flock(leaseGate, LOCK_UN); close(leaseGate) }
        try requireRegularLock(leaseGate)
        guard flock(leaseGate, LOCK_EX | LOCK_NB) == 0 else {
            throw InstallRefusal.io("another command is using legacy state; close it before retrying migration")
        }
        let savedMarker: Marker?
        if FileSafety.pathState(markerPath) != .absent {
            guard let info = FileSafety.lstatInfo(markerPath), FileSafety.isRegular(info), info.st_uid == geteuid(),
                  let data = FileSafety.readSmallFile(markerPath, limit: 64 * 1024),
                  let saved = try? JSONDecoder().decode(Marker.self, from: data), saved.version == 1,
                  !saved.moves.isEmpty, saved.moves.count <= 2,
                  Set(saved.moves.map(\.old)).count == saved.moves.count,
                  saved.moves.allSatisfy({ move in expectedPairs.contains { $0.0 == move.old && $0.1 == move.new } }) else {
                throw InstallRefusal.journal("unreadable state migration marker; preserve both folders and inspect or repair the marker manually")
            }
            if saved.done == true {
                if FileSafety.pathState(oldSupport) != .absent || FileSafety.pathState(oldCache) != .absent {
                    // The migrated state is authoritative; an odd recreated legacy folder (symlink,
                    // foreign owner, unreadable) must not stop the tool, only be reported.
                    let hasState = (try? legacyHasRecoveryState(oldSupport)) ?? true
                    if hasState {
                        return blocked(current, "migration already completed; recreated legacy state was left untouched. Recover it with the old binary or manually merge it; Patched is using the migrated folders")
                    }
                    warn("migration already completed; ignoring recreated legacy folders without journals or backups")
                    return current
                }
                return current
            }
            savedMarker = saved
        } else { savedMarker = nil }
        // Honour existing per-app locks before inspecting journals or moving their directory.
        // Keep the descriptors alive through every rename and metadata rewrite.
        var appLocks: [Int32] = []
        defer { for fd in appLocks { flock(fd, LOCK_UN); close(fd) } }
        for support in [oldSupport, newSupport] {
            let directory = support + "/transactions"
            if FileSafety.pathState(directory) == .absent { continue }
            try requireOwnedDirectory(directory)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory) where name.hasSuffix(".lock") {
                let path = directory + "/" + name
                try FileSafety.requireNoSymlinks(path)
                let fd = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw InstallRefusal.io("cannot open legacy app lock") }
                do { try requireRegularLock(fd) } catch { close(fd); throw error }
                if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                    close(fd)
                    throw InstallRefusal.io("an installer is running; retry Patched state migration after it finishes")
                }
                appLocks.append(fd)
            }
        }
        func keepSelected(_ selected: InstallerLocations, _ message: String) throws -> InstallerLocations {
            let shared = open(leasePath, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard shared >= 0 else { throw InstallRefusal.io("cannot open retained migration lease") }
            do { try requireRegularLock(shared) } catch { close(shared); throw error }
            // Other compliant selectors cannot enter while `lock` remains exclusive.
            // A second open description cannot share-lock against our exclusive gate.
            flock(leaseGate, LOCK_UN)
            guard flock(shared, LOCK_SH | LOCK_NB) == 0 else {
                close(shared)
                throw InstallRefusal.io("cannot retain state migration lease")
            }
            var result = blocked(selected, message)
            result.migrationLease = MigrationLease(shared)
            return result
        }
        func keepLegacy(_ message: String) throws -> InstallerLocations {
            try keepSelected(legacy, message)
        }
        let marker: Marker
        if let saved = savedMarker {
            marker = saved
        } else {
            var moves: [Move] = []
            for (old, new) in expectedPairs {
                switch FileSafety.pathState(old) {
                case .absent: continue
                case .unknown: throw InstallRefusal.io("cannot inspect legacy state at \(old)")
                case .present: break
                }
                // A pre-existing destination is never merged or replaced. Keep using the old
                // pair if only one destination exists, rather than split a live journal's roots.
                if FileSafety.pathState(new) != .absent {
                    return try keepLegacy("both legacy and Patched Updater folders exist; keeping legacy state. Quit Patched and close other updater commands, then resolve the folder conflict manually; no folders were merged")
                }
                try requireOwnedDirectory(old)
                let destinationParent = (new as NSString).deletingLastPathComponent
                let existingParent = FileSafety.pathState(destinationParent) == .absent
                    ? (destinationParent as NSString).deletingLastPathComponent : destinationParent
                try requireOwnedDirectory(existingParent)
                guard let identity = FileSafety.directoryIdentity(old),
                      let parent = FileSafety.directoryIdentity(existingParent),
                      identity.device == parent.device else { throw InstallRefusal.unsafePath("state migration requires a same-volume rename") }
                moves.append(Move(old: old, new: new, identity: identity))
            }
            do { _ = try metadata(support: legacy.supportRoot) }
            catch {
                return try keepLegacy("legacy state was left in place: \(error). \(recoveryAdvice(error))")
            }
            if moves.isEmpty { return current }
            for move in moves {
                let parent = (move.new as NSString).deletingLastPathComponent
                if FileSafety.pathState(parent) == .absent {
                    try FileSafety.makePrivateDirectory(parent)
                    try FileSafety.syncDirectory((parent as NSString).deletingLastPathComponent)
                }
            }
            marker = Marker(version: 1, moves: moves)
            try FileSafety.writeAtomically(try JSONEncoder().encode(marker), to: markerPath)
            try checkpoint("marker-written")
        }
        // The marker proves intent and identities, not that a legacy executable has stayed
        // idle since it was written. Revalidate every root and current metadata before any
        // additional rename, including on a marker-only resume.
        var hasMovedRoot = false
        for move in marker.moves {
            if FileSafety.pathState(move.old) == .absent {
                try requireOwnedDirectory(move.new)
                guard FileSafety.directoryIdentity(move.new) == move.identity else { throw InstallRefusal.unsafePath("migration destination identity changed: \(move.new)") }
                hasMovedRoot = true
            } else {
                try requireOwnedDirectory(move.old)
                guard FileSafety.directoryIdentity(move.old) == move.identity,
                      FileSafety.pathState(move.new) == .absent else { throw InstallRefusal.unsafePath("migration folders changed; preserving both") }
            }
        }
        let supportToInspect = FileSafety.pathState(oldSupport) == .absent ? newSupport : oldSupport
        do { _ = try metadata(support: supportToInspect) }
        catch {
            if !hasMovedRoot {
                // Retain the marker for after recovery; no path or metadata has changed yet.
                return try keepLegacy("legacy state was left in place: \(error). \(recoveryAdvice(error))")
            }
            let moved = marker.moves.filter { FileSafety.pathState($0.old) == .absent }
            let selected = locations(supportToInspect, FileSafety.pathState(oldCache) == .absent ? newCache : oldCache)
            // Repair only prefixes whose roots already moved. Keep an unmoved cache in
            // place so recovery's strict journal path checks still describe real files.
            try rewriteMetadata(support: supportToInspect, moves: moved, allowUnfinished: true,
                                tolerateUnreadable: true, checkpoint: checkpoint)
            return try keepSelected(selected, "state migration is partially renamed: \(error). Using updater support at \(selected.supportRoot) and cache at \((selected.downloads as NSString).deletingLastPathComponent). \(recoveryAdvice(error)) Then retry to finish migration")
        }
        for move in marker.moves {
            if FileSafety.pathState(move.old) == .absent {
                try requireOwnedDirectory(move.new)
                guard FileSafety.directoryIdentity(move.new) == move.identity else { throw InstallRefusal.unsafePath("migration destination identity changed: \(move.new)") }
            } else {
                try requireOwnedDirectory(move.old)
                guard FileSafety.directoryIdentity(move.old) == move.identity,
                      FileSafety.pathState(move.new) == .absent else { throw InstallRefusal.unsafePath("migration folders changed; preserving both") }
                guard renamex_np(move.old, move.new, UInt32(RENAME_EXCL)) == 0 else { throw InstallRefusal.io("cannot rename legacy state: \(String(cString: strerror(errno)))") }
                try FileSafety.syncDirectory((move.new as NSString).deletingLastPathComponent)
                try FileSafety.syncDirectory((move.old as NSString).deletingLastPathComponent)
                try checkpoint("root-renamed")
            }
        }
        // Re-read every file on resume: writes are atomic and substitutions are idempotent,
        // including a crash halfway through updating the journal and backup metadata.
        try rewriteMetadata(support: newSupport, moves: marker.moves, checkpoint: checkpoint)
        var completed = marker
        completed.done = true
        try FileSafety.writeAtomically(try JSONEncoder().encode(completed), to: markerPath)
        try checkpoint("migration-completed")
        return current
    }

    static func rewriteMetadata(support: String, moves: [Move], allowUnfinished: Bool = false,
                                tolerateUnreadable: Bool = false, checkpoint: (String) throws -> Void) throws {
        for (path, data) in try metadata(support: support, allowUnfinished: allowUnfinished, tolerateUnreadable: tolerateUnreadable) {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InstallRefusal.journal("invalid metadata at \(path)") }
            var rewritten = json
            let keys: Set<String> = path.hasSuffix("/backup.json") ? ["originalPath"] :
                ["targetPath", "stagingDir", "downloadDir", "mountPoint", "restoredFrom", "backupDir", "backupCopyPartial"]
            func moved(_ value: String) -> String {
                for move in moves where value == move.old || value.hasPrefix(move.old + "/") {
                    // Normalisation is essential: old/../elsewhere must never become a new path.
                    if FileSafety.lexicallyNormalised(value) == value { return move.new + value.dropFirst(move.old.count) }
                }
                return value
            }
            for key in keys { if let value = json[key] as? String { rewritten[key] = moved(value) } }
            if let paths = json["cleanupPending"] as? [String] { rewritten["cleanupPending"] = paths.map(moved) }
            try FileSafety.writeAtomically(try JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: path)
            try checkpoint("metadata-written")
        }
    }

    static func recoveryAdvice(_ error: Error) -> String {
        if String(describing: error).contains("backup metadata") {
            return "Quit Patched and close other updater commands, then inspect and repair the backup metadata manually; patched recover cannot repair it."
        }
        return "Quit Patched and close other updater commands, then run patched recover for unfinished journals; inspect unreadable journals manually."
    }

    static func legacyHasRecoveryState(_ support: String) throws -> Bool {
        if FileSafety.pathState(support) == .absent { return false }
        try requireOwnedDirectory(support)
        for name in ["transactions", "backups"] {
            let path = support + "/" + name
            if FileSafety.pathState(path) == .absent { continue }
            try requireOwnedDirectory(path)
            let entries = try FileManager.default.contentsOfDirectory(atPath: path)
            if entries.contains(where: { name == "backups" || !$0.hasSuffix(".lock") }) { return true }
        }
        return false
    }

    static func requireRegularLock(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, FileSafety.isRegular(info), info.st_uid == geteuid(), info.st_nlink == 1 else {
            throw InstallRefusal.unsafePath("migration lock must be an owned regular file")
        }
    }

    static func requireOwnedDirectory(_ path: String) throws {
        try FileSafety.requireNoSymlinks(path)
        guard let info = FileSafety.lstatInfo(path), FileSafety.isDirectory(info), info.st_uid == geteuid() else {
            throw InstallRefusal.unsafePath("state directory is not owned by the current user: \(path)")
        }
    }

    /// Enumerate only installer metadata, never the contents of a backed-up application bundle.
    static func metadata(support: String, allowUnfinished: Bool = false, tolerateUnreadable: Bool = false) throws -> [(String, Data)] {
        if FileSafety.pathState(support) == .absent { return [] }
        try requireOwnedDirectory(support)
        var result: [(String, Data)] = []
        func children(_ path: String) throws -> [String] {
            if FileSafety.pathState(path) == .absent { return [] }
            try requireOwnedDirectory(path)
            return try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        }
        let transactions = support + "/transactions"
        for name in try children(transactions) where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = transactions + "/" + name
            try FileSafety.requireNoSymlinks(path)
            guard let data = FileSafety.readSmallFile(path, limit: 1024 * 1024),
                  let journal = try? JSONDecoder().decode(TransactionJournal.self, from: data),
                  journal.id + ".json" == name,
                  allowUnfinished || (journal.isTerminal && journal.cleanupPending?.isEmpty != false) else {
                if tolerateUnreadable { continue }
                throw InstallRefusal.journal("unfinished, cleanup-pending or unreadable journal: \(name)")
            }
            result.append((path, data))
        }
        let backups = support + "/backups"
        for app in try children(backups) where !app.hasPrefix(".") {
            for version in try children(backups + "/" + app) where !version.hasPrefix(".") {
                let folder = backups + "/" + app + "/" + version
                try requireOwnedDirectory(folder)
                let path = folder + "/backup.json"
                try FileSafety.requireNoSymlinks(path)
                guard let data = FileSafety.readSmallFile(path, limit: 64 * 1024),
                      (try? JSONDecoder().decode(BackupRecord.self, from: data)) != nil else {
                    if tolerateUnreadable { continue }
                    throw InstallRefusal.journal("unreadable backup metadata: \(path)")
                }
                result.append((path, data))
            }
        }
        return result
    }

    static func blocked(_ legacy: InstallerLocations, _ message: String) -> InstallerLocations {
        warn(message)
        return InstallerLocations(downloads: legacy.downloads, transactions: legacy.transactions,
                                  backups: legacy.backups, migrationNotice: message)
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data(("Patched: " + message + "\n").utf8))
    }
}
