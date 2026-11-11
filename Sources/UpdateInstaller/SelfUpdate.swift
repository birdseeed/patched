import Foundation
import CryptoKit
import Darwin
import Security
import UpdateSources

// Patched updating itself, on an explicit and confirmed click only.
//
// The first trust anchor is Patched's own Ed25519 release key: every release zip is signed with it
// (scripts/release.sh), and the public half is built into the app below. A zip is only unpacked when its
// signature verifies against that key. The normal installer still refuses Patched, so this is its own path.
//
// The second is the release Team ID, `PatchedReleaseTeamID` in the running app's own Info.plist (written by
// scripts/build-app.sh from RELEASE_TEAM_ID, and covered by the app's code signature). It is never read from
// the download. When it is empty (ad-hoc and development builds, up to and including 0.1.6) nothing more is
// checked, so 0.1.6 accepts 0.1.7 on the Ed25519 key alone. When it is set (Developer ID releases, from 0.1.7
// on), the new app must also be notarised, signed with Developer ID Application by exactly that team, and pin
// the same team itself, so an ad-hoc or other-team download is refused even when its zip carries a valid
// release signature. A pin that is not a
// well-formed Team ID refuses every self-update rather than counting as "no pin".
// See THREAT-MODEL.md, "Patched updating itself".

/// The release-signing key Patched trusts for its own updates, and the bundle it may replace.
public enum PatchedReleaseKey {
    /// Raw 32-byte Curve25519 signing public key, base64. The private half never leaves the owner's Keychain.
    public static let publicKeyBase64 = "3pXCQuK7pRsCXKXhXwld3tJw+yisZpSMKef3OjEsk/k="
    public static let bundleID = "im.patched.app"
    /// The Info.plist key holding the Developer ID Team ID that future releases must be signed by.
    public static let teamIDInfoKey = "PatchedReleaseTeamID"
}

/// The release Team ID this copy of Patched pins its own updates to, from its own Info.plist.
public enum ReleaseTeamPin: Sendable, Equatable {
    /// No pin (key absent or empty): an ad-hoc or development build. Self-update relies on the release key alone.
    case none
    /// A well-formed Team ID: the new Patched must be Developer ID Application signed by this team.
    case team(String)
    /// Present but not a Team ID. Every self-update is refused; this is never treated as `none`.
    case malformed(String)

    /// The running app's pin. Read from `Bundle.main`'s unlocalised Info.plist, never from a download.
    public static var running: ReleaseTeamPin { from(bundle: .main) }

    public static func from(bundle: Bundle) -> ReleaseTeamPin {
        from(infoValue: bundle.infoDictionary?[PatchedReleaseKey.teamIDInfoKey])
    }

    public static func from(infoValue: Any?) -> ReleaseTeamPin {
        guard let value = infoValue else { return .none }
        guard let text = value as? String else { return .malformed("the value is not text") }
        if text.isEmpty { return .none }
        return TeamIdentifier.isValid(text) ? .team(text) : .malformed(String(text.prefix(40)))
    }

    /// The one source of the release requirement. scripts/release.sh reads this exact line (with sed) and checks
    /// every Developer ID release against it before writing anything, so keep it on one line and unchanged in form.
    /// Patched's signing identifier, Apple's anchor, the Developer ID intermediate (1.2.840.113635.100.6.2.6), a
    /// Developer ID Application leaf (1.2.840.113635.100.6.1.13), the leaf's team, and a notarisation ticket.
    public static let requirementTemplate = "identifier \"@IDENTIFIER@\" and anchor apple generic and certificate leaf[subject.OU] = \"@TEAM@\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized"

    /// The code requirement a release signed by `team` satisfies (`requirementTemplate`). `team` and `identifier`
    /// are validated first, so nothing can be injected.
    public static func requirement(team: String, identifier: String = PatchedReleaseKey.bundleID) throws -> String {
        guard TeamIdentifier.isValid(team) else {
            throw InstallRefusal.cannotPinIdentity("Patched's release Team ID \"\(team.prefix(40))\" is not a valid Apple Team ID")
        }
        guard !identifier.isEmpty, identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                                                                || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }) else {
            throw InstallRefusal.signatureInvalid("signing identifier \"\(identifier.prefix(80))\" cannot be put in a requirement")
        }
        return requirementTemplate.replacingOccurrences(of: "@IDENTIFIER@", with: identifier)
            .replacingOccurrences(of: "@TEAM@", with: team)
    }
}

