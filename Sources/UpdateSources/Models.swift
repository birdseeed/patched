import Foundation
import Darwin

/// Where an app's updates are published.
public enum UpdateSource: Sendable, Equatable {
    case sparkle(feed: URL)
    /// URL of the electron-builder `latest-mac.yml`.
    case electron(feed: URL)
    case homebrewCask(token: String)
    /// The Mac App Store. Only reports a version; Patched never installs these (`app_store_managed`).
    case appStore(trackID: Int)

    public var kind: String {
        switch self {
        case .sparkle: return "sparkle"
        case .electron: return "electron"
        case .homebrewCask: return "homebrew"
        case .appStore: return "appstore"
        }
    }
    public var isAppStore: Bool { if case .appStore = self { return true }; return false }
    /// The feed URL, or the cask token, for display.
    public var locator: String {
        switch self {
        case .sparkle(let feed), .electron(let feed): return feed.absoluteString
        case .homebrewCask(let token): return token
        case .appStore(let trackID): return "id\(trackID)"
        }
    }
}

/// Why an app has no update source. Stable raw values appear in JSON as `noSourceReason`.
public enum NoSourceReason: String, Sendable, Equatable, CaseIterable {
    /// Nothing public to check: no Sparkle/Electron feed, no matching Homebrew cask.
    case noPublicFeed = "no_public_feed"
    /// Patched itself, which is updated separately.
    case thisApp = "this_app"
    /// A Mac App Store app that the App Store lookup does not list (region, delisted, or a non-Mac listing).
    case appStoreNotListed = "app_store_not_listed"
    /// The catalogue says to ignore this app: nothing was looked up.
    case ignored = "ignored"

    public var text: String {
        switch self {
        case .noPublicFeed: return "no public update feed"
        case .thisApp: return "this app"
        case .appStoreNotListed: return "updates through the App Store (not in its public lookup)"
        case .ignored: return "ignored in the catalogue"
        }
    }
    public static let patchedBundleID = "im.patched.app"
}

/// Entry points for App Store updates, for the UI. `showUpdatesPage` is the long-standing `macappstore:`
/// scheme the App Store app registers (it lists macappstore/macappstores/itms-apps in its Info.plist); if a
/// future macOS stops honouring the path, open the App Store app by `bundleID` instead.
public enum AppStoreLinks {
    public static let updatesPageURL = URL(string: "macappstore://showUpdatesPage")!
    public static let appBundleID = "com.apple.AppStore"
    public static func appURL(trackID: Int) -> URL { URL(string: "macappstore://apps.apple.com/app/id\(trackID)")! }
}

public enum ArtifactFormat: String, Sendable, Equatable {
    case dmg, zip, pkg, tarball, unknown

    /// Infers the format from a download URL, falling back to a MIME type.
    public static func infer(from url: URL, mimeType: String? = nil) -> ArtifactFormat {
        let path = url.path.lowercased()
        if path.hasSuffix(".dmg") { return .dmg }
        if path.hasSuffix(".zip") { return .zip }
        if path.hasSuffix(".pkg") || path.hasSuffix(".mpkg") { return .pkg }
        for suffix in [".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz", ".tar"] where path.hasSuffix(suffix) {
            return .tarball
        }
        switch mimeType?.lowercased() {
        case "application/x-apple-diskimage"?: return .dmg
        case "application/zip"?, "application/x-zip-compressed"?: return .zip
        case "application/x-tar"?, "application/gzip"?, "application/x-gzip"?, "application/x-bzip2"?: return .tarball
        case "application/vnd.apple.installer+xml"?, "application/x-newton-compatible-pkg"?: return .pkg
        default: return .unknown
        }
    }
}

public struct UpdateOffer: Sendable, Equatable {
    public let displayVersion: String
    public let buildVersion: String?
    public let downloadURL: URL
    /// Lower-case hex.
    public let sha256: String?
    /// Base64, as published by electron-builder.
    public let sha512: String?
    /// Sparkle EdDSA signature (base64).
    public let edSignature: String?
    public let length: Int?
    public let minimumSystemVersion: String?
    /// Darwin kernel minimum, as published by electron-builder.
    public let minimumKernelVersion: String?
    public let format: ArtifactFormat
    public let source: UpdateSource

    public init(displayVersion: String, buildVersion: String? = nil, downloadURL: URL, sha256: String? = nil,
                sha512: String? = nil, edSignature: String? = nil, length: Int? = nil,
                minimumSystemVersion: String? = nil, minimumKernelVersion: String? = nil, format: ArtifactFormat, source: UpdateSource) {
        self.displayVersion = displayVersion; self.buildVersion = buildVersion; self.downloadURL = downloadURL
        self.sha256 = sha256; self.sha512 = sha512; self.edSignature = edSignature; self.length = length
        self.minimumSystemVersion = minimumSystemVersion; self.minimumKernelVersion = minimumKernelVersion; self.format = format; self.source = source
    }
}

/// Why an app could not be checked. Every case carries a stable `code` and a human-readable `message`.
public enum RefusalReason: Error, Sendable, Equatable {
    case insecureFeed(String)
    case insecureRedirect(String)
    case insecureDownload(String)
    case malformedFeed(String)
    case tooLarge
    case noCompatibleItem
    case unversioned(String)
    case missingInstalledVersion
    case invalidSource(String)
    case network(String)
    /// The server could not be reached at all (no connection, DNS failure, timeout, connection lost). Unlike
    /// `network` (which includes HTTP errors such as 404), this says nothing about the feed itself.
    case offline(String)
    /// Not a failure: the update exists but the App Store owns installing it.
    case appStoreManaged
    /// Apple returned conflicting App Store listings for one bundle ID.
    case lookupConflict(String)

