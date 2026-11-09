import Foundation
import CryptoKit
import Darwin
import UpdateSources

public enum DownloadLimits {
    /// Hard ceiling for any artifact.
    public static let maxBytes: Int64 = 4 * 1024 * 1024 * 1024
    public static let idleTimeout: TimeInterval = 60
    public static let totalTimeout: TimeInterval = 2 * 60 * 60
}

public struct DownloadedArtifact: Sendable, Equatable {
    public let path: String
    public let byteCount: Int64
    /// Lower-case hex.
    public let sha256Hex: String
    public let sha512: Data
}

/// Receives the body in chunks: writes it to a new 0600 file, hashes it with SHA-256 and SHA-512 as
/// it goes, and stops the moment the byte cap is passed. Used by the real downloader and by tests.
public final class ArtifactSink: @unchecked Sendable {
    private let fd: Int32
    public let path: String
    private let maxBytes: Int64
    private var sha256 = SHA256()
    private var sha512 = SHA512()
    public private(set) var byteCount: Int64 = 0
    private var closed = false

    public init(path: String, maxBytes: Int64) throws {
        self.path = path
        self.maxBytes = min(maxBytes, DownloadLimits.maxBytes)
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstallRefusal.io("could not create \(path): \(String(cString: strerror(errno)))") }
    }
    deinit { if !closed { close(fd) } }

    public func append(_ chunk: Data) throws {
        guard !closed else { throw InstallRefusal.io("download file already closed") }
        byteCount += Int64(chunk.count)
        if byteCount > maxBytes { throw InstallRefusal.tooLarge("more than \(maxBytes) bytes") }
        sha256.update(data: chunk)
        sha512.update(data: chunk)
        try chunk.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { throw InstallRefusal.io("write failed: \(String(cString: strerror(errno)))") }
                offset += written
            }
        }
    }

    public func finish() throws -> DownloadedArtifact {
        guard !closed else { throw InstallRefusal.io("download file already closed") }
        closed = true
        let synced = fsync(fd) == 0
        close(fd)
        guard synced else { throw InstallRefusal.io("fsync failed for \(path)") }
        let hex = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        return DownloadedArtifact(path: path, byteCount: byteCount, sha256Hex: hex, sha512: Data(sha512.finalize()))
    }
}

/// Fetches an artifact into a sink. `expectedLength` lets the implementation refuse early from Content-Length.
public protocol ArtifactDownloading: Sendable {
    func download(_ url: URL, into sink: ArtifactSink, expectedLength: Int64?) async throws
}

/// Compares what was downloaded with what the feed promised. Missing values are not checked; a value
/// that is present must match exactly.
public enum DigestCheck {
    public static func verify(_ artifact: DownloadedArtifact, against offer: UpdateOffer) throws {
        if let length = offer.length, Int64(length) != artifact.byteCount {
            throw InstallRefusal.lengthMismatch("feed says \(length) bytes, got \(artifact.byteCount)")
        }
        if let expected = offer.sha256 {
            let normalised = expected.lowercased()
            guard normalised.count == 64, normalised.allSatisfy(\.isHexDigit) else {
                throw InstallRefusal.hashMismatch("feed SHA-256 is malformed")
            }
            guard normalised == artifact.sha256Hex else {
                throw InstallRefusal.hashMismatch("SHA-256 expected \(normalised), got \(artifact.sha256Hex)")
            }
        }
        if let expected = offer.sha512 {
            guard let bytes = Data(base64Encoded: expected) ?? hexData(expected), bytes.count == 64 else {
                throw InstallRefusal.hashMismatch("feed SHA-512 is malformed")
            }
            guard bytes == artifact.sha512 else {
                throw InstallRefusal.hashMismatch("SHA-512 does not match")
            }
        }
    }

    static func hexData(_ text: String) -> Data? {
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(), index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte); index = next
        }
        return data
    }
}

/// Real https downloader: ephemeral session, https-only redirects (the Phase 1 policy), streams to the sink.
public struct URLSessionArtifactDownloader: ArtifactDownloading {
    /// When set, the first URL and every redirect must be on one of these hosts (lower case); nil allows any
    /// https host, as for vendor downloads.
    public let allowedHosts: Set<String>?
    public init(allowedHosts: Set<String>? = nil) { self.allowedHosts = allowedHosts }

    public func download(_ url: URL, into sink: ArtifactSink, expectedLength: Int64?) async throws {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw InstallRefusal.insecureDownload(url.absoluteString)
        }
        if let allowedHosts, !allowedHosts.contains(url.host?.lowercased() ?? "") {
            throw InstallRefusal.insecureDownload("\(url.absoluteString) is not on an allowed host")
        }
        let delegate = StreamingDelegate(sink: sink, expectedLength: expectedLength, allowedHosts: allowedHosts)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = DownloadLimits.idleTimeout
        config.timeoutIntervalForResource = DownloadLimits.totalTimeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": URLSessionFetcher.userAgent]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: DownloadLimits.idleTimeout)
        request.setValue(URLSessionFetcher.userAgent, forHTTPHeaderField: "User-Agent")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                let task = session.dataTask(with: request)
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let sink: ArtifactSink
    let expectedLength: Int64?
    let allowedHosts: Set<String>?
    var continuation: CheckedContinuation<Void, Error>?
    var task: URLSessionTask?
    private var failure: Error?
    private let lock = NSLock()

    init(sink: ArtifactSink, expectedLength: Int64?, allowedHosts: Set<String>? = nil) {
        self.sink = sink; self.expectedLength = expectedLength; self.allowedHosts = allowedHosts
    }

    func cancel() { lock.withLock { task }?.cancel() }

    private func fail(_ error: Error, _ task: URLSessionTask) {
        if failure == nil { failure = error }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let allowed = HTTPSRedirectPolicy.decide(request, allowedHosts: allowedHosts) {
            completionHandler(allowed)
        } else {
            fail(InstallRefusal.insecureDownload("redirect to \(request.url?.absoluteString ?? "?")"), task)
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(InstallRefusal.download("non-HTTP response"), dataTask); completionHandler(.cancel); return
        }
        guard http.url?.scheme?.lowercased() == "https",
              allowedHosts.map({ $0.contains(http.url?.host?.lowercased() ?? "") }) ?? true else {
            fail(InstallRefusal.insecureDownload(http.url?.absoluteString ?? "?"), dataTask); completionHandler(.cancel); return
        }
        guard http.statusCode == 200 else {
            fail(InstallRefusal.download("HTTP \(http.statusCode)"), dataTask); completionHandler(.cancel); return
        }
        let announced = http.expectedContentLength
        if announced > DownloadLimits.maxBytes {
            fail(InstallRefusal.tooLarge("server announces \(announced) bytes"), dataTask); completionHandler(.cancel); return
        }
        if let expectedLength, announced >= 0, announced != expectedLength {
            fail(InstallRefusal.lengthMismatch("feed says \(expectedLength) bytes, server announces \(announced)"), dataTask)
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do { try sink.append(data) } catch { fail(error, dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Error?
        if let failure { result = failure }
        else if let error { result = InstallRefusal.download((error as NSError).localizedDescription) }
        else { result = nil }
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let c = self.continuation; self.continuation = nil; return c
        }
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
    }
}