/// Ed25519 over the exact zip bytes, as Sparkle does. The `.sig` file is the 64-byte signature in base64 on
/// one line.
public enum ReleaseSignature {
    /// Throws `releaseSignatureInvalid` unless `signatureText` is one base64 signature that verifies over `archive`.
    public static func verify(signatureText: String, archive: Data, publicKeyBase64: String) throws {
        guard let keyBytes = Data(base64Encoded: publicKeyBase64), keyBytes.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw InstallRefusal.releaseSignatureInvalid("the release public key is malformed")
        }
        let text = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InstallRefusal.releaseSignatureInvalid("the release has no signature") }
        guard !text.contains(where: \.isWhitespace), let signature = Data(base64Encoded: text), signature.count == 64 else {
            throw InstallRefusal.releaseSignatureInvalid("the release signature is not 64 base64-encoded bytes")
        }
        guard key.isValidSignature(signature, for: archive) else {
            throw InstallRefusal.releaseSignatureInvalid("the release signature does not match the download")
        }
    }

    /// As above, reading both files. The signature file may be at most `SelfUpdateLimits.signatureBytes`.
    public static func verify(signatureFile: String, archivePath: String, publicKeyBase64: String) throws {
        guard let data = FileSafety.readSmallFile(signatureFile, limit: Int(SelfUpdateLimits.signatureBytes)) else {
            throw InstallRefusal.releaseSignatureInvalid("the release signature is missing or too large")
        }
        let archive: Data
        do { archive = try Data(contentsOf: URL(fileURLWithPath: archivePath), options: [.alwaysMapped]) }
        catch { throw InstallRefusal.io("cannot read the download for signature checking") }
        try verify(signatureText: String(decoding: data, as: UTF8.self), archive: archive, publicKeyBase64: publicKeyBase64)
    }
}

public enum SelfUpdateLimits {
    /// Patched's zip is about 3 MB; anything near this is not a Patched release.
    public static let zipBytes: Int64 = 64 * 1024 * 1024
    public static let signatureBytes: Int64 = 1024
    /// Where a release download may go. `github.com` serves the asset URL itself and answers with a 302 to
    /// `release-assets.githubusercontent.com` (seen on 9 November 2026 for Patched-0.1.2.zip); older releases
    /// redirected to `objects.githubusercontent.com`. Every hop must be https and on this list.
    public static let downloadHosts: Set<String> = ["github.com", "release-assets.githubusercontent.com",
                                                    "objects.githubusercontent.com"]
    /// Unpacking budget, sized for a small app rather than the multi-gigabyte vendor budget.
    public static let unpackBudget = UnpackBudget(reserveBytes: 512 * 1024 * 1024, reservePerDownloadByte: 4,
                                                  maxStagedFloor: 1024 * 1024 * 1024, maxStagedPerDownloadByte: 8,
                                                  minFreeDuring: 256 * 1024 * 1024, maxEntries: 50_000)
}

