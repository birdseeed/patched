import Foundation
import AppKit
import UpdateSources
import UpdateInstaller

// Everything Patched opens outside itself (the App Store, the support links) goes through one seam, so
// tests record the request instead of opening anything. Only an explicit click may reach it: a row's
// Open in App Store button, Update All (window, menu or notification button) and the Help & Support links.
// The scheduler never holds an opener.

/// Opens a URL, or an app by bundle identifier, in the user's session. Both return false when nothing was opened.
@MainActor public protocol ExternalURLOpening: AnyObject {
    func open(_ url: URL) -> Bool
    /// Resolves once the launch has actually succeeded or failed.
    func openApplication(bundleID: String) async -> Bool
    /// Opens the app bundle at this installed path, but only if it is still the app the row was built from
    /// (same bundle ID, and same Team ID when one was observed). Only a direct click on a row may reach it.
    func openApplication(atPath path: String, expectedBundleID: String, expectedTeamID: String?) async -> AppOpenResult
}

/// `changed` means the bundle at the path is no longer the one that was checked: nothing was launched.
public enum AppOpenResult: Equatable, Sendable { case opened, changed, failed }

/// The check made immediately before an installed app is launched from a row. Pure of side effects.
public enum InstalledAppRevalidation {
    /// True only when `path` is itself a directory (not a symlink) named `*.app` whose Info.plist bundle ID equals
    /// `bundleID` and, when `teamID` is given, whose code signature is valid and pinned to that Team ID (the
    /// installer's own strict, nested-code check; merely reading the signature would trust unvalidated metadata).
    /// With no Team ID on the row (an unsigned or ad-hoc app) only the symlink, bundle and bundle ID checks apply.
    public static func isStillTheSameApp(path: String, bundleID: String, teamID: String?,
                                         verifier: any CodeVerifying = SystemCodeVerifier()) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, path.hasSuffix(".app") else { return false }
        let plist = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Contents/Info.plist")
        var plistInfo = stat()
        guard lstat(plist.path, &plistInfo) == 0, plistInfo.st_mode & S_IFMT == S_IFREG, plistInfo.st_size <= 1_048_576,
              let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any], dict["CFBundleIdentifier"] as? String == bundleID else { return false }
        if let teamID {
            do { try verifier.verifySignature(ofBundleAt: path, teamID: teamID) } catch { return false }
        }
        return true
    }
}

/// The default for controllers built without an opener (fixtures, previews): opens nothing.
@MainActor public final class InertURLOpener: ExternalURLOpening {
    public init() {}
    public func open(_ url: URL) -> Bool { false }
    public func openApplication(bundleID: String) async -> Bool { false }
    public func openApplication(atPath path: String, expectedBundleID: String, expectedTeamID: String?) async -> AppOpenResult { .failed }
}

/// `NSWorkspace` in production. Refuses under the real-state tripwire, so no test run opens a real URL.
@MainActor public final class WorkspaceURLOpener: ExternalURLOpening {
    private let verifier: any CodeVerifying
    private let launcher: (@MainActor (URL) async -> Bool)?
    public init() { verifier = SystemCodeVerifier(); launcher = nil }
    /// Checks only: a fake verifier and a fake launcher, so nothing real is validated or opened.
    @_spi(Testing) public init(verifier: any CodeVerifying, launcher: @escaping @MainActor (URL) async -> Bool) {
        self.verifier = verifier; self.launcher = launcher
    }
    public func open(_ url: URL) -> Bool {
        if RealStateTripwire.isActive { return false }
        return NSWorkspace.shared.open(url)
    }
    public func openApplication(bundleID: String) async -> Bool {
        if RealStateTripwire.isActive { return false }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }
}

extension WorkspaceURLOpener {
    public func openApplication(atPath path: String, expectedBundleID: String, expectedTeamID: String?) async -> AppOpenResult {
        if launcher == nil && RealStateTripwire.isActive { return .failed }
        // Revalidated immediately before the launch: a replaced or relinked bundle is never opened.
        guard InstalledAppRevalidation.isStillTheSameApp(path: path, bundleID: expectedBundleID, teamID: expectedTeamID,
                                                         verifier: verifier) else { return .changed }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if let launcher { return await launcher(url) ? .opened : .failed }
        let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
        return opened ? .opened : .failed
    }
}

extension ExternalURLOpening {
    /// Opens the App Store's Updates page; if that fails, the App Store app itself.
    func openAppStoreUpdates() async -> Bool {
        if open(AppStoreLinks.updatesPageURL) { return true }
        return await openApplication(bundleID: AppStoreLinks.appBundleID)
    }
}

/// Public places Patched can point to.
public enum PublicLinks {
    public static let coffee = URL(string: "https://buymeacoffee.com/andybridson")!
    /// The public repository. Help & Support links to its issue tracker ("Report a problem") and to the source;
    /// both open only on a click. Nil would hide those two links.
    public static let repository: URL? = URL(string: "https://github.com/birdseeed/patched")
    /// Help & Support's "Contact the developer": opens a new email in the user's mail app, only on a click.
    public static let contact = URL(string: "mailto:hello@patched.im?subject=Patched")!
}

/// What the Help & Support screen shows. Pure, so it can be checked without a window.
public struct SupportContent: Equatable, Sendable {
    public struct Link: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let url: URL
    }
    public let heading: String
    public let about: String
    public let links: [Link]

    public static func make(repository: URL? = PublicLinks.repository, coffee: URL = PublicLinks.coffee,
                            contact: URL = PublicLinks.contact) -> SupportContent {
        var links = [Link(title: String(localized: "Buy me a coffee"),
                          detail: String(localized: "Donations help pay for the Apple Developer membership that signs and notarises each release."), url: coffee)]
        if let repository {
            links.append(Link(title: String(localized: "Report a problem"), detail: String(localized: "Opens the issue tracker."),
                              url: repository.appendingPathComponent("issues")))
        }
        links.append(Link(title: String(localized: "Contact the developer"), detail: String(localized: "Opens an email to hello@patched.im."), url: contact))
        if let repository {
            links.append(Link(title: String(localized: "Source code"), detail: String(localized: "The Patched repository."), url: repository))
        }
        return SupportContent(
            heading: String(localized: "Help & Support"),
            about: String(localized: "Patched is a free, open source community project, licensed under the GNU General Public Licence, version 3 only. There is no company behind it and no support team, but if something goes wrong, report it or email the developer below and we'll do our best to help."),
            links: links)
    }
}
