import Foundation
import Darwin

/// An explicit, bounded observation of local directories and untrusted plist claims.
public actor LocalApplicationInventory {
    private let sessionID = UUID()
    private var generation: UInt64 = 0
    private let fixtureRoots: [String]?
    private let observer: (@Sendable (LocalInventoryReadEvent) -> Void)?
    public init() {
        fixtureRoots = nil; observer = nil
    }
    /// Scans exactly these directories instead of /Applications and ~/Applications (observations report `.fixture` provenance).
    public init(scanningDirectories roots: [String]) {
        fixtureRoots = roots; observer = nil
    }
    @_spi(Testing) public init(fixtureRoots: [String], observer: (@Sendable (LocalInventoryReadEvent) -> Void)? = nil) {
        self.fixtureRoots = fixtureRoots; self.observer = observer
    }
    public func scan() -> LocalInventoryObservation {
        let started = Date(), provenance: LocalInventoryProvenance = fixtureRoots == nil ? .native : .fixture
        guard generation < UInt64.max else {
            return LocalInventoryObservation(sessionID: sessionID, generation: generation, startedAt: started,
                finishedAt: Date(), provenance: provenance, roots: [], applications: [],
                issues: [LocalInventoryIssue(kind: .generationExhausted, path: nil)], completeness: .unavailable)
        }
        generation += 1
        let requested: [(String, LocalInventoryRootScope)]
        if let fixtureRoots { requested = fixtureRoots.map { ($0, .fixture) } }
        else { requested = [("/Applications", .systemApplications), (InventoryIO.home().map { $0 + "/Applications" } ?? "", .userApplications)] }
        var scan = InventoryScan(observer: observer)
        for (path, scope) in requested { scan.root(path, scope: scope) }
        return LocalInventoryObservation(sessionID: sessionID, generation: generation, startedAt: started,
            finishedAt: Date(), provenance: provenance, roots: scan.roots,
            applications: scan.rows.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) },
            issues: scan.issues, completeness: scan.issues.isEmpty ? .complete : .incomplete)
    }
}

private enum InventoryFailure: Error, Equatable { case absent, unsafe, unreadable, changed }
private enum InventoryIO {
    static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    static let fileFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    static func home() -> String? {
        // Account database lookup uses the effective principal, never environment HOME.
        var entry = passwd(), found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 65_536)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(geteuid(), &entry, bytes.baseAddress!, bytes.count, &found) == 0,
                  found != nil, entry.pw_uid == geteuid(), let path = entry.pw_dir else { return nil }
            return String(validatingCString: path)
        }
    }
    static func safeText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= LocalInventoryLimits.fieldBytes &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func safeFeed(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value), parts.string == value,
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return false }
        return true
    }
    static func components(_ path: String) throws -> [String] {
        guard path.utf8.count <= LocalInventoryLimits.pathBytes, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InventoryFailure.unsafe }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= Int(NAME_MAX) }) else { throw InventoryFailure.unsafe }
        return parts.map(String.init)
    }
    /// Whether two stats describe the same, unchanged object. A directory is compared by identity only (device,
    /// inode, type and permissions, owner): its times, size and link count change whenever any entry is added
    /// or removed, and its ancestors (/, the home folder, the shared temporary folder) are written by other
    /// programs all the time, which made whole roots unavailable. A directory swapped, renamed over or replaced
    /// by a link still fails, and files keep the full comparison, times included.
    static func stable(_ a: stat, _ b: stat) -> Bool {
        let identity = a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
        if identity && a.st_mode & S_IFMT == S_IFDIR { return true }
        return identity &&
            a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }
    static func named(_ parent: Int32, _ name: String) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw errno == ENOENT ? InventoryFailure.absent : InventoryFailure.unreadable
        }
        return value
    }
    static func confirm(_ fd: Int32, _ before: stat, parent: Int32, name: String) throws {
        var held = stat()
        guard fstat(fd, &held) == 0, held.st_nlink > 0, stable(before, held),
              let named = try? named(parent, name), stable(held, named) else { throw InventoryFailure.changed }
    }
    static func issue(_ error: Error) -> LocalInventoryIssueKind {
        switch error {
        case InventoryFailure.changed: return .changedDuringScan
        case InventoryFailure.unsafe: return .unsafePath
        default: return .unreadable
        }
    }
}