/// Where a self-update has got to, for the menu's progress line. Steps only move forward.
public enum SelfUpdateStep: Int, Sendable, Comparable {
    case downloading, verifying, installing
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct SelfUpdateReport: Sendable, Equatable {
    public let appPath: String
    public let fromVersion: String
    public let toVersion: String
    /// The previous version, kept until the next self-update. nil when it could not be kept (see `note`).
    public let backupPath: String?
    public let note: String?
    public init(appPath: String, fromVersion: String, toVersion: String, backupPath: String?, note: String?) {
        self.appPath = appPath; self.fromVersion = fromVersion; self.toVersion = toVersion; self.backupPath = backupPath; self.note = note
    }
}

/// Replaces the running Patched with a signed release. Every step fails closed; until the one atomic swap
/// the installed app is never touched, and a new app that fails its checks after the swap is swapped back.
/// The Ed25519 signature over the zip, against the key built into this app, is what makes the download
/// trusted. When this app pins a release Team ID (`ReleaseTeamPin`), the new app must also be signed with
/// Developer ID Application by that team (`teamCheck`); with no pin (an ad-hoc build) there is no Team ID to check.
public struct SelfUpdater: Sendable {
    /// The running app's bundle (`Bundle.main.bundlePath`).
    public let appPath: String
    /// The running app's `CFBundleShortVersionString`. The release must be strictly newer.
    public let runningVersion: String
    /// The installer's backups folder; the previous Patched goes in `<backups>/im.patched.app`.
    public let backupsRoot: String
    let downloader: any ArtifactDownloading
    let codeCheck: @Sendable (String) throws -> Void
    /// The running app's release Team ID pin. Only `.team` runs `teamCheck`; `.malformed` refuses everything.
    let teamPin: ReleaseTeamPin
    /// `(path, team)`: the bundle at `path` must be Developer ID Application signed by `team`.
    let teamCheck: @Sendable (String, String) throws -> Void
    let publicKey: String
    let uid: uid_t

    /// Production: the embedded release key, the running app's own Team ID pin, GitHub-only downloads,
    /// `codesign --verify --strict --deep` and, when pinned, the Developer ID requirement.
    public init(appPath: String, runningVersion: String, backupsRoot: String,
                downloader: any ArtifactDownloading = URLSessionArtifactDownloader(allowedHosts: SelfUpdateLimits.downloadHosts),
                codeCheck: @escaping @Sendable (String) throws -> Void = SelfUpdater.verifyCodeSignature,
                uid: uid_t = geteuid()) {
        self.init(productionWith: .main, appPath: appPath, runningVersion: runningVersion, backupsRoot: backupsRoot,
                  downloader: downloader, codeCheck: codeCheck, uid: uid)
    }

    /// The production wiring, with the bundle whose Info.plist holds the pin made explicit so the checks can prove
    /// it: the pin is that bundle's own (the running app's, from the public initialiser) and the team check is the
    /// real `verifyReleaseTeam`.
    @_spi(Testing) public init(productionWith bundle: Bundle, appPath: String, runningVersion: String, backupsRoot: String,
                               downloader: any ArtifactDownloading, codeCheck: @escaping @Sendable (String) throws -> Void,
                               uid: uid_t) {
        self.init(appPath: appPath, runningVersion: runningVersion, backupsRoot: backupsRoot, downloader: downloader,
                  codeCheck: codeCheck, uid: uid, publicKey: PatchedReleaseKey.publicKeyBase64,
                  teamPin: ReleaseTeamPin.from(bundle: bundle), teamCheck: { try SelfUpdater.verifyReleaseTeam($0, team: $1) })
    }

    @_spi(Testing) public var teamPinForTesting: ReleaseTeamPin { teamPin }
    @_spi(Testing) public var teamCheckForTesting: @Sendable (String, String) throws -> Void { teamCheck }

    /// Checks only: a throwaway key, because the real private key is never used in tests, and an explicit pin
    /// and team check (no pin unless a check asks for one).
    @_spi(Testing) public init(appPath: String, runningVersion: String, backupsRoot: String, downloader: any ArtifactDownloading,
                               codeCheck: @escaping @Sendable (String) throws -> Void, uid: uid_t = geteuid(), publicKey: String,
                               teamPin: ReleaseTeamPin = .none,
                               teamCheck: @escaping @Sendable (String, String) throws -> Void = { try SelfUpdater.verifyReleaseTeam($0, team: $1) }) {
        self.appPath = appPath; self.runningVersion = runningVersion; self.backupsRoot = backupsRoot
        self.downloader = downloader; self.codeCheck = codeCheck; self.uid = uid; self.publicKey = publicKey
        self.teamPin = teamPin; self.teamCheck = teamCheck
    }

    var parent: String { (appPath as NSString).deletingLastPathComponent }
    var appName: String { (appPath as NSString).lastPathComponent }

    // MARK: Preconditions

