import Foundation

/// A newer Patched release, as announced by GitHub's "latest release" record. Notify-only: the only thing
/// Patched ever does with it is show the version and, on a click, open the validated release page.
public struct PatchedRelease: Equatable, Sendable {
    /// The version without any leading "v", for example "0.2.0".
    public let version: String
    /// Exactly `https://github.com/birdseeed/patched/releases/tag/<tag>`; nothing else is ever accepted.
    public let pageURL: URL
    public init(version: String, pageURL: URL) { self.version = version; self.pageURL = pageURL }
}

/// What looking up Patched's own latest release found.
public enum PatchedReleaseResult: Equatable, Sendable {
    /// A valid release newer than the running app.
    case newer(PatchedRelease)
    /// No release, an older or equal one, a draft or prerelease, or a record that failed validation.
    case noNews
    /// The request itself failed (offline, server error). Says nothing about whether there is news.
    case unavailable
}

/// Reads `GET https://api.github.com/repos/birdseeed/patched/releases/latest`. The record is untrusted: only
/// `tag_name`, `html_url`, `draft` and `prerelease` are read, `html_url` must be this repository's page for
/// that exact tag, and no asset is ever looked at, downloaded or opened.
public enum PatchedReleaseChecker {
    public static let apiURL = URL(string: "https://api.github.com/repos/birdseeed/patched/releases/latest")!
    public static let accept = "application/vnd.github+json"
    static let tagPageBase = "https://github.com/birdseeed/patched/releases/tag/"

    public static func userAgent(version: String) -> String { "Patched/" + version }

    /// One request. `currentVersion` is the running app's `CFBundleShortVersionString`.
    public static func check(currentVersion: String, fetcher: any HTTPFetching) async -> PatchedReleaseResult {
        let data: Data
        do {
            data = try await fetcher.fetch(apiURL, maxBytes: FetchLimits.releaseBytes, accept: accept,
                                           userAgent: userAgent(version: currentVersion),
                                           allowedRedirectHosts: ["api.github.com"])
        } catch FetchError.http(404) {
            return .noNews           // no release published yet; 401, 403, 429 and the rest say nothing
        } catch {
            return .unavailable
        }
        return evaluate(data, currentVersion: currentVersion)
    }

    /// Pure: the record's bytes against the running version.
    public static func evaluate(_ data: Data, currentVersion: String) -> PatchedReleaseResult {
        guard let release = parse(data), VersionComparator.isNewer(release.version, than: currentVersion) else { return .noNews }
        return .newer(release)
    }

    public static func parse(_ data: Data) -> PatchedRelease? {
        guard data.count <= FetchLimits.releaseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, let version = version(fromTag: tag),
              let page = object["html_url"] as? String, page == tagPageBase + tag, let url = URL(string: page),
              object["draft"] as? Bool == false, object["prerelease"] as? Bool == false else { return nil }
        return PatchedRelease(version: version, pageURL: url)
    }

    /// `v1.2.3` or `1.2.3`: digits and single dots only after an optional "v".
    static func version(fromTag tag: String) -> String? {
        let body = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard body.range(of: "^[0-9]+(\\.[0-9]+)*\\z", options: .regularExpression) != nil else { return nil }
        return body
    }
}
