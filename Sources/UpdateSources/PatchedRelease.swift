import Foundation

/// The two release files self-update needs: the zip and its Ed25519 signature. Each URL is exactly
/// `https://github.com/birdseeed/patched/releases/download/<tag>/<name>`, with the names
/// `Patched-<version>.zip` and `Patched-<version>.zip.sig`. Where they point is not trusted: the zip is only
/// installed if the signature verifies against the release key built into Patched.
public struct PatchedReleaseAssets: Equatable, Sendable {
    public let zipURL: URL
    public let signatureURL: URL
    public init(zipURL: URL, signatureURL: URL) { self.zipURL = zipURL; self.signatureURL = signatureURL }
}

/// A newer Patched release, as announced by GitHub's "latest release" record. Patched shows the version and,
/// on a click, opens the validated release page. When the release also carries its signed zip (`assets`), an
/// explicit, confirmed click can install it (see `SelfUpdater`); nothing else ever does.
public struct PatchedRelease: Equatable, Sendable {
    /// The version without any leading "v", for example "0.2.0".
    public let version: String
    /// Exactly `https://github.com/birdseeed/patched/releases/tag/<tag>`; nothing else is ever accepted.
    public let pageURL: URL
    /// The signed zip, when the release has both files under their exact names and URLs. nil: notify-only.
    public let assets: PatchedReleaseAssets?
    public init(version: String, pageURL: URL, assets: PatchedReleaseAssets? = nil) {
        self.version = version; self.pageURL = pageURL; self.assets = assets
    }
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
/// `tag_name`, `html_url`, `draft`, `prerelease` and each asset's `name` and `browser_download_url` are read.
/// `html_url` must be this repository's page for that exact tag, and an asset counts only under its exact
/// name and exact download URL for that tag. Nothing is downloaded here.
public enum PatchedReleaseChecker {
    public static let apiURL = URL(string: "https://api.github.com/repos/birdseeed/patched/releases/latest")!
    public static let accept = "application/vnd.github+json"
    static let tagPageBase = "https://github.com/birdseeed/patched/releases/tag/"
    static let downloadBase = "https://github.com/birdseeed/patched/releases/download/"
    /// At most this many assets are looked at; a record with more is notify-only.
    static let maxAssets = 64

    public static func zipName(version: String) -> String { "Patched-" + version + ".zip" }
    public static func signatureName(version: String) -> String { zipName(version: version) + ".sig" }

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
        return PatchedRelease(version: version, pageURL: url, assets: assets(object["assets"], tag: tag, version: version))
    }

    /// The zip and signature, only when each appears exactly once under its exact name with exactly the
    /// download URL GitHub gives that name for this tag. Anything else (missing, duplicated, another host,
    /// path, tag or query) means no assets: the release stays notify-only.
    static func assets(_ value: Any?, tag: String, version: String) -> PatchedReleaseAssets? {
        guard let list = value as? [Any], list.count <= maxAssets else { return nil }
        let zip = zipName(version: version), sig = signatureName(version: version)
        var found: [String: [String]] = [:]
        for case let asset as [String: Any] in list {
            guard let name = asset["name"] as? String, name == zip || name == sig else { continue }
            found[name, default: []].append((asset["browser_download_url"] as? String) ?? "")
        }
        func exact(_ name: String) -> URL? {
            let expected = downloadBase + tag + "/" + name
            guard let urls = found[name], urls == [expected], let url = URL(string: expected),
                  url.scheme == "https", url.host == "github.com", url.absoluteString == expected else { return nil }
            return url
        }
        guard let zipURL = exact(zip), let sigURL = exact(sig) else { return nil }
        return PatchedReleaseAssets(zipURL: zipURL, signatureURL: sigURL)
    }

    /// `v1.2.3` or `1.2.3`: digits and single dots only after an optional "v".
    static func version(fromTag tag: String) -> String? {
        let body = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard body.range(of: "^[0-9]+(\\.[0-9]+)*\\z", options: .regularExpression) != nil else { return nil }
        return body
    }
}