    /// The running bundle must be a real, user-replaceable Patched.app. Read-only. Anything that would need
    /// admin rights throws `needsAdmin`; the app then opens the release page instead.
    public func preflight() throws -> BundleFacts {
        guard appPath.hasSuffix(".app"), appPath.hasPrefix("/") else {
            throw InstallRefusal.unsafePath("Patched is not running from an app bundle (\(appPath))")
        }
        if appPath.contains("/AppTranslocation/") {
            throw InstallRefusal.needsAdmin("Patched is running from a read-only copy macOS made; move Patched to Applications and open it from there")
        }
        try FileSafety.requireNoSymlinks(appPath)
        guard let info = FileSafety.lstatInfo(appPath), FileSafety.isDirectory(info) else {
            throw InstallRefusal.unsafePath("\(appPath) is not a directory")
        }
        let facts = try BundleFacts.read(bundleAt: appPath)
        guard facts.bundleID == PatchedReleaseKey.bundleID else {
            throw InstallRefusal.unsafePath("\(appPath) is \(facts.bundleID), not Patched")
        }
        if info.st_flags & UInt32(SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE) != 0 {
            throw InstallRefusal.needsAdmin("\(appPath) is protected by file flags")
        }
        try FileSafety.requireTreeOwned(by: uid, appPath)
        if info.st_mode & 0o200 == 0 { throw InstallRefusal.needsAdmin("\(appPath) is not writable by its owner") }
        guard let parentInfo = FileSafety.lstatInfo(parent), FileSafety.isDirectory(parentInfo) else {
            throw InstallRefusal.unsafePath("\(parent) is not a directory")
        }
        if access(parent, W_OK | X_OK) != 0 { throw InstallRefusal.needsAdmin("\(parent) is not writable by this user") }
        if parentInfo.st_mode & S_ISVTX != 0 && parentInfo.st_uid != uid && info.st_uid != uid {
            throw InstallRefusal.needsAdmin("\(parent) is sticky and Patched belongs to someone else")
        }
        return facts
    }

    // MARK: The whole update

