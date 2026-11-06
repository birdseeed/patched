import Foundation
import Darwin

/// Test seam for `UserCatalogue.setIgnored`: observes each step in order, can fail a named step, and runs code between
/// the read and the commit (so a test can race a second edit or a manual change). Production uses the defaults.
@_spi(Testing) public struct CatalogueEditHooks: Sendable {
    public var event: @Sendable (String) -> Void = { _ in }
    public var fail: @Sendable (String) -> Bool = { _ in false }
    public var afterRead: @Sendable () -> Void = {}
    /// The permission bits of the new file straight after it is created, before anything is written.
    public var tempMode: @Sendable (Int) -> Void = { _ in }
    public init() {}
}

extension UserCatalogue {
    /// What an ignore edit did.
    public enum IgnoreEdit: Sendable, Equatable { case added, removed, unchanged }

    /// Adds (`ignored`) or removes the catalogue's ignore entry for one bundle ID, and nothing else.
    ///
    /// The whole read, change and write is one step under an exclusive lock on `catalogue.json.lock` beside the file
    /// (a second edit is refused while it is held). Everything is done relative to one held descriptor of the parent
    /// folder, which must be a real folder owned by the user, never a symlink. The file must parse strictly, else the
    /// edit is refused and the file left alone. Just before committing it is read again, and if it is no longer exactly
    /// what was parsed (a manual edit, say) the edit is refused too. Every other entry is carried over unchanged, and
    /// an app that has a `source` entry is never touched. The result goes to a new 0600 file renamed over the
    /// catalogue, and the folder is synced after the rename.
    @discardableResult
    public static func setIgnored(_ ignored: Bool, bundleID: String, at url: URL) throws -> IgnoreEdit {
        try setIgnored(ignored, bundleID: bundleID, at: url, hooks: CatalogueEditHooks())
    }

