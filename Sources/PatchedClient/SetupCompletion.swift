import Foundation
import Darwin
import UpdateSources

/// Whether first-run setup has been completed. One flag and nothing else.
@MainActor public protocol SetupCompletionStoring: AnyObject {
    var completed: Bool { get }
    func markCompleted()
}

/// The app's own `UserDefaults` key `setupCompleted`. Under the test tripwire it lives in memory only.
/// When the key is not set, a completed setup recorded by an earlier build counts, once.
@MainActor public final class DefaultsSetupCompletion: SetupCompletionStoring {
    public static let key = "setupCompleted"
    private var memory = false
    private var useMemory: Bool { RealStateTripwire.isActive }
    /// Resolved only when real state is allowed, so under the tripwire nothing touches real defaults.
    private let defaults: () -> UserDefaults
    public init(defaults: @escaping () -> UserDefaults = { .standard }) { self.defaults = defaults }
    public var completed: Bool {
        if useMemory { return memory }
        let store = defaults()
        if store.bool(forKey: Self.key) { return true }
        let folder = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Patched"
        guard LegacySetupRecord.completed(inPatchedFolder: folder) else { return false }
        store.set(true, forKey: Self.key)
        return true
    }
    public func markCompleted() {
        if useMemory { memory = true; return }
        defaults().set(true, forKey: Self.key)
    }
}

/// Reads only `setup.completed` from the preferences record written by earlier builds. Every other
/// field (schedule choices, failure reports, the network draft, receipts) is ignored, so any record those
/// builds wrote still loads. The record is never written, moved or deleted.
public enum LegacySetupRecord {
    public static let maximumBytes = 1_048_576

    /// `Preferences/record.json` first, then the older location directly in the Patched folder.
    public static func completed(inPatchedFolder folder: String) -> Bool {
        for path in [folder + "/Preferences/record.json", folder + "/record.json"] {
            if let bytes = read(path), completed(record: bytes) { return true }
        }
        return false
    }

    /// True only for a JSON object whose `setup.completed` is the JSON literal `true`.
    public static func completed(record bytes: Data) -> Bool {
        guard bytes.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let setup = object["setup"] as? [String: Any],
              let flag = setup["completed"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
        return flag.boolValue
    }

    /// A bounded read of a regular file. Every component is opened relative to its parent with
    /// O_NOFOLLOW, so a symlinked file or any symlinked ancestor folder reads as absent, as do FIFOs,
    /// folders and oversized files.
    static func read(_ path: String) -> Data? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let leaf = parts.last, !parts.contains(".."), !parts.contains(".") else { return nil }
        var dir = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        for part in parts.dropLast() {
            let next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(dir)
            guard next >= 0 else { return nil }
            dir = next
        }
        let fd = openat(dir, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        close(dir)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + offset, $0.count - offset, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            offset += count
        }
        return Data(bytes)
    }
}

/// Records setup completion in memory only: for checks and previews.
@MainActor public final class MemorySetupCompletion: SetupCompletionStoring {
    public private(set) var completed: Bool
    public private(set) var marks = 0
    public init(completed: Bool = false) { self.completed = completed }
    public func markCompleted() { completed = true; marks += 1 }
}