    /// Download, signature, unpack, staged checks, swap, re-check, backup. Returns once the new Patched is in
    /// place and verified; relaunching is a separate step (`relaunch`).
    public func install(_ release: PatchedRelease, progress: @escaping @Sendable (SelfUpdateStep) -> Void = { _ in }) async throws -> SelfUpdateReport {
        guard let assets = release.assets else {
            throw InstallRefusal.notInstallable("Patched \(release.version) has no signed download; use the release page")
        }
        // A damaged pin could never accept anything, so it is refused before anything is downloaded.
        try Self.requireUsablePin(teamPin)
        try Self.checkAssetURL(assets.zipURL, name: PatchedReleaseChecker.zipName(version: release.version))
        try Self.checkAssetURL(assets.signatureURL, name: PatchedReleaseChecker.signatureName(version: release.version))
        guard VersionComparator.isNewer(release.version, than: runningVersion) else {
            throw InstallRefusal.notNewer("\(release.version) is not newer than the running Patched \(runningVersion)")
        }
        let installed = try preflight()
        guard let oldIdentity = FileSafety.directoryIdentity(appPath) else { throw InstallRefusal.unsafePath("cannot read \(appPath)") }
        if let short = installed.shortVersion, !VersionComparator.isNewer(release.version, than: short) {
            throw InstallRefusal.notNewer("\(release.version) is not newer than the installed Patched \(short)")
        }

        // One private folder beside the app (same volume, so the swap is a single rename). Nothing in it is
        // trusted until the signature has verified.
        let work = parent + "/" + Self.workFolderPrefix + UUID().uuidString
        try FileSafety.makeFreshPrivateDirectory(work)
        var swapped = false
        do {
            guard FileSafety.directoryIdentity(work)?.device == oldIdentity.device else {
                throw InstallRefusal.unsafePath("the staging folder is not on the same volume as \(appPath)")
            }
            progress(.downloading)
            let zipPath = work + "/" + PatchedReleaseChecker.zipName(version: release.version)
            let sigPath = zipPath + ".sig"
            let zipBytes = try await fetch(assets.zipURL, to: zipPath, maxBytes: SelfUpdateLimits.zipBytes)
            do { _ = try await fetch(assets.signatureURL, to: sigPath, maxBytes: SelfUpdateLimits.signatureBytes) }
            catch InstallRefusal.download(let detail) { throw InstallRefusal.releaseSignatureInvalid("the release signature could not be downloaded (\(detail))") }

            progress(.verifying)
            try ReleaseSignature.verify(signatureFile: sigPath, archivePath: zipPath, publicKeyBase64: publicKey)

            let budget = SelfUpdateLimits.unpackBudget
            try budget.preflight(volume: work, downloadBytes: zipBytes)
            let unpacked = work + "/unpacked"
            try FileSafety.makeFreshPrivateDirectory(unpacked)
            try Unpacker.extractZip(zipPath, into: unpacked, budget: budget, downloadBytes: zipBytes)
            let chosen = try BundleSelector.select(in: unpacked, bundleID: PatchedReleaseKey.bundleID)
            let staged = work + "/" + appName
            guard rename(chosen, staged) == 0 else { throw InstallRefusal.io("cannot move the unpacked app into place") }
            try verifyStaged(staged, version: release.version, installed: installed)
            Self.removeQuarantine(staged)
            guard let newIdentity = FileSafety.directoryIdentity(staged) else { throw InstallRefusal.io("cannot read \(staged)") }

            progress(.installing)
            guard FileSafety.directoryIdentity(appPath) == oldIdentity else {
                throw InstallRefusal.io("Patched changed on disk while the update was being prepared")
            }
            let swapError = renamex_np(staged, appPath, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
            guard swapError == 0 else { throw InstallRefusal.swapFailed("renamex_np: \(String(cString: strerror(swapError)))") }
            swapped = true
            // The old app is now at `staged`. What is installed must be the verified new bundle.
            do {
                guard FileSafety.directoryIdentity(appPath) == newIdentity else {
                    throw InstallRefusal.verificationFailedAfterSwap("the installed bundle is not the one that was checked")
                }
                try verifyStaged(appPath, version: release.version, installed: installed)
            } catch {
                let refusal = (error as? InstallRefusal) ?? .signatureInvalid("\(error)")
                try swapBack(staged: staged, oldIdentity: oldIdentity, installed: installed, because: refusal)
                swapped = false
                throw InstallRefusal.verificationFailedAfterSwap(refusal.message + "; the previous Patched was put back")
            }
            let (backup, note) = keepBackup(old: staged, work: work)
            return SelfUpdateReport(appPath: appPath, fromVersion: installed.shortVersion ?? runningVersion,
                                    toVersion: release.version, backupPath: backup, note: note)
        } catch {
            // Before the swap (or after a verified swap back) the installed app is the old one, untouched:
            // everything staged goes. After an unexplained swap failure nothing is deleted.
            if !swapped { try? FileSafety.removeTree(work, within: parent) }
            throw error
        }
    }

    /// Bundle ID, contained symlinks, exact version, strictly newer, the code signature, then (when pinned) the
    /// Developer ID team.
    func verifyStaged(_ path: String, version: String, installed: BundleFacts) throws {
        guard let info = FileSafety.lstatInfo(path), FileSafety.isDirectory(info) else {
            throw InstallRefusal.unsafePath("the new Patched is not a directory")
        }
        let facts = try BundleFacts.read(bundleAt: path)
        guard facts.bundleID == PatchedReleaseKey.bundleID else {
            throw InstallRefusal.bundleNotFound("the download's bundle ID is \(facts.bundleID), not \(PatchedReleaseKey.bundleID)")
        }
        try FileSafety.requireContainedSymlinks(path)
        guard facts.shortVersion == version else {
            throw InstallRefusal.versionMismatch("the release is \(version) but the download contains \(facts.shortVersion ?? "no version")")
        }
        // Replay of an older, genuinely signed zip is stopped here.
        guard VersionComparator.isNewer(version, than: runningVersion),
              installed.shortVersion.map({ VersionComparator.isNewer(version, than: $0) }) ?? true else {
            throw InstallRefusal.notNewer("\(version) is not newer than Patched \(installed.shortVersion ?? runningVersion)")
        }
        try codeCheck(path)
        switch teamPin {
        case .none: break
        case .team(let team):
            try teamCheck(path, team)
            // A release cannot drop or change the pin: the new app must pin the same team as this one.
            let stagedPin = Self.pin(inInfoPlistOf: path)
            guard stagedPin == teamPin else {
                let shown: String
                switch stagedPin {
                case .none: shown = "no Team ID"
                case .team(let other): shown = "team \(other)"
                case .malformed(let value): shown = "a malformed Team ID (\(value))"
                }
                throw InstallRefusal.releaseTeamMismatch("the new Patched pins \(shown) instead of team \(team)")
            }
        case .malformed: try Self.requireUsablePin(teamPin)
        }
    }

    /// The pin in a bundle's Info.plist, read from the file itself (never through `Bundle`, which caches by path).
    static func pin(inInfoPlistOf path: String) -> ReleaseTeamPin {
        guard let data = FileSafety.readSmallFile(path + "/Contents/Info.plist", limit: 1024 * 1024),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return .malformed("unreadable Info.plist")
        }
        return ReleaseTeamPin.from(infoValue: plist[PatchedReleaseKey.teamIDInfoKey])
    }