    public var code: String {
        switch self {
        case .insecureFeed: return "insecure_feed"
        case .insecureRedirect: return "insecure_redirect"
        case .insecureDownload: return "insecure_download"
        case .malformedFeed: return "malformed_feed"
        case .tooLarge: return "too_large"
        case .noCompatibleItem: return "no_compatible_item"
        case .unversioned: return "unversioned"
        case .missingInstalledVersion: return "missing_installed_version"
        case .invalidSource: return "invalid_source"
        case .network: return "network"
        case .offline: return "offline"
        case .appStoreManaged: return "app_store_managed"
        case .lookupConflict: return "lookup_conflict"
        }
    }
    public var message: String {
        switch self {
        case .insecureFeed(let detail): return "insecure feed: \(detail)"
        case .insecureRedirect(let detail): return "refused redirect to a non-https URL: \(detail)"
        case .insecureDownload(let detail): return "insecure download URL: \(detail)"
        case .malformedFeed(let detail): return "malformed feed: \(detail)"
        case .tooLarge: return "feed larger than the allowed size"
        case .noCompatibleItem: return "no compatible release in the feed"
        case .unversioned(let detail): return "unversioned: \(detail)"
        case .missingInstalledVersion: return "installed app has no readable version"
        case .invalidSource(let detail): return "invalid update source: \(detail)"
        case .network(let detail): return "network error: \(detail)"
        case .offline(let detail): return "couldn't reach the server: \(detail)"
        case .appStoreManaged: return "Update in the App Store"
        case .lookupConflict(let detail): return "conflicting App Store listings: \(detail)"
        }
    }
}

public enum CheckResult: Sendable, Equatable {
    case upToDate
    case updateAvailable(UpdateOffer)
    case noSource
    case refused(RefusalReason)
}

/// The host the check is running on; decides arch- and OS-specific choices.
public struct HostEnvironment: Sendable, Equatable {
    public enum Arch: String, Sendable { case arm64, x86_64 }
    public let arch: Arch
    /// Dotted, e.g. "15.1" or "27.0.1".
    public let osVersion: String

    public let kernelVersion: String
    public init(arch: Arch, osVersion: String, kernelVersion: String = HostEnvironment.currentKernelVersion) {
        self.arch = arch; self.osVersion = osVersion; self.kernelVersion = kernelVersion
    }
    public static var currentKernelVersion: String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        return withUnsafeBytes(of: &info.release) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public static var current: HostEnvironment {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = Arch.arm64
        #else
        let arch = Arch.x86_64
        #endif
        return HostEnvironment(arch: arch, osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }
    public var osMajor: Int { Int(osVersion.split(separator: ".").first ?? "") ?? 0 }
}

/// What the resolvers need to know about an installed app.
public struct InstalledApp: Sendable, Equatable {
    public let name: String
    public let path: String
    public let bundleID: String?
    public let shortVersion: String?
    public let build: String?
    /// `SUFeedURL` from Info.plist, if present.
    public let sparkleFeed: String?
    /// The scanner saw an `SUFeedURL` that is not a plain https URL.
    public let sparkleFeedRejected: Bool
    /// Raw `Contents/Resources/app-update.yml`.
    public let electronConfig: Data?
    /// Installed from the Mac App Store (has `Contents/_MASReceipt`); the App Store owns its updates.
    public let isAppStore: Bool
    /// An iPhone/iPad app installed from the App Store on Apple silicon (`Wrapper/*.app` and `iTunesMetadata.plist`,
    /// no `Contents`). The App Store owns it, so `isAppStore` is always true for these; its installed version is the
    /// iOS version, so an iOS listing can be compared with it directly.
    public let isWrappedIOSApp: Bool
    /// `SUPublicEDKey` as the installer reads it (nil when absent, "" when not a string). A key means every offer needs a valid EdDSA signature.
    public let sparklePublicEDKey: String?
    public var pinsSparkleKey: Bool { sparklePublicEDKey != nil }

    public init(name: String, path: String, bundleID: String?, shortVersion: String?, build: String?,
                sparkleFeed: String? = nil, sparkleFeedRejected: Bool = false, electronConfig: Data? = nil,
                isAppStore: Bool = false, isWrappedIOSApp: Bool = false, sparklePublicEDKey: String? = nil) {
        self.sparklePublicEDKey = sparklePublicEDKey
        self.isAppStore = isAppStore || isWrappedIOSApp
        self.isWrappedIOSApp = isWrappedIOSApp
        self.name = name; self.path = path; self.bundleID = bundleID
        self.shortVersion = shortVersion; self.build = build
        self.sparkleFeed = sparkleFeed; self.sparkleFeedRejected = sparkleFeedRejected
        self.electronConfig = electronConfig
    }
    /// File name of the bundle, e.g. "Foo.app".
    public var bundleFileName: String { (path as NSString).lastPathComponent }
}

extension URL {
    var isHTTPS: Bool { scheme?.lowercased() == "https" && host?.isEmpty == false }
}