/// Each directory keeps both its descriptor and its named parent alive. Confirmations
/// bind every ancestor back to /; a renamed descriptor alone is insufficient evidence.
private final class InventoryDirectory {
    let fd: Int32, captured: stat, parent: InventoryDirectory?, name: String, path: String
    init(fd: Int32, captured: stat, parent: InventoryDirectory?, name: String, path: String) {
        self.fd = fd; self.captured = captured; self.parent = parent; self.name = name; self.path = path
    }
    deinit { close(fd) }
    static func absolute(_ path: String) throws -> InventoryDirectory {
        let parts = try InventoryIO.components(path)
        let fd = Darwin.open("/", InventoryIO.directoryFlags)
        guard fd >= 0 else { throw InventoryFailure.unreadable }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { close(fd); throw InventoryFailure.unsafe }
        var current = InventoryDirectory(fd: fd, captured: value, parent: nil, name: "", path: "")
        for name in parts { current = try current.child(name) }
        return current
    }
    func confirm() throws {
        if let parent {
            try parent.confirm()
            try InventoryIO.confirm(fd, captured, parent: parent.fd, name: name)
        } else {
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, lstat("/", &named) == 0,
                  InventoryIO.stable(captured, held), InventoryIO.stable(held, named) else { throw InventoryFailure.changed }
        }
    }
    func child(_ name: String) throws -> InventoryDirectory {
        try confirm()
        let before = try InventoryIO.named(fd, name)
        guard before.st_mode & S_IFMT == S_IFDIR else { throw InventoryFailure.unsafe }
        let opened = openat(fd, name, InventoryIO.directoryFlags)
        guard opened >= 0 else { throw InventoryFailure.unreadable }
        var captured = stat()
        guard fstat(opened, &captured) == 0, InventoryIO.stable(before, captured) else { close(opened); throw InventoryFailure.changed }
        let child = InventoryDirectory(fd: opened, captured: captured, parent: self, name: name, path: path + "/" + name)
        try child.confirm()
        return child
    }
}

private struct InventoryScan {
    let observer: (@Sendable (LocalInventoryReadEvent) -> Void)?
    var roots: [LocalInventoryRootObservation] = []
    var rows: [LocalApplicationObservation] = []
    var issues: [LocalInventoryIssue] = []
    private var entries = 0, metadataBytes = 0
    private var iconBytes = 0, retainedIcons = 0
    private var entryLimit = false