    static func requireUsablePin(_ pin: ReleaseTeamPin) throws {
        if case .malformed(let value) = pin {
            throw InstallRefusal.cannotPinIdentity("this Patched's release Team ID (\(value)) is not a valid Apple Team ID, so no update can be checked")
        }
    }

    /// Puts the old app back after a failed post-swap check, but only if what is at `staged` is still it.
    func swapBack(staged: String, oldIdentity: FileSafety.Identity, installed: BundleFacts, because reason: InstallRefusal) throws {
        guard FileSafety.directoryIdentity(staged) == oldIdentity,
              (try? BundleFacts.read(bundleAt: staged)) == installed else {
            throw InstallRefusal.unresolved("the new Patched failed its check (\(reason.message)) and the previous one is not where it should be (\(staged)); nothing was deleted")
        }
        let error = renamex_np(staged, appPath, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
        guard error == 0, FileSafety.directoryIdentity(appPath) == oldIdentity else {
            throw InstallRefusal.unresolved("the new Patched failed its check (\(reason.message)) and could not be swapped back; the previous one is at \(staged)")
        }
        try? FileSafety.removeTree((staged as NSString).deletingLastPathComponent, within: parent)
    }

    /// Moves the previous Patched into the backups folder (rename, or copy then delete across volumes) and
    /// removes older self-update backups. Never fails the update: the new app is already verified.
    func keepBackup(old: String, work: String) -> (String?, String?) {
        let appBackups = backupsRoot + "/" + PatchedReleaseKey.bundleID
        let folder = appBackups + "/previous-" + UUID().uuidString
        let destination = folder + "/" + appName
        do {
            try FileSafety.makePrivateDirectory(folder)
            if rename(old, destination) != 0 {
                guard errno == EXDEV else { throw InstallRefusal.io("cannot move the previous Patched: \(String(cString: strerror(errno)))") }
                try Unpacker.copyBundle(old, to: destination)
                try FileSafety.syncTree(destination)
            }
        } catch {
            try? FileSafety.removeTree(folder, within: backupsRoot)
            return (nil, "The previous version could not be moved to backups and was left at \(old).")
        }
        try? FileSafety.removeTree(work, within: parent)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: appBackups)) ?? []
        for name in names where name.hasPrefix("previous-") && appBackups + "/" + name != folder {
            try? FileSafety.removeTree(appBackups + "/" + name, within: backupsRoot)
        }
        return (destination, nil)
    }

    func fetch(_ url: URL, to path: String, maxBytes: Int64) async throws -> Int64 {
        let sink = try ArtifactSink(path: path, maxBytes: maxBytes)
        try await downloader.download(url, into: sink, expectedLength: nil)
        return try sink.finish().byteCount
    }

