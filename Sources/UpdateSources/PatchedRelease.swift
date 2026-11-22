import Foundation

/// The two release files self-update needs: the zip and its Ed25519 signature. Each URL is exactly
/// `https://github.com/birdseeed/patched/releases/download/<tag>/<name>`, with the names
/// `Patched-<version>.zip` and `Patched-<version>.zip.sig`. Where they point is not trusted: the zip is only
/// installed if the signature verifies against the release key built into Patched.
public struct PatchedReleaseAssets: Equatable, Sendable {
    public let zipURL: URL
    public let signatureURL: URL
    /// What GitHub says the two files are, beyond their names: each asset's numeric `id` and, when GitHub gives one,
    /// its `digest`. Uploading a different file under the same name gives it a new id (and digest), so the automatic
    /// self-update's 24-hour wait starts again. Untrusted and only compared for equality; it is never used to fetch or
    /// verify anything. nil when either file has no valid id, or carries a digest that is not well formed: such a
    /// release can still be installed with a click, never automatically.
    public let fingerprint: String?
    public init(zipURL: URL, signatureURL: URL, fingerprint: String? = nil) {
        self.zipURL = zipURL; self.signatureURL = signatureURL; self.fingerprint = fingerprint
    }
}

/// A newer Patched release, as announced by GitHub's "latest release" record. Patched shows the version and,
/// on a click, opens the validated release page. When the release also carries its signed zip (`assets`), an
/// explicit, confirmed click can install it (see `SelfUpdater`). The only other path is the opt-in "Also update
/// Patched itself" daily run, through the same `SelfUpdater` and checks, for a version known on this Mac for 24 hours.
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
    /// No release (404), an older or equal one, or a draft or prerelease.
    case noNews
    /// The request failed (offline, server error), or the record could not be read or failed validation.
    /// Says nothing about whether there is news.
    case unavailable
}

/// Reads `GET https://api.github.com/repos/birdseeed/patched/releases/latest`. The record is untrusted: only
/// `tag_name`, `html_url`, `draft`, `prerelease` and each asset's `name`, `browser_download_url`, `id` and `digest`
/// are read (the last two only for the zip and signature, as their fingerprint).
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

    /// Pure: the record's bytes against the running version. A draft or prerelease, or a valid release that is
    /// not newer, is no news. A record Patched cannot read or validate says nothing (`.unavailable`), so it never
    /// counts as the release having gone (which would restart the automatic self-update's wait).
    public static func evaluate(_ data: Data, currentVersion: String) -> PatchedReleaseResult {
        guard let release = parse(data) else {
            if data.count <= FetchLimits.releaseBytes,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return .noNews }
            return .unavailable
        }
        return VersionComparator.isNewer(release.version, than: currentVersion) ? .newer(release) : .noNews
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
        var marks: [String: String?] = [:]
        for case let asset as [String: Any] in list {
            guard let name = asset["name"] as? String, name == zip || name == sig else { continue }
            found[name, default: []].append((asset["browser_download_url"] as? String) ?? "")
            marks[name] = mark(asset)
        }
        func exact(_ name: String) -> URL? {
            let expected = downloadBase + tag + "/" + name
            guard let urls = found[name], urls == [expected], let url = URL(string: expected),
                  url.scheme == "https", url.host == "github.com", url.absoluteString == expected else { return nil }
            return url
        }
        guard let zipURL = exact(zip), let sigURL = exact(sig) else { return nil }
        // Each name appears exactly once here, so each mark is that one asset's.
        var fingerprint: String?
        if let zipMark = marks[zip] ?? nil, let sigMark = marks[sig] ?? nil { fingerprint = "zip=" + zipMark + ";sig=" + sigMark }
        return PatchedReleaseAssets(zipURL: zipURL, signatureURL: sigURL, fingerprint: fingerprint)
    }

    /// One asset's `id`, plus its `digest` when present: "123" or "123@sha256:<64 hex>". The id must be a JSON
    /// integer from 1 to 2^53 (not a boolean, fraction or string). A digest, when present, must be exactly
    /// "sha256:" and 64 lowercase hex digits. nil otherwise: no fingerprint.
    static func mark(_ asset: [String: Any]) -> String? {
        guard let number = asset["id"] as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(), !CFNumberIsFloatType(number as CFNumber) else {
            return nil
        }
        let id = number.int64Value
        guard id > 0, id <= 1 << 53, number.stringValue == String(id) else { return nil }
        guard let value = asset["digest"], !(value is NSNull) else { return String(id) }
        guard let digest = value as? String, digest.utf8.count == 71, digest.hasPrefix("sha256:"),
              digest.utf8.dropFirst(7).allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) })
        else { return nil }
        return String(id) + "@" + digest
    }

    /// `v1.2.3` or `1.2.3`: digits and single dots only after an optional "v".
    static func version(fromTag tag: String) -> String? {
        let body = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard body.range(of: "^[0-9]+(\\.[0-9]+)*\\z", options: .regularExpression) != nil else { return nil }
        return body
    }
}