    init(observer: (@Sendable (LocalInventoryReadEvent) -> Void)?) {
        self.observer = observer
    }
    mutating func issue(_ kind: LocalInventoryIssueKind, _ path: String?) {
        let safePath = path.flatMap { $0.utf8.count <= LocalInventoryLimits.pathBytes ? $0 : nil }
        if issues.count < LocalInventoryLimits.issues {
            issues.append(LocalInventoryIssue(kind: kind, path: safePath))
        }
        if issues.count == LocalInventoryLimits.issues {
            issues[LocalInventoryLimits.issues - 1] = LocalInventoryIssue(kind: .issueLimit, path: nil)
        }
    }
    mutating func root(_ path: String, scope: LocalInventoryRootScope) {
        var status: LocalInventoryRootStatus = .scanned
        let outputPath = path.utf8.count <= LocalInventoryLimits.pathBytes ? path : ""
        do {
            guard !path.isEmpty else { issue(.unavailable, nil); roots.append(.init(path: outputPath, scope: scope, status: .unavailable)); return }
            guard path.utf8.count <= LocalInventoryLimits.pathBytes else { issue(.pathLimit, nil); roots.append(.init(path: outputPath, scope: scope, status: .refused)); return }
            let directory = try InventoryDirectory.absolute(path)
            guard scope != .userApplications || directory.captured.st_uid == geteuid() else { throw InventoryFailure.unsafe }
            walk(directory, depth: 0)
            try directory.confirm()
        } catch InventoryFailure.absent { status = .absent }
        catch {
            status = (error as? InventoryFailure) == .unsafe ? .refused : .unavailable
            issue(InventoryIO.issue(error), path)
            refuseRows(under: path)
        }
        roots.append(LocalInventoryRootObservation(path: outputPath, scope: scope, status: status))
    }
    mutating func refuseRows(under path: String) {
        for index in rows.indices where rows[index].path.hasPrefix(path + "/") {
            let row = rows[index]
            rows[index] = LocalApplicationObservation(path: row.path, physicalIdentity: row.physicalIdentity,
                displayName: fallback(row.path.split(separator: "/").last.map(String.init) ?? ""),
                claimedBundleIdentifier: nil, claimedShortVersion: nil, claimedBuild: nil, metadataDisposition: .refused)
        }
    }
    mutating func names(_ directory: InventoryDirectory) throws -> [String] {
        try directory.confirm()
        if entryLimit { return [] }
        let duplicate = openat(directory.fd, ".", InventoryIO.directoryFlags)
        guard duplicate >= 0 else { throw InventoryFailure.unreadable }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw InventoryFailure.unreadable }
        defer { closedir(stream) }
        var result: [String] = []
        while !entryLimit {
            errno = 0
            guard let pointer = readdir(stream) else {
                guard errno == 0 else { throw InventoryFailure.unreadable }
                break
            }
            var entry = pointer.pointee
            let bytes = withUnsafeBytes(of: &entry.d_name) { Array($0.prefix(Int(entry.d_namlen))) }
            if bytes == [46] || bytes == [46, 46] { continue }
            entries += 1 // All entries count, including files, hidden names and refusals.
            if entries == LocalInventoryLimits.directoryEntries {
                entryLimit = true; issue(.entryLimit, directory.path)
            }
            guard !bytes.isEmpty, !bytes.contains(0), !bytes.contains(47),
                  let name = String(bytes: bytes, encoding: .utf8), Array(name.utf8) == bytes,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                issue(.unsafePath, directory.path); continue
            }
            result.append(name)
        }
        try directory.confirm()
        return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    mutating func walk(_ directory: InventoryDirectory, depth: Int) {
        do {
            for name in try names(directory) {
                let path = directory.path + "/" + name
                guard path.utf8.count <= LocalInventoryLimits.pathBytes else { issue(.pathLimit, nil); continue }
                do {
                    try directory.confirm()
                    let named = try InventoryIO.named(directory.fd, name)
                    if named.st_mode & S_IFMT == S_IFLNK { issue(.unsafePath, path); continue }
                    guard named.st_mode & S_IFMT == S_IFDIR, !name.hasPrefix(".") else { continue }
                    guard depth < LocalInventoryLimits.directoryDepth else { issue(.depthLimit, path); continue }
                    let child = try directory.child(name)
                    if name.lowercased().hasSuffix(".app") {
                        guard rows.count < LocalInventoryLimits.applications else { issue(.applicationLimit, path); continue }
                        application(child)
                    } else if depth + 1 == LocalInventoryLimits.directoryDepth {
                        // This directory itself is at the boundary; its contents would be deeper.
                        issue(.depthLimit, path)
                    } else { walk(child, depth: depth + 1) }
                } catch { issue(InventoryIO.issue(error), path) }
            }
            try directory.confirm()
        } catch { issue(InventoryIO.issue(error), directory.path); refuseRows(under: directory.path) }
    }
    func fallback(_ name: String) -> String {
        let value = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        return InventoryIO.safeText(value) ? value : "Application"
    }
    /// An iPhone/iPad app from the App Store has `Wrapper/<Name>.app` and no `Contents`.
    private struct WrappedIOSMetadata { let display: String?, identifier: String?, version: String?, build: String? }

    /// Reads one regular file (never a symlink) inside a held directory, within the plist size cap and the shared
    /// metadata budget, confirming the file and every ancestor around each read.
    mutating func boundedFile(_ directory: InventoryDirectory, _ name: String, limit: Int, applicationPath: String) throws -> Data {
        let before = try InventoryIO.named(directory.fd, name)
        guard before.st_mode & S_IFMT == S_IFREG else { throw InventoryFailure.unsafe }
        let fd = openat(directory.fd, name, InventoryIO.fileFlags)
        guard fd >= 0 else { throw InventoryFailure.unreadable }
        defer { close(fd) }
        try directory.confirm()
        try InventoryIO.confirm(fd, before, parent: directory.fd, name: name)
        guard before.st_size >= 0, before.st_size <= limit else { issue(.plistLimit, applicationPath); throw InventoryFailure.unsafe }
        let size = Int(before.st_size)
        guard size <= LocalInventoryLimits.totalMetadataBytes - metadataBytes else {
            issue(.totalMetadataLimit, applicationPath); throw InventoryFailure.unsafe
        }
        metadataBytes += size
        var bytes = [UInt8](repeating: 0, count: size), offset = 0
        while offset < size {
            try directory.confirm()
            try InventoryIO.confirm(fd, before, parent: directory.fd, name: name)
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + offset, min(65_536, size - offset), off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw InventoryFailure.changed }
            offset += count
        }
        try directory.confirm()
        try InventoryIO.confirm(fd, before, parent: directory.fd, name: name)
        return Data(bytes)
    }

    /// `Wrapper/` must be a real folder holding exactly one `*.app` folder (also real) and `iTunesMetadata.plist`.
    /// The inner `Info.plist` supplies the claims; the iTunes record must name the same bundle ID when it names one.
    private mutating func wrappedIOSMetadata(_ bundle: InventoryDirectory) throws -> WrappedIOSMetadata {
        let wrapper = try bundle.child("Wrapper")
        let listed = try names(wrapper)
        let inner = listed.filter { $0.lowercased().hasSuffix(".app") }
        guard inner.count == 1, listed.contains("iTunesMetadata.plist") else { throw InventoryFailure.unsafe }
        let innerApp = try wrapper.child(inner[0])
        let itunes = try boundedFile(wrapper, "iTunesMetadata.plist", limit: LocalInventoryLimits.plistBytes, applicationPath: bundle.path)
        let info = try boundedFile(innerApp, "Info.plist", limit: LocalInventoryLimits.plistBytes, applicationPath: bundle.path)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let infoValue = try? PropertyListSerialization.propertyList(from: info, options: [], format: &format),
              format == .xml || format == .binary, let dictionary = infoValue as? [String: Any],
              let itunesValue = try? PropertyListSerialization.propertyList(from: itunes, options: [], format: &format),
              let record = itunesValue as? [String: Any] else { throw InventoryFailure.unsafe }
        func field(_ key: String) throws -> String? {
            guard let raw = dictionary[key] else { return nil }
            guard let text = raw as? String, InventoryIO.safeText(text) else { throw InventoryFailure.unsafe }
            return text
        }
        let identifier = try field("CFBundleIdentifier")
        if let claimed = record["softwareVersionBundleId"], (claimed as? String) != identifier { throw InventoryFailure.unsafe }
        let metadata = WrappedIOSMetadata(display: try field("CFBundleDisplayName") ?? field("CFBundleName"), identifier: identifier,
                                          version: try field("CFBundleShortVersionString"), build: try field("CFBundleVersion"))
        try innerApp.confirm()
        try wrapper.confirm()
        try bundle.confirm()
        return metadata
    }

    mutating func wrappedApplication(_ bundle: InventoryDirectory) {
        var row = LocalApplicationObservation(path: bundle.path, physicalIdentity: Self.identity(bundle), displayName: fallback(bundle.name),
                                              claimedBundleIdentifier: nil, claimedShortVersion: nil, claimedBuild: nil,
                                              metadataDisposition: .refused)
        do {
            let found = try wrappedIOSMetadata(bundle)
            let observed = found.identifier != nil && found.version != nil && found.build != nil
            row = LocalApplicationObservation(path: bundle.path, physicalIdentity: Self.identity(bundle),
                displayName: found.display ?? fallback(bundle.name), claimedBundleIdentifier: found.identifier,
                claimedShortVersion: found.version, claimedBuild: found.build,
                metadataDisposition: observed ? .observed : .unavailable, isWrappedIOSApp: true)
            if !observed { issue(.metadataUnavailable, bundle.path) }
        } catch {
            issue(InventoryIO.issue(error), bundle.path)
        }
        rows.append(row)
        if rows.count == LocalInventoryLimits.applications { issue(.applicationLimit, bundle.path) }
    }

    static func identity(_ bundle: InventoryDirectory) -> LocalInventoryPhysicalIdentity {
        let captured = bundle.captured
        return LocalInventoryPhysicalIdentity(device: UInt64(UInt32(bitPattern: captured.st_dev)),
            inode: UInt64(captured.st_ino), changeSeconds: Int64(captured.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(captured.st_ctimespec.tv_nsec))
    }

    mutating func application(_ bundle: InventoryDirectory) {
        if (try? InventoryIO.named(bundle.fd, "Contents")) == nil, (try? InventoryIO.named(bundle.fd, "Wrapper")) != nil {
            wrappedApplication(bundle); return
        }
        var display = fallback(bundle.name), identifier: String?, version: String?, build: String?
        var disposition: LocalInventoryMetadataDisposition = .unavailable
        var feed: String?, config: Data?, product: Data?
        var edKey: String?
        var backgroundOnly = false
        var installedIcon: LocalInstalledIcon?
        var feedDisposition: LocalInventoryMetadataDisposition = .unavailable
        var configDisposition: LocalInventoryMetadataDisposition = .unavailable
        var productDisposition: LocalInventoryMetadataDisposition = .unavailable
        do {
            let contents = try bundle.child("Contents")
            let before = try InventoryIO.named(contents.fd, "Info.plist")
            guard before.st_mode & S_IFMT == S_IFREG else { throw InventoryFailure.unsafe }
            let fd = openat(contents.fd, "Info.plist", InventoryIO.fileFlags)
            guard fd >= 0 else { throw InventoryFailure.unreadable }
            defer { close(fd) }
            try InventoryIO.confirm(fd, before, parent: contents.fd, name: "Info.plist")
            // All three boundaries are now captured; the observer supplies no outcome data.
            observer?(.beforeMetadataRead(applicationPath: bundle.path))
            try contents.confirm()
            try InventoryIO.confirm(fd, before, parent: contents.fd, name: "Info.plist")
            guard before.st_size >= 0, before.st_size <= LocalInventoryLimits.plistBytes else {
                issue(.plistLimit, bundle.path); append(); return
            }
            let size = Int(before.st_size)
            guard size <= LocalInventoryLimits.totalMetadataBytes - metadataBytes else {
                issue(.totalMetadataLimit, bundle.path); append(); return
            }
            metadataBytes += size // Reserve even a partial/failed read against the aggregate bound.
            if metadataBytes == LocalInventoryLimits.totalMetadataBytes { issue(.totalMetadataLimit, bundle.path) }
            var bytes = [UInt8](repeating: 0, count: size), offset = 0
            while offset < size {
                try contents.confirm()
                try InventoryIO.confirm(fd, before, parent: contents.fd, name: "Info.plist")
                let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + offset, min(65_536, size - offset), off_t(offset)) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw InventoryFailure.changed }
                offset += count
            }
            try contents.confirm()
            try InventoryIO.confirm(fd, before, parent: contents.fd, name: "Info.plist")
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let value = try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: &format),
                  format == .xml || format == .binary, let dictionary = value as? [String: Any] else {
                disposition = .malformed; issue(.malformedMetadata, bundle.path); append(); return
            }
            var malformed = false, limited = false
            func field(_ key: String) -> String? {
                guard let raw = dictionary[key] else { return nil }
                guard let text = raw as? String else { malformed = true; return nil }
                guard InventoryIO.safeText(text) else { malformed = true; limited = true; return nil }
                return text
            }
            let preferred = field("CFBundleDisplayName"), name = field("CFBundleName")
            identifier = field("CFBundleIdentifier"); version = field("CFBundleShortVersionString"); build = field("CFBundleVersion")
            display = preferred ?? name ?? display
            edKey = dictionary["SUPublicEDKey"] == nil ? nil : (dictionary["SUPublicEDKey"] as? String ?? "")
            switch dictionary["LSBackgroundOnly"] {
            case let number as NSNumber: backgroundOnly = number.boolValue
            case let text as String: backgroundOnly = ["1", "yes", "true"].contains(text.lowercased())
            default: backgroundOnly = false
            }
            // Some real menu bar apps (OneDrive, BetterDisplay) declare LSBackgroundOnly too. An app that names
            // its own icon is one people know they have, so only icon-less helpers count as background-only.
            if backgroundOnly, ["CFBundleIconFile", "CFBundleIconName"].contains(where: { !((dictionary[$0] as? String) ?? "").isEmpty }) {
                backgroundOnly = false
            }
            if let raw = dictionary["SUFeedURL"] {
                if let text = raw as? String, InventoryIO.safeFeed(text) {
                    feed = text; feedDisposition = .observed
                } else {
                    feedDisposition = .malformed; issue(.malformedMetadata, bundle.path)
                }
            }
            disposition = malformed ? .malformed : (identifier != nil && version != nil && build != nil ? .observed : .unavailable)
            if limited { issue(.fieldLimit, bundle.path) }
            if malformed { issue(.malformedMetadata, bundle.path) }
            else if disposition != .observed { issue(.metadataUnavailable, bundle.path) }
            // Parsing is also inside the identity window. No accepted metadata survives a swap.
            try contents.confirm()
            try InventoryIO.confirm(fd, before, parent: contents.fd, name: "Info.plist")
            (config, configDisposition) = electronConfig(contents, applicationPath: bundle.path)
            (product, productDisposition) = productJSON(contents, applicationPath: bundle.path)
            installedIcon = icon(dictionary["CFBundleIconFile"], contents: contents, applicationPath: bundle.path)
            // Optional vendor-file failure is independent, but no claim survives
            // a changed plist or application namespace during these observations.
            try contents.confirm()
            try InventoryIO.confirm(fd, before, parent: contents.fd, name: "Info.plist")
        } catch {
            identifier = nil; version = nil; build = nil; display = fallback(bundle.name)
            disposition = (error as? InventoryFailure) == .absent ? .unavailable : .refused
            feed = nil; config = nil; product = nil; installedIcon = nil; edKey = nil
            feedDisposition = disposition; configDisposition = disposition; productDisposition = disposition
            issue((error as? InventoryFailure) == .absent ? .metadataUnavailable : InventoryIO.issue(error), bundle.path)
        }
        append()
        func append() {
            let captured = bundle.captured
            rows.append(LocalApplicationObservation(path: bundle.path,
                physicalIdentity: LocalInventoryPhysicalIdentity(device: UInt64(UInt32(bitPattern: captured.st_dev)),
                    inode: UInt64(captured.st_ino), changeSeconds: Int64(captured.st_ctimespec.tv_sec),
                    changeNanoseconds: Int64(captured.st_ctimespec.tv_nsec)), displayName: display,
                claimedBundleIdentifier: identifier, claimedShortVersion: version, claimedBuild: build, metadataDisposition: disposition,
                vendorMetadata: LocalInstalledVendorMetadata(sparkleFeedURL: feed, electronConfigBytes: config,
                    sparkleDisposition: feedDisposition, electronDisposition: configDisposition,
                    productJSONBytes: product, productJSONDisposition: productDisposition,
                    sparklePublicEDKey: edKey, backgroundOnly: backgroundOnly), installedIcon: installedIcon))
            if rows.count == LocalInventoryLimits.applications { issue(.applicationLimit, bundle.path) }
        }
    }

    /// One explicit resource leaf only, with a separate attempted-input budget.
    /// The output allowance is checked before touching the icon namespace.
    mutating func icon(_ raw: Any?, contents: InventoryDirectory, applicationPath: String) -> LocalInstalledIcon? {
        guard retainedIcons < 64, let raw else { return nil }
        guard let name = raw as? String, !name.isEmpty, name.utf8.count <= 255,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.lowercased().hasSuffix(".png") || name.lowercased().hasSuffix(".icns") else { return nil }
        do {
            let resources = try contents.child("Resources")
            let before = try InventoryIO.named(resources.fd, name)
            guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw InventoryFailure.unsafe }
            let fd = openat(resources.fd, name, InventoryIO.fileFlags)
            guard fd >= 0 else { throw InventoryFailure.unreadable }
            defer { close(fd) }
            func confirm() throws {
                try resources.confirm()
                try InventoryIO.confirm(fd, before, parent: resources.fd, name: name)
            }
            try confirm()
            guard before.st_size > 0, before.st_size <= 1_048_576 else { return nil }
            let size = Int(before.st_size)
            guard size <= 8_388_608 - iconBytes else { return nil }
            iconBytes += size // Failed and partial reads consume the reservation too.
            observer?(.beforeIconRead(applicationPath: applicationPath))
            try confirm()
            let observer = observer
            // Release each encoded buffer and ImageIO source before the next copy.
            let result: LocalInstalledIcon? = try autoreleasepool {
                var bytes = Data(repeating: 0, count: size), offset = 0
                while offset < size {
                    try confirm()
                    let count = bytes.withUnsafeMutableBytes {
                        pread(fd, $0.baseAddress! + offset, min(65_536, size - offset), off_t(offset))
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw InventoryFailure.changed }
                    offset += count
                    try confirm()
                }
                try confirm()
                let value = try LocalInstalledIconDecoder.normalise(bytes, confirm: confirm) {
                    observer?(.beforeIconDecode(applicationPath: applicationPath))
                }
                try confirm()
                return value
            }
            try confirm()
            if result != nil { retainedIcons += 1 }
            return result
        } catch InventoryFailure.absent {
            return nil
        } catch {
            // A leaf-only failure preserves independent metadata. The caller
            // separately reconfirms Contents and Info.plist after all icon work.
            issue(InventoryIO.issue(error), applicationPath)
            return nil
        }
    }

    /// Observe only the fixed installed file. These bytes are unparsed, untrusted
    /// claims and share the plist budget, including unsuccessful reserved reads.
    mutating func electronConfig(_ contents: InventoryDirectory, applicationPath: String) -> (Data?, LocalInventoryMetadataDisposition) {
        do {
            let resources = try contents.child("Resources")
            let before = try InventoryIO.named(resources.fd, "app-update.yml")
            guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw InventoryFailure.unsafe }
            let fd = openat(resources.fd, "app-update.yml", InventoryIO.fileFlags)
            guard fd >= 0 else { throw InventoryFailure.unreadable }
            defer { close(fd) }
            try resources.confirm()
            try InventoryIO.confirm(fd, before, parent: resources.fd, name: "app-update.yml")
            guard before.st_size >= 0, before.st_size <= 65_536 else {
                issue(.malformedMetadata, applicationPath); return (nil, .malformed)
            }
            let size = Int(before.st_size)
            guard size <= LocalInventoryLimits.totalMetadataBytes - metadataBytes else {
                issue(.totalMetadataLimit, applicationPath); return (nil, .refused)
            }
            metadataBytes += size
            if metadataBytes == LocalInventoryLimits.totalMetadataBytes { issue(.totalMetadataLimit, applicationPath) }
            var bytes = [UInt8](repeating: 0, count: size), offset = 0
            while offset < size {
                try resources.confirm()
                try InventoryIO.confirm(fd, before, parent: resources.fd, name: "app-update.yml")
                let count = bytes.withUnsafeMutableBytes {
                    pread(fd, $0.baseAddress! + offset, min(65_536, size - offset), off_t(offset))
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw InventoryFailure.changed }
                offset += count
            }
            try resources.confirm()
            try InventoryIO.confirm(fd, before, parent: resources.fd, name: "app-update.yml")
            guard !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil else {
                issue(.malformedMetadata, applicationPath); return (nil, .malformed)
            }
            let data = Data(bytes)
            try resources.confirm()
            try InventoryIO.confirm(fd, before, parent: resources.fd, name: "app-update.yml")
            return (data, .observed)
        } catch InventoryFailure.absent {
            return (nil, .unavailable)
        } catch {
            issue(InventoryIO.issue(error), applicationPath)
            return (nil, .refused)
        }
    }

    /// Raw product claims only, at one fixed path and with the same shared budget.
    mutating func productJSON(_ contents: InventoryDirectory, applicationPath: String) -> (Data?, LocalInventoryMetadataDisposition) {
        do {
            let resources = try contents.child("Resources").child("app")
            let before = try InventoryIO.named(resources.fd, "product.json")
            guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw InventoryFailure.unsafe }
            let fd = openat(resources.fd, "product.json", InventoryIO.fileFlags)
            guard fd >= 0 else { throw InventoryFailure.unreadable }
            defer { close(fd) }
            try resources.confirm()
            try InventoryIO.confirm(fd, before, parent: resources.fd, name: "product.json")
            guard before.st_size >= 0, before.st_size <= 65_536 else {
                issue(.malformedMetadata, applicationPath); return (nil, .malformed)
            }
            let size = Int(before.st_size)
            guard size <= LocalInventoryLimits.totalMetadataBytes - metadataBytes else {
                issue(.totalMetadataLimit, applicationPath); return (nil, .refused)
            }
            metadataBytes += size
            if metadataBytes == LocalInventoryLimits.totalMetadataBytes { issue(.totalMetadataLimit, applicationPath) }
            // Notification is inside the captured fd/name window; it supplies no bytes.
            observer?(.beforeProductMetadataRead(applicationPath: applicationPath))
            try resources.confirm()
            try InventoryIO.confirm(fd, before, parent: resources.fd, name: "product.json")
            var bytes = [UInt8](repeating: 0, count: size), offset = 0
            while offset < size {
                try resources.confirm()
                try InventoryIO.confirm(fd, before, parent: resources.fd, name: "product.json")
                let count = bytes.withUnsafeMutableBytes {
                    pread(fd, $0.baseAddress! + offset, min(65_536, size - offset), off_t(offset))
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw InventoryFailure.changed }
                offset += count
            }
            try resources.confirm()
            try InventoryIO.confirm(fd, before, parent: resources.fd, name: "product.json")
            guard !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil else {
                issue(.malformedMetadata, applicationPath); return (nil, .malformed)
            }
            let data = Data(bytes)
            try resources.confirm()
            try InventoryIO.confirm(fd, before, parent: resources.fd, name: "product.json")
            return (data, .observed)
        } catch InventoryFailure.absent {
            return (nil, .unavailable)
        } catch {
            issue(InventoryIO.issue(error), applicationPath)
            return (nil, .refused)
        }
    }
}