    /// Defence in depth: the lookup already insisted on these exact URLs.
    static func checkAssetURL(_ url: URL, name: String) throws {
        guard url.scheme == "https", url.host == "github.com", url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/birdseeed/patched/releases/download/"), url.lastPathComponent == name else {
            throw InstallRefusal.insecureDownload(url.absoluteString)
        }
    }

    // MARK: System pieces

    /// `codesign --verify --strict --deep`, with the signing identifier pinned to Patched's. This runs for every
    /// release, ad-hoc or not; the Team ID is checked separately (`verifyReleaseTeam`) only when this app pins one.
    public static func verifyCodeSignature(_ path: String) throws {
        let result = ProcessRunner.run("/usr/bin/codesign",
                                       ["--verify", "--strict", "--deep", "-R=identifier \"\(PatchedReleaseKey.bundleID)\"", path],
                                       timeout: 120)
        guard result.succeeded else { throw InstallRefusal.signatureInvalid("codesign --verify --strict --deep: \(result.summary)") }
    }

    /// The pinned-release check: strict, every architecture, nested code and revocation, against
    /// `ReleaseTeamPin.requirement(team:)`, then the signing information must name the same team and identifier.
    /// An ad-hoc, other-team or non-Developer-ID signature fails the requirement and is `releaseTeamMismatch`.
    public static func verifyReleaseTeam(_ path: String, team: String) throws {
        try verifyDeveloperIDSignature(path, team: team, identifier: PatchedReleaseKey.bundleID, enforceRevocation: true)
    }

    /// As `verifyReleaseTeam`, for any identifier, so the checks can run it against a real Developer ID app.
    @_spi(Testing) public static func verifyDeveloperIDSignature(_ path: String, team: String, identifier: String,
                                                                  enforceRevocation: Bool) throws {
        let requirementText = try ReleaseTeamPin.requirement(team: team, identifier: identifier)
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        guard created == errSecSuccess, let code else {
            throw InstallRefusal.signatureInvalid("cannot read the new Patched's code signature (OSStatus \(created))")
        }
        var requirement: SecRequirement?
        let parsed = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard parsed == errSecSuccess, let requirement else {
            throw InstallRefusal.signatureInvalid("cannot build the release requirement (OSStatus \(parsed))")
        }
        var flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        if enforceRevocation { flags |= SystemCodeVerifier.enforceRevocationChecks }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: flags), requirement, &error)
        let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? ""
        if let refusal = validityRefusal(status: status, team: team, detail: detail) { throw refusal }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              dictionary[kSecCodeInfoTeamIdentifier as String] as? String == team,
              dictionary[kSecCodeInfoIdentifier as String] as? String == identifier else {
            throw InstallRefusal.releaseTeamMismatch("the new Patched's signing information does not name team \(team) and \(identifier)")
        }
    }

    /// Revocation answers: the certificate or the notarisation was revoked. Always a hard refusal.
    static let revokedStatuses: Set<OSStatus> = [
        -2147409652,   // CSSMERR_TP_CERT_REVOKED
        -67820,        // errSecCertificateRevoked
        -66992,        // errSecCSRevokedNotarization
    ]
    /// Revocation could not be checked (OCSP or network unreachable, busy, or unusable): worth trying again later.
    static let uncheckableStatuses: Set<OSStatus> = [
        -67630,        // errSecOCSPBadResponse
        -67632,        // errSecOCSPUnavailable
        -67636,        // errSecNetworkFailure
        -67642,        // errSecOCSPResponderInternalError
        -67643,        // errSecOCSPResponderTryLater
        -2147408883,   // CSSMERR_APPLETP_CRL_NOT_FOUND
        -2147408863,   // CSSMERR_APPLETP_OCSP_UNAVAILABLE
        -2147408861,   // CSSMERR_APPLETP_INCOMPLETE_REVOCATION_CHECK
        -2147408860,   // CSSMERR_APPLETP_NETWORK_FAILURE
        -2147408853,   // CSSMERR_APPLETP_OCSP_RESP_TRY_LATER
    ]

    /// What a `SecStaticCodeCheckValidityWithErrors` status means for a pinned release. nil only for success.
    @_spi(Testing) public static func validityRefusal(status: OSStatus, team: String, detail: String) -> InstallRefusal? {
        let suffix = detail.isEmpty ? "" : " (\(detail.prefix(200)))"
        if status == errSecSuccess { return nil }
        if status == errSecCSReqFailed {
            return .releaseTeamMismatch("the new Patched is not notarised Developer ID Application software from team \(team)" + suffix)
        }
        if revokedStatuses.contains(status) {
            return .releaseCertificateRevoked("OSStatus \(status)" + suffix)
        }
        if uncheckableStatuses.contains(status) {
            return .releaseCertificateUnchecked("OSStatus \(status)" + suffix)
        }
        return .signatureInvalid("the new Patched's code signature is not valid (OSStatus \(status))" + suffix)
    }

    /// The download is not quarantined by URLSession, but a quarantine flag copied in from anywhere would make
    /// macOS refuse to open an ad-hoc app it has never seen. The signature check has already been done.
    static func removeQuarantine(_ root: String) {
        removexattr(root, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return }
        for case let relative as String in enumerator {
            removexattr(root + "/" + relative, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }
}

extension SelfUpdater {
    /// Prefix of the private staging folder a self-update makes beside the app.
    public static let workFolderPrefix = ".patched-self-update-"

    /// A staging folder younger than this may belong to an update another Patched is running right now.
    public static let staleWorkFolderAge: TimeInterval = 10 * 60

    /// Removes staging folders a crashed or killed self-update left beside `appPath`. Only directories with the
    /// staging prefix, owned by `uid`, directly in the app's folder, older than `staleWorkFolderAge`, and holding
    /// no app bundle at their top level (after a swap, or when the backup move failed, the previous Patched
    /// lives there and may be the only copy, so it is kept). Never follows symlinks. Returns what was removed.
    @discardableResult
    public static func removeStaleWorkFolders(besideApp appPath: String, uid: uid_t = geteuid(),
                                              now: Date = Date(), minimumAge: TimeInterval = staleWorkFolderAge) -> [String] {
        let parent = (appPath as NSString).deletingLastPathComponent
        guard appPath.hasSuffix(".app"), parent.hasPrefix("/"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        var removed: [String] = []
        for name in names where name.hasPrefix(workFolderPrefix) && !name.contains("/") {
            let path = parent + "/" + name
            guard let info = FileSafety.lstatInfo(path), FileSafety.isDirectory(info), info.st_uid == uid else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) >= minimumAge else { continue }
            let holdsApp = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? ["?"]).contains { $0.hasSuffix(".app") }
            guard !holdsApp else { continue }
            if (try? FileSafety.removeTree(path, within: parent)) != nil { removed.append(path) }
        }
        return removed
    }
}

