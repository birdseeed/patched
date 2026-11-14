import Foundation

public enum FetchLimits {
    public static let feedBytes = 4 * 1024 * 1024
    /// The single GitHub release record Patched reads about itself.
    public static let releaseBytes = 256 * 1024
    /// Apple's public OS version feed (gdmf.apple.com), about 90 KB in November 2026.
    public static let macOSFeedBytes = 1024 * 1024
    public static let caskIndexBytes = 64 * 1024 * 1024
    public static let timeout: TimeInterval = 20
    public static let concurrency = 6
}

public enum FetchError: Error, Sendable, Equatable {
    case insecureScheme(String)
    case insecureRedirect(String)
    case tooLarge
    case http(Int)
    case transport(String)
    /// The request never reached a server: see `FetchError.offlineCodes`.
    case offline(String)

    /// URLSession failures that mean "no usable connection", not "the server answered badly".
    public static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    /// Classifies a URLSession error: offline for the codes above, transport for anything else.
    public static func classify(_ error: Error) -> FetchError {
        if let url = error as? URLError, offlineCodes.contains(url.code) { return .offline(url.localizedDescription) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, offlineCodes.contains(URLError.Code(rawValue: ns.code)) { return .offline(ns.localizedDescription) }
        return .transport(ns.localizedDescription)
    }

    public var refusal: RefusalReason {
        switch self {
        case .insecureScheme(let u): return .insecureFeed(u)
        case .insecureRedirect(let u): return .insecureRedirect(u)
        case .tooLarge: return .tooLarge
        case .http(let code): return .network("HTTP \(code)")
        case .transport(let detail): return .network(detail)
        case .offline(let detail): return .offline(detail)
        }
    }
}

public protocol HTTPFetching: Sendable {
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data
    /// As `fetch(_:maxBytes:)`, with `Accept` and `User-Agent` set (the only headers that can be chosen) and, when
    /// `allowedRedirectHosts` is given, redirects limited to those hosts (any other redirect fails the request).
    /// Fetchers that do not care about headers need not implement it.
    func fetch(_ url: URL, maxBytes: Int, accept: String?, userAgent: String?, allowedRedirectHosts: Set<String>?) async throws -> Data
}

extension HTTPFetching {
    public func fetch(_ url: URL, maxBytes: Int, accept: String?, userAgent: String?, allowedRedirectHosts: Set<String>?) async throws -> Data {
        try await fetch(url, maxBytes: maxBytes)
    }
}

/// Redirects may only stay on https. A pure function so it can be tested without a network.
public enum HTTPSRedirectPolicy {
    public static func decide(_ proposed: URLRequest, allowedHosts: Set<String>? = nil) -> URLRequest? {
        guard let url = proposed.url, url.isHTTPS else { return nil }
        if let allowedHosts, !allowedHosts.contains(url.host?.lowercased() ?? "") { return nil }
        return proposed
    }
}

final class HTTPSOnlyRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>?
    init(allowedHosts: Set<String>? = nil) { self.allowedHosts = allowedHosts }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(HTTPSRedirectPolicy.decide(request, allowedHosts: allowedHosts))
    }
}

/// https-only, ephemeral (no cache, no cookies), size-capped fetcher with a generic User-Agent.
public struct URLSessionFetcher: HTTPFetching {
    public static let userAgent = "Patched"
    private let session: URLSession

    public init() { self.init(configuration: .ephemeral) }

    /// Applies the same hardening to the given configuration (tests pass one with a stub `URLProtocol`).
    public init(configuration config: URLSessionConfiguration) {
        config.timeoutIntervalForRequest = FetchLimits.timeout
        config.timeoutIntervalForResource = FetchLimits.timeout * 6
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: config)
    }

    public func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        try await fetch(url, maxBytes: maxBytes, accept: nil, userAgent: nil, allowedRedirectHosts: nil)
    }

    public func fetch(_ url: URL, maxBytes: Int, accept: String?, userAgent: String?, allowedRedirectHosts: Set<String>?) async throws -> Data {
        guard url.isHTTPS else { throw FetchError.insecureScheme(url.absoluteString) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: FetchLimits.timeout)
        request.setValue(userAgent ?? Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: HTTPSOnlyRedirectGuard(allowedHosts: allowedRedirectHosts))
            guard let http = response as? HTTPURLResponse else { throw FetchError.transport("non-HTTP response") }
            if (300..<400).contains(http.statusCode) { throw FetchError.insecureRedirect(http.value(forHTTPHeaderField: "Location") ?? url.absoluteString) }
            guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
            if http.expectedContentLength > Int64(maxBytes) { throw FetchError.tooLarge }
            var data = Data(), chunk = [UInt8]()
            chunk.reserveCapacity(65_536)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 65_536 {
                    data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                    if data.count > maxBytes { throw FetchError.tooLarge }
                }
            }
            data.append(contentsOf: chunk)
            if data.count > maxBytes { throw FetchError.tooLarge }
            return data
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.classify(error)
        }
    }
}
