import Foundation
import Darwin

/// Low-level file checks. Everything here uses `lstat`, never follows symlinks, and fails closed.
public enum FileSafety {
    public struct Identity: Sendable, Equatable, Codable {
        public let device: UInt64
        public let inode: UInt64
    }

    static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }
    static func isDirectory(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFDIR }
    static func isSymlink(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFLNK }
    static func isRegular(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFREG }

    /// Device and inode of a real directory (not a symlink), or nil.
    public static func directoryIdentity(_ path: String) -> Identity? {
        guard let info = lstatInfo(path), isDirectory(info) else { return nil }
        return Identity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    public static func exists(_ path: String) -> Bool { lstatInfo(path) != nil }

    public enum PathState: Equatable, Sendable { case present, absent, unknown(Int32) }
    /// Whether a path exists, telling "not there" (ENOENT/ENOTDIR) apart from "cannot tell" (EACCES, EIO...).
    public static func pathState(_ path: String) -> PathState {
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        let code = errno
        return code == ENOENT || code == ENOTDIR ? .absent : .unknown(code)
    }

    /// Size in bytes of a path (not following symlinks), 0 if missing.
    public static func lstatInfoSize(_ path: String) -> Int64 { lstatInfo(path).map { Int64($0.st_size) } ?? 0 }

    /// Permission bits of a path (not following symlinks).
    public static func mode(_ path: String) -> mode_t? { lstatInfo(path).map { $0.st_mode & 0o7777 } }

    /// The path must be absolute, normalised, and no component (including the last) may be a symlink.
    public static func requireNoSymlinks(_ path: String) throws {
        guard path.hasPrefix("/") else { throw InstallRefusal.unsafePath("\(path) is not absolute") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }), lexicallyNormalised(path) == path else {
            throw InstallRefusal.unsafePath("\(path) is not a normalised path")
        }
        var current = ""
        for part in parts {
            current += "/" + part
            guard let info = lstatInfo(current) else { throw InstallRefusal.unsafePath("\(current) does not exist") }
            if isSymlink(info) { throw InstallRefusal.unsafePath("\(current) is a symlink") }
        }
    }

    /// Creates `path` (and missing parents) with mode 0700, refusing symlinks and directories owned by
    /// someone else. Existing directories are tightened to 0700 if this process owns them.
    public static func makePrivateDirectory(_ path: String, uid: uid_t = geteuid()) throws {
        guard path.hasPrefix("/") else { throw InstallRefusal.unsafePath("\(path) is not absolute") }
        var current = ""
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        for part in parts {
            current += "/" + part
            if let info = lstatInfo(current) {
                if isSymlink(info) {
                    // Above the user's home, system symlinks such as /tmp or /var are a fact of life;
                    // the private tree we create must never contain one. Callers pass resolved paths.
                    throw InstallRefusal.unsafePath("\(current) is a symlink")
                }
                guard isDirectory(info) else { throw InstallRefusal.unsafePath("\(current) is not a directory") }
                continue
            }
            guard mkdir(current, 0o700) == 0 || errno == EEXIST else {
                throw InstallRefusal.io("could not create \(current): \(String(cString: strerror(errno)))")
            }
        }
        guard let info = lstatInfo(path), isDirectory(info) else { throw InstallRefusal.unsafePath("\(path) is not a directory") }
        guard info.st_uid == uid else { throw InstallRefusal.unsafePath("\(path) is not owned by the current user") }
        if info.st_mode & 0o077 != 0 { guard chmod(path, 0o700) == 0 else { throw InstallRefusal.io("could not chmod \(path)") } }
    }

    /// Creates a new directory that must not already exist, mode 0700.
    public static func makeFreshPrivateDirectory(_ path: String) throws {
        guard mkdir(path, 0o700) == 0 else {
            throw InstallRefusal.io("could not create \(path): \(String(cString: strerror(errno)))")
        }
        guard let info = lstatInfo(path), isDirectory(info), info.st_uid == geteuid() else {
            throw InstallRefusal.unsafePath("\(path) is not a fresh private directory")
        }
    }

    /// Removes a file tree that must lie strictly inside `root`. Before deleting it requires: both paths
    /// lexically normalised, no symlink in any component of the path (from `/` down), and the same device
    /// as `root` (no mount in between). `FileManager.removeItem` then deletes without following symlinks
    /// inside the tree. A missing path is fine; anything else that does not check out is refused.
    public static func removeTree(_ path: String, within root: String) throws {
        guard lexicallyNormalised(path) == path, lexicallyNormalised(root) == root, path.hasPrefix(root + "/") else {
            throw InstallRefusal.unsafePath("refusing to delete \(path): not inside \(root)")
        }
        switch pathState(path) {
        case .absent: return
        case .unknown(let code):
            throw InstallRefusal.io("cannot tell whether \(path) exists: \(String(cString: strerror(code)))")
        case .present: break
        }
        try requireNoSymlinks(path)
        guard let here = lstatInfo(path), let base = lstatInfo(root), here.st_dev == base.st_dev else {
            throw InstallRefusal.unsafePath("refusing to delete \(path): on a different volume from \(root)")
        }
        // Make sure directories inside are writable by us so removal does not stop half way.
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in enumerator {
                let child = path + "/" + relative
                if let info = lstatInfo(child), isDirectory(info) {
                    guard info.st_dev == base.st_dev else {
                        throw InstallRefusal.unsafePath("refusing to delete \(path): \(child) is a mount point")
                    }
                    if info.st_uid == geteuid(), info.st_mode & 0o200 == 0 { chmod(child, mode_t(info.st_mode & 0o7777) | 0o700) }
                }
            }
        }
        do { try FileManager.default.removeItem(atPath: path) }
        catch { throw InstallRefusal.io("could not delete \(path): \(error.localizedDescription)") }
    }

    /// Makes a copied tree durable: fsync every regular file and directory (errors are fatal), then
    /// F_FULLFSYNC the root directory so the data reaches the medium, not just the drive cache.
    public static func syncTree(_ root: String) throws {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { throw InstallRefusal.io("cannot read \(root)") }
        for case let relative as String in enumerator {
            let path = root + "/" + relative
            guard let info = lstatInfo(path) else { throw InstallRefusal.io("cannot stat \(path)") }
            if isSymlink(info) { continue }
            guard isRegular(info) || isDirectory(info) else { continue }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isDirectory(info) ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw InstallRefusal.io("cannot open \(path) to sync it") }
            let synced = fsync(fd) == 0
            close(fd)
            guard synced else { throw InstallRefusal.io("fsync failed for \(path)") }
        }
        try fullSync(directory: root)
    }

    /// F_FULLFSYNC on a directory (falls back to fsync where the file system does not support it).
    public static func fullSync(directory: String) throws {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw InstallRefusal.io("cannot open \(directory) to sync it") }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 { throw InstallRefusal.io("sync failed for \(directory)") }
    }

    /// Bytes available to this user on the volume holding `path`.
    public static func freeBytes(_ path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Like `treeBytes`, but stops as soon as the total passes `maxBytes` or the count passes `maxEntries`,
    /// so a huge tree cannot make one scan take long.
    public static func boundedTreeScan(_ path: String, maxBytes: Int64, maxEntries: Int) -> (bytes: Int64, entries: Int) {
        guard let top = lstatInfo(path) else { return (0, 0) }
        var total = max(Int64(top.st_size), Int64(top.st_blocks) * 512), count = 0
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return (total, count) }
        while let relative = enumerator.nextObject() as? String {
            count += 1
            if let info = lstatInfo(path + "/" + relative) { total += max(Int64(info.st_size), Int64(info.st_blocks) * 512) }
            if count > maxEntries || total > maxBytes { break }
        }
        return (total, count)
    }

    /// Sum of logical (or allocated, if larger) bytes under `path`, never following symlinks. Missing paths count as zero.
    public static func treeBytes(_ path: String) -> Int64 {
        guard let top = lstatInfo(path) else { return 0 }
        var total = max(Int64(top.st_size), Int64(top.st_blocks) * 512)
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in enumerator {
                if let info = lstatInfo(path + "/" + relative) { total += max(Int64(info.st_size), Int64(info.st_blocks) * 512) }
            }
        }
        return total
    }

    /// Every entry in the tree must be owned by `uid` and no directory may be immutable, otherwise moving
    /// and later deleting the bundle would need admin rights.
    public static func requireTreeOwned(by uid: uid_t, _ root: String) throws {
        guard let rootInfo = lstatInfo(root) else { throw InstallRefusal.unsafePath("\(root) does not exist") }
        guard rootInfo.st_uid == uid else { throw InstallRefusal.needsAdmin("\(root) is owned by uid \(rootInfo.st_uid)") }
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { throw InstallRefusal.io("cannot read \(root)") }
        for case let relative as String in enumerator {
            let child = root + "/" + relative
            guard let info = lstatInfo(child) else { throw InstallRefusal.io("cannot stat \(child)") }
            if info.st_uid != uid { throw InstallRefusal.needsAdmin("\(child) is owned by uid \(info.st_uid)") }
            if info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 {
                throw InstallRefusal.needsAdmin("\(child) has an immutable or append-only flag")
            }
        }
    }

    /// No entry in the tree may carry an immutable or append-only flag. Used on the admin path, where
    /// ownership by someone else is expected but such flags would still stop a replacement half way.
    public static func requireNoImmutableFlags(_ root: String) throws {
        guard let rootInfo = lstatInfo(root) else { throw InstallRefusal.unsafePath("\(root) does not exist") }
        let blocked = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND | SF_RESTRICTED)
        if rootInfo.st_flags & blocked != 0 { throw InstallRefusal.needsAdmin("\(root) is protected by file flags") }
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { throw InstallRefusal.io("cannot read \(root)") }
        for case let relative as String in enumerator {
            let child = root + "/" + relative
            guard let info = lstatInfo(child) else { throw InstallRefusal.io("cannot stat \(child)") }
            if info.st_flags & blocked != 0 {
                throw InstallRefusal.needsAdmin("\(child) has an immutable, append-only or restricted flag")
            }
        }
    }

    /// Checks every symlink inside `root` stays inside it, lexically and after resolution. Absolute and
    /// dangling links are refused.
    public static func requireContainedSymlinks(_ root: String) throws {
        guard let realRoot = realPath(root) else { throw InstallRefusal.io("cannot resolve \(root)") }
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { throw InstallRefusal.io("cannot read \(root)") }
        for case let relative as String in enumerator {
            let link = root + "/" + relative
            guard let info = lstatInfo(link), isSymlink(info) else { continue }
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
                throw InstallRefusal.unsafeSymlink("\(relative) cannot be read")
            }
            if destination.hasPrefix("/") { throw InstallRefusal.unsafeSymlink("\(relative) -> \(destination) is absolute") }
            let lexical = lexicallyNormalised((link as NSString).deletingLastPathComponent + "/" + destination)
            guard lexical.hasPrefix(root + "/") else { throw InstallRefusal.unsafeSymlink("\(relative) -> \(destination) leaves the bundle") }
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            guard realpath(link, &resolved) != nil else {
                throw InstallRefusal.unsafeSymlink("\(relative) -> \(destination) is dangling")
            }
            let physical = resolved.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard physical.hasPrefix(realRoot + "/") || physical == realRoot else {
                throw InstallRefusal.unsafeSymlink("\(relative) -> \(destination) resolves outside the bundle")
            }
        }
    }

    /// Writes data to a new file atomically: temp file 0600, fsync, rename, fsync the directory.
    public static func writeAtomically(_ data: Data, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let temp = directory + "/.tmp-" + UUID().uuidString
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstallRefusal.journal("could not create \(temp): \(String(cString: strerror(errno)))") }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { ok = false; break }
                offset += written
            }
        }
        if fsync(fd) != 0 { ok = false }
        close(fd)
        guard ok, rename(temp, path) == 0 else {
            unlink(temp)
            throw InstallRefusal.journal("could not write \(path)")
        }
        try syncDirectory(directory)
    }

    /// fsync a directory so a rename or new entry in it is durable. Errors are fatal.
    public static func syncDirectory(_ directory: String) throws {
        let dirFD = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFD >= 0 else { throw InstallRefusal.io("cannot open \(directory) to sync it") }
        defer { close(dirFD) }
        guard fsync(dirFD) == 0 else { throw InstallRefusal.io("fsync failed for \(directory)") }
    }

    /// Reads a small regular file (not a symlink), capped.
    public static func readSmallFile(_ path: String, limit: Int = 4 * 1024 * 1024) -> Data? {
        guard let info = lstatInfo(path), isRegular(info), Int(info.st_size) <= limit else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// Collapses `//`, `.` and `..` without touching the file system (unlike `standardizingPath`, which
    /// also strips `/private` and so cannot be used for containment checks).
    public static func lexicallyNormalised(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `realpath` of an existing path.
    public static func realPath(_ path: String) -> String? {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &resolved) != nil else { return nil }
        return resolved.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
