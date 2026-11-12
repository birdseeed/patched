import Foundation
import Darwin
import UpdateSources

/// The offer a `.pkg` journal was opened for, recorded before Apple's Installer is opened, so `recover`
/// judges what Installer left behind against the same offer as the uninterrupted run.
public struct StoredOffer: Codable, Sendable, Equatable {
    public let displayVersion: String
    public let buildVersion: String?
    /// `sparkle`, `electron` or `homebrew`, with the feed URL or cask token: the version rules depend on it.
    public let sourceKind: String
    public let sourceLocator: String
    public let downloadURL: String

    public init(_ offer: UpdateOffer) {
        displayVersion = offer.displayVersion; buildVersion = offer.buildVersion
        sourceKind = offer.source.kind; sourceLocator = offer.source.locator
        downloadURL = offer.downloadURL.absoluteString
    }

    /// The offer again, or nil when the record does not describe one.
    public var updateOffer: UpdateOffer? {
        guard let url = URL(string: downloadURL) else { return nil }
        let source: UpdateSource
        switch sourceKind {
        case "sparkle": guard let feed = URL(string: sourceLocator) else { return nil }; source = .sparkle(feed: feed)
        case "electron": guard let feed = URL(string: sourceLocator) else { return nil }; source = .electron(feed: feed)
        case "homebrew": source = .homebrewCask(token: sourceLocator)
        default: return nil
        }
        return UpdateOffer(displayVersion: displayVersion, buildVersion: buildVersion, downloadURL: url, format: .pkg, source: source)
    }
}

/// One install or rollback, written to disk before every state change so `recover` can finish or undo it.
public struct TransactionJournal: Codable, Sendable, Equatable {
    /// `freshInstall`: Self Service installing a catalogue app that is not installed yet. There is no old app and no
    /// backup; `targetPath` is the destination in ~/Applications, and `newIdentity` is the copy Patched moved there.
    public enum Kind: String, Codable, Sendable { case update, rollback, freshInstall }
    /// `staging`: downloading/unpacking/verifying, nothing in the target folder changed yet.
    /// `prepared`: verified bundle staged, about to swap. `swapped`: swap done, re-verifying.
    /// `swapBack`: re-verification failed, about to swap the old bundle back.
    /// `backingUp`: verified, moving the old bundle into the backups folder.
    /// `backedUp`: the old bundle is durably in the backups folder; final verification and cleanup remain.
    /// `cleanupPending`: the outcome is settled but temporary files or a mount could not be removed;
    /// `cleanupPending` lists them and `cleanupThen` is the phase to record once they are gone (nil: delete).
    /// `finished` and `reverted` are terminal and kept as a record.
    public enum Phase: String, Codable, Sendable { case staging, prepared, swapped, swapBack, backingUp, backedUp, cleanupPending, finished, reverted }

    public var id: String
    public var kind: Kind
    public var phase: Phase
    public var bundleID: String
    public var teamID: String
    public var targetPath: String
    public var stagingDir: String
    public var downloadDir: String?
    public var mountPoint: String?
    /// For rollbacks: the backup folder being restored.
    public var restoredFrom: String?
    public var oldIdentity: FileSafety.Identity?
    public var newIdentity: FileSafety.Identity?
    public var oldShortVersion: String?
    public var oldBuild: String?
    public var newShortVersion: String?
    public var newBuild: String?
    /// Folder that receives the outgoing bundle: `backups/<bundleID>/<version>-<build>`.
    public var backupDir: String?
    /// Set only after a cross-volume backup copy was verified and synced: the copy's identity.
    public var backupCopyIdentity: FileSafety.Identity?
    /// Where that verified, synced copy sits before it is renamed into place (`backupDir/.partial-<uuid>`).
    public var backupCopyPartial: String?
    public var cleanupPending: [String]?
    public var cleanupThen: Phase?
    /// Experimental admin path: the target is replaced through macOS's own admin prompt, never by a rename
    /// of ours. Staging then lives in the downloads folder (`downloads/.mac-updater-<id>`), the old app is
    /// copied into backups before anything privileged happens, and `recover` never uses admin rights: it
    /// only judges what is installed and cleans up its own files. Absent (nil) for every ordinary journal.
    public var privileged: Bool?
    /// Admin path for a `.pkg`: Apple's Installer, not Patched, changes the app.
    public var viaInstaller: Bool?
    /// For a `.pkg`: the offer, written before Installer opens (the bundle ID and Team ID are above).
    public var offer: StoredOffer?
    /// Owner (uid) of the installed bundle after a privileged replacement, as recorded for the report.
    public var installedOwner: UInt32?
    /// Fresh installs only: the Self Service folder (~/Applications) the install was started in. Recovery refuses a
    /// journal whose target is not directly inside it, or whose folder is not this user's Self Service folder.
    public var destinationRoot: String?
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, kind: Kind, phase: Phase, bundleID: String, teamID: String, targetPath: String,
                stagingDir: String, downloadDir: String? = nil, mountPoint: String? = nil, restoredFrom: String? = nil,
                oldIdentity: FileSafety.Identity? = nil, newIdentity: FileSafety.Identity? = nil,
                oldShortVersion: String? = nil, oldBuild: String? = nil, newShortVersion: String? = nil,
                newBuild: String? = nil, backupDir: String? = nil, createdAt: String, updatedAt: String) {
        self.id = id; self.kind = kind; self.phase = phase; self.bundleID = bundleID; self.teamID = teamID
        self.targetPath = targetPath; self.stagingDir = stagingDir; self.downloadDir = downloadDir
        self.mountPoint = mountPoint; self.restoredFrom = restoredFrom; self.oldIdentity = oldIdentity
        self.newIdentity = newIdentity; self.oldShortVersion = oldShortVersion; self.oldBuild = oldBuild
        self.newShortVersion = newShortVersion; self.newBuild = newBuild; self.backupDir = backupDir
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var targetName: String { (targetPath as NSString).lastPathComponent }
    public var stagedBundlePath: String { stagingDir + "/" + targetName }
    public var backupBundlePath: String? { backupDir.map { $0 + "/" + targetName } }
    public var isTerminal: Bool { phase == .finished || phase == .reverted }
    public var isPrivileged: Bool { privileged == true }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}

