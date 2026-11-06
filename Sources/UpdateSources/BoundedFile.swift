import Foundation
import Darwin

/// One descriptor validates identity and bounds every read, including a concurrently growing file.
enum BoundedFile {
    static func read(_ url: URL, maxBytes: Int) throws -> (data: Data, modified: Date) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maxBytes else { throw POSIXError(.EINVAL) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maxBytes - data.count + 1))
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
            if count == 0 { break }
            guard count <= maxBytes - data.count else { throw POSIXError(.EFBIG) }
            data.append(contentsOf: buffer.prefix(count))
        }
        return (data, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
    }
}
