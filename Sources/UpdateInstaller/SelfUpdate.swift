import Foundation
import CryptoKit
import Darwin
import UpdateSources

// Patched updating itself, on an explicit and confirmed click only.
//
// Releases are ad-hoc signed: there is no Apple Developer ID, so no Team ID to pin and no notarisation to
// check, and the normal installer refuses Patched for exactly that reason. Here the trust anchor is Patched's
// own Ed25519 release key instead: every release zip is signed with it (scripts/release.sh), and the public
// half is built into the app below. A zip is only unpacked when its signature verifies against that key.
// See THREAT-MODEL.md, "Patched updating itself".

/// The release-signing key Patched trusts for its own updates, and the bundle it may replace.
public enum PatchedReleaseKey {
    /// Raw 32-byte Curve25519 signing public key, base64. The private half never leaves the owner's Keychain.
    public static let publicKeyBase64 = "3pXCQuK7pRsCXKXhXwld3tJw+yisZpSMKef3OjEsk/k="
    public static let bundleID = "im.patched.app"
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
/// No Team ID or notarisation check: there is none to make for an ad-hoc build. The Ed25519 signature over
/// the zip, against the key built into this app, is what makes the download trusted.
public struct SelfUpdater: Sendable {
    /// The running app's bundle (`Bundle.main.bundlePath`).
    public let appPath: String
    /// The running app's `CFBundleShortVersionString`. The release must be strictly newer.
    public let runningVersion: String
    /// The installer's backups folder; the previous Patched goes in `<backups>/im.patched.app`.
    public let backupsRoot: String
    let downloader: any ArtifactDownloading
    let codeCheck: @Sendable (String) throws -> Void
    let publicKey: String
    let uid: uid_t

    /// Production: the embedded release key, GitHub-only downloads and `codesign --verify --strict --deep`.
    public init(appPath: String, runningVersion: String, backupsRoot: String,
                downloader: any ArtifactDownloading = URLSessionArtifactDownloader(allowedHosts: SelfUpdateLimits.downloadHosts),
                codeCheck: @escaping @Sendable (String) throws -> Void = SelfUpdater.verifyCodeSignature,
                uid: uid_t = geteuid()) {
        self.init(appPath: appPath, runningVersion: runningVersion, backupsRoot: backupsRoot, downloader: downloader,
                  codeCheck: codeCheck, uid: uid, publicKey: PatchedReleaseKey.publicKeyBase64)
    }

    /// Checks only: a throwaway key, because the real private key is never used in tests.
    @_spi(Testing) public init(appPath: String, runningVersion: String, backupsRoot: String, downloader: any ArtifactDownloading,
                               codeCheck: @escaping @Sendable (String) throws -> Void, uid: uid_t = geteuid(), publicKey: String) {
        self.appPath = appPath; self.runningVersion = runningVersion; self.backupsRoot = backupsRoot
        self.downloader = downloader; self.codeCheck = codeCheck; self.uid = uid; self.publicKey = publicKey
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

    /// Bundle ID, contained symlinks, exact version, strictly newer, then the code signature.
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

    /// `codesign --verify --strict --deep`, with the signing identifier pinned to Patched's. No Team ID and no
    /// Gatekeeper assessment: an ad-hoc release has neither, and the release signature has already vouched for it.
    public static func verifyCodeSignature(_ path: String) throws {
        let result = ProcessRunner.run("/usr/bin/codesign",
                                       ["--verify", "--strict", "--deep", "-R=identifier \"\(PatchedReleaseKey.bundleID)\"", path],
                                       timeout: 120)
        guard result.succeeded else { throw InstallRefusal.signatureInvalid("codesign --verify --strict --deep: \(result.summary)") }
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