/// Starting the new Patched once the old one has quit. The new app is opened with `open -n` and told which
/// process to wait for; it waits (bounded) before touching any state, so two copies never work at once.
public enum SelfRelaunch {
    public static let argument = "--patched-relaunched-after"
    public static let maxWait: TimeInterval = 15

    /// `/usr/bin/open -n <app> --args --patched-relaunched-after <pid>`. Throws if it could not be opened.
    public static func open(appPath: String, waitingFor pid: pid_t = getpid()) throws {
        let result = ProcessRunner.run("/usr/bin/open", ["-n", appPath, "--args", argument, String(pid)], timeout: 30)
        guard result.succeeded else { throw InstallRefusal.io("could not reopen Patched: \(result.summary)") }
    }

    /// The process a freshly relaunched Patched should wait for, from its own arguments. Only a plain positive
    /// number that is not this process counts.
    public static func pidToAwait(in arguments: [String], ownPID: pid_t = getpid()) -> pid_t? {
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        let text = arguments[index + 1]
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let pid = pid_t(text), pid > 1, pid != ownPID else { return nil }
        return pid
    }

    /// Waits until `pid` has exited, at most `timeout`. Returns whether it exited.
    @discardableResult
    public static func waitForExit(of pid: pid_t, timeout: TimeInterval = maxWait) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0 || errno == EPERM {
            if Date() >= deadline { return false }
            usleep(100_000)
        }
        return true
    }
}