/// Test fault injection: called after each journal write; throwing `SimulatedCrash` stops the run dead.
public struct TransactionHooks: Sendable {
    public var afterJournalWrite: @Sendable (TransactionJournal.Phase) throws -> Void
    /// Named points between journal writes (for example `backup.renamed`), for crash injection.
    public var atCheckpoint: @Sendable (String) throws -> Void
    public init(afterJournalWrite: @escaping @Sendable (TransactionJournal.Phase) throws -> Void = { _ in },
                atCheckpoint: @escaping @Sendable (String) throws -> Void = { _ in }) {
        self.afterJournalWrite = afterJournalWrite
        self.atCheckpoint = atCheckpoint
    }
    public static let none = TransactionHooks()
}

/// Journal files: `transactions/<id>.json`, 0600, written atomically with fsync, in a 0700 folder.
public struct JournalStore: Sendable {
    public let directory: String
    public init(directory: String) { self.directory = directory }

    func path(for id: String) -> String { directory + "/" + id + ".json" }

    public func write(_ journal: inout TransactionJournal) throws {
        journal.updatedAt = TransactionJournal.now()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(journal) } catch { throw InstallRefusal.journal("encode failed: \(error)") }
        try FileSafety.writeAtomically(data, to: path(for: journal.id))
    }

    public func delete(_ id: String) {
        unlink(path(for: id))
        let dirFD = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dirFD >= 0 { fsync(dirFD); close(dirFD) }
    }

    /// Every journal, oldest first. Unreadable files are reported, never ignored silently.
    public func all() -> (journals: [TransactionJournal], unreadable: [String]) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter {
            $0.hasSuffix(".json") && !$0.hasPrefix(".")
        }
        var journals: [TransactionJournal] = [], unreadable: [String] = []
        for name in names.sorted() {
            guard let data = FileSafety.readSmallFile(directory + "/" + name, limit: 1024 * 1024),
                  let journal = try? JSONDecoder().decode(TransactionJournal.self, from: data),
                  journal.id + ".json" == name else {
                unreadable.append(name); continue
            }
            journals.append(journal)
        }
        return (journals.sorted { $0.createdAt < $1.createdAt }, unreadable)
    }

    public func unfinished() -> [TransactionJournal] { all().journals.filter { !$0.isTerminal } }
}

/// An exclusive, non-blocking per-app lock (`transactions/<bundleID>.lock`) so two runs never touch the same app.
public final class AppLock: @unchecked Sendable {
    private let fd: Int32
    public init(directory: String, bundleID: String) throws {
        guard BundleFacts.isSafeBundleID(bundleID) else { throw InstallRefusal.unsafePath("bundle ID \(bundleID)") }
        let path = directory + "/" + bundleID + ".lock"
        fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstallRefusal.io("cannot open lock \(path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw InstallRefusal.busy(bundleID)
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