    @_spi(Testing) @discardableResult
    public static func setIgnored(_ ignored: Bool, bundleID: String, at url: URL, hooks: CatalogueEditHooks) throws -> IgnoreEdit {
        guard !bundleID.isEmpty else { throw CatalogueError(message: "an app without a bundle ID cannot be ignored") }
        let parent = url.deletingLastPathComponent().path, name = url.lastPathComponent
        var probe = stat()
        if lstat(parent, &probe) != 0 {
            guard errno == ENOENT else { throw CatalogueError(message: "\(parent): cannot be inspected") }
            if !ignored { return .unchanged }
            do { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw CatalogueError(message: "\(parent): could not be created") }
        }
        let dirfd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirfd >= 0 else { throw CatalogueError(message: "\(parent) is not a plain folder (a symlink is refused)") }
        defer { close(dirfd) }
        var held = stat()
        guard fstat(dirfd, &held) == 0, held.st_mode & S_IFMT == S_IFDIR, held.st_uid == getuid() else {
            throw CatalogueError(message: "\(parent) is not a folder owned by you")
        }
        func sameFolder() -> Bool {
            var now = stat(), named = stat()
            return fstat(dirfd, &now) == 0 && lstat(parent, &named) == 0
                && now.st_dev == held.st_dev && now.st_ino == held.st_ino && named.st_dev == held.st_dev && named.st_ino == held.st_ino
        }

        // The lock: a stable sidecar file, held from before the read until after the rename.
        let lockName = name + ".lock"
        let lockfd = openat(dirfd, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockfd >= 0 else { throw CatalogueError(message: "\(parent): could not open \(lockName)") }
        defer { close(lockfd) }
        var lockInfo = stat()
        guard fstat(lockfd, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == getuid() else {
            throw CatalogueError(message: "\(lockName) is not a regular file of yours")
        }
        guard flock(lockfd, LOCK_EX | LOCK_NB) == 0 else {
            throw CatalogueError(message: "catalogue.json is being edited at the moment, so it was not changed. Try again")
        }
        defer { flock(lockfd, LOCK_UN) }
        hooks.event("lock")

        let existing = try readFile(dirfd: dirfd, name: name, shown: url.path)
        hooks.event("read")
        var apps: [[String: Any]] = []
        var version: Any = 1
        if let existing {
            let parsed: UserCatalogue
            do { parsed = try decode(existing) } catch let error as CatalogueError {
                throw CatalogueError(message: "\(url.path): \(error.message), so it was not changed")
            }
            switch parsed.entries[bundleID] {
            case .ignore?:
                if ignored { return .unchanged }
            case .source?:
                throw CatalogueError(message: "\(bundleID) has a source entry in catalogue.json; edit the file by hand")
            case nil:
                if !ignored { return .unchanged }
            }
            // `decode` accepted it, so these casts hold.
            let root = try JSONSerialization.jsonObject(with: existing) as? [String: Any] ?? [:]
            version = root["version"] ?? 1
            apps = (root["apps"] as? [[String: Any]]) ?? []
        } else if !ignored { return .unchanged }

        if ignored { apps.append(["bundleID": bundleID, "ignore": true]) }
        else { apps.removeAll { ($0["bundleID"] as? String) == bundleID } }
        let output = try JSONSerialization.data(withJSONObject: ["version": version, "apps": apps] as [String: Any],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // What is about to be written must itself load, and mean exactly one entry more or fewer.
        guard try decode(output).entries[bundleID] == (ignored ? .ignore : nil) else {
            throw CatalogueError(message: "internal error: the edited catalogue did not read back, so nothing was written")
        }
        hooks.afterRead()

        // Commit only if the folder and the file are still what was read.
        guard sameFolder() else { throw CatalogueError(message: "\(parent) changed while catalogue.json was being edited, so it was not changed") }
        let again = try readFile(dirfd: dirfd, name: name, shown: url.path)
        hooks.event("reread")
        guard again == existing else {
            throw CatalogueError(message: "catalogue.json changed while it was being edited, so it was not changed. Try again")
        }

        let temporary = ".catalogue-\(UUID().uuidString).tmp"
        let fd = openat(dirfd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CatalogueError(message: "\(parent): could not write a new catalogue.json") }
        hooks.event("create")
        var created = stat()
        if fstat(fd, &created) == 0 { hooks.tempMode(Int(created.st_mode & 0o777)) }
        var renamed = false
        defer { if !renamed { unlinkat(dirfd, temporary, 0); hooks.event("unlink") } }
        let wrote: Bool = !hooks.fail("write") && output.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
        hooks.event("write")
        let synced = wrote && !hooks.fail("fsync-file") && fsync(fd) == 0
        hooks.event("fsync-file")
        guard close(fd) == 0, synced else { throw CatalogueError(message: "\(parent): could not write a new catalogue.json") }
        guard sameFolder(), !hooks.fail("rename"), renameat(dirfd, temporary, dirfd, name) == 0 else {
            throw CatalogueError(message: "\(url.path): could not be replaced, so it was not changed")
        }
        renamed = true
        hooks.event("rename")
        guard !hooks.fail("fsync-dir"), fsync(dirfd) == 0 else {
            throw CatalogueError(message: "\(url.path) was replaced, but the folder could not be synced, so the change may not survive a power cut")
        }
        hooks.event("fsync-dir")
        return ignored ? .added : .removed
    }

    /// nil when the file does not exist. Never follows a symlink; the file must be a regular file of yours within the size cap.
    private static func readFile(dirfd: Int32, name: String, shown: String) throws -> Data? {
        let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw CatalogueError(message: "catalogue.json must be a regular file, not a symlink")
            default: throw CatalogueError(message: "\(shown): unreadable, so it was not changed")
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maxBytes else {
            throw CatalogueError(message: "\(shown): unreadable or larger than \(maxBytes) bytes, so it was not changed")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maxBytes - data.count + 1))
            if count < 0 { if errno == EINTR { continue }; throw CatalogueError(message: "\(shown): unreadable, so it was not changed") }
            if count == 0 { break }
            guard count <= maxBytes - data.count else { throw CatalogueError(message: "\(shown): larger than \(maxBytes) bytes, so it was not changed") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
