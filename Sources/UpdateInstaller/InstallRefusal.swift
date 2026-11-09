import Foundation

/// Why an install, rollback or recovery step refused to go on. Every case has a stable `code` and a
/// human-readable `message`. Every check in the installer fails closed by throwing one of these.
public enum InstallRefusal: Error, Sendable, Equatable {
    /// The installed app has no Team ID (unsigned or ad-hoc), so there is nothing to pin the update to.
    case cannotPinIdentity(String)
    /// Replacing the app would need admin rights (root-owned bundle, unwritable folder, files owned by others).
    case needsAdmin(String)
    /// The download is not a zip or dmg (for example a pkg).
    case unsupportedFormat(String)
    /// The update source is not confirmed for installing (Phase 1 marked it not installable).
    case notInstallable(String)
    /// The app has a Mac App Store receipt; the App Store owns its updates.
    case appStoreManaged(String)
    /// A path is not what it must be: a symlink, not a directory, outside the expected place.
    case unsafePath(String)
    case insecureDownload(String)
    case download(String)
    case tooLarge(String)
    case lengthMismatch(String)
    case hashMismatch(String)
    /// The installed app pins a Sparkle EdDSA key but the offer has no signature.
    case edSignatureMissing
    case edSignatureInvalid(String)
    case unpackFailed(String)
    /// Unpacking would use (or did use) more disk than the budget allows.
    case unpackTooLarge(String)
    /// The transaction stopped in a state it could not prove good; nothing was deleted. Run `recover`.
    case unresolved(String)
    /// Temporary files or a disk image could not be removed; `recover` will retry.
    case cleanupIncomplete(String)
    case bundleNotFound(String)
    case ambiguousBundle(String)
    case unsafeSymlink(String)
    case signatureInvalid(String)
    case notarisationRejected(String)
    case versionMismatch(String)
    case notNewer(String)
    case appRunning(String)
    case appWouldNotQuit(String)
    case busy(String)
    case unfinishedTransaction(String)
    case swapFailed(String)
    /// The new bundle failed re-verification after the swap; the old bundle was swapped back.
    case verificationFailedAfterSwap(String)
    case journal(String)
    case noBackup(String)
    /// The newest backup was replaced by an installer package update, which Patched cannot undo.
    case rollbackUnsupported(String)
    case recoveryAmbiguous(String)
    case io(String)
    // Admin updates: root-owned replacement (off unless PATCHED_ENABLE_ADMIN_UPDATES=1) and .pkg (on unless PATCHED_ENABLE_PKG_UPDATES=0).
    /// The update needs admin rights but there is nobody at the Mac to answer macOS's prompt
    /// (no graphical login session, for example over SSH, or another user is at the screen).
    case needsInteractiveAdmin(String)
    /// macOS did not grant admin rights (the prompt was cancelled or system policy refused).
    case adminDenied(String)
    /// macOS granted admin rights but could not replace the app.
    case privilegedReplaceFailed(String)
    /// macOS granted the prompt but its privileged helper refused the replacement (EIO). Seen on macOS 27
    /// for ad-hoc-signed builds; expected to need Developer ID signing.
    case adminReplaceUnavailable(String)
    /// `patched update --all` reached an app that needs admin rights or Apple's Installer; those need the
    /// user to name the app (`patched update <app>`), so nothing was tried.
    case needsAdminApproval(String)
    /// The installer package is not signed with Developer ID Installer by the installed app's Team ID.
    case packageSignatureInvalid(String)
    /// The installer package is not a plain flat (xar) package.
    case packageMalformed(String)
    /// Apple's Installer could not be opened.
    case installerFailed(String)
    /// Apple's Installer did not change the app (cancelled, still open, or the wait ran out).
    case installerNotFinished(String)
    /// Apple's Installer changed the app, but what is installed now failed verification.
    case installedUnverified(String)

    public var code: String {
        switch self {
        case .cannotPinIdentity: return "cannot_pin_identity"
        case .needsAdmin: return "needs_admin"
        case .unsupportedFormat: return "unsupported_format"
        case .notInstallable: return "not_installable"
        case .appStoreManaged: return "app_store_managed"
        case .unsafePath: return "unsafe_path"
        case .insecureDownload: return "insecure_download"
        case .download: return "download_failed"
        case .tooLarge: return "too_large"
        case .lengthMismatch: return "length_mismatch"
        case .hashMismatch: return "hash_mismatch"
        case .edSignatureMissing: return "ed_signature_missing"
        case .edSignatureInvalid: return "ed_signature_invalid"
        case .unpackFailed: return "unpack_failed"
        case .unpackTooLarge: return "unpack_too_large"
        case .unresolved: return "unresolved"
        case .cleanupIncomplete: return "cleanup_incomplete"
        case .bundleNotFound: return "bundle_not_found"
        case .ambiguousBundle: return "ambiguous_bundle"
        case .unsafeSymlink: return "unsafe_symlink"
        case .signatureInvalid: return "signature_invalid"
        case .notarisationRejected: return "notarisation_rejected"
        case .versionMismatch: return "version_mismatch"
        case .notNewer: return "not_newer"
        case .appRunning: return "app_running"
        case .appWouldNotQuit: return "app_would_not_quit"
        case .busy: return "busy"
        case .unfinishedTransaction: return "unfinished_transaction"
        case .swapFailed: return "swap_failed"
        case .verificationFailedAfterSwap: return "verification_failed_after_swap"
        case .journal: return "journal_error"
        case .noBackup: return "no_backup"
        case .rollbackUnsupported: return "rollback_unsupported"
        case .recoveryAmbiguous: return "recovery_ambiguous"
        case .io: return "io_error"
        case .needsInteractiveAdmin: return "needs_interactive_admin"
        case .adminDenied: return "admin_denied"
        case .privilegedReplaceFailed: return "privileged_replace_failed"
        case .adminReplaceUnavailable: return "admin_replace_unavailable"
        case .needsAdminApproval: return "needs_admin_approval"
        case .packageSignatureInvalid: return "package_signature_invalid"
        case .packageMalformed: return "package_malformed"
        case .installerFailed: return "installer_failed"
        case .installerNotFinished: return "installer_not_finished"
        case .installedUnverified: return "installed_unverified"
        }
    }

    public var message: String {
        switch self {
        case .cannotPinIdentity(let d): return "cannot pin the app's identity: \(d)"
        case .needsAdmin(let d): return "needs admin rights, update this app manually: \(d)"
        case .unsupportedFormat(let d): return "unsupported download format: \(d)"
        case .notInstallable(let d): return "not installable: \(d)"
        case .appStoreManaged(let d): return "Update in the App Store (\(d))"
        case .unsafePath(let d): return "unsafe path: \(d)"
        case .insecureDownload(let d): return "insecure download: \(d)"
        case .download(let d): return "download failed: \(d)"
        case .tooLarge(let d): return "download too large: \(d)"
        case .lengthMismatch(let d): return "download length does not match the feed: \(d)"
        case .hashMismatch(let d): return "download hash does not match the feed: \(d)"
        case .edSignatureMissing: return "the app pins a Sparkle EdDSA key but the update has no EdDSA signature"
        case .edSignatureInvalid(let d): return "Sparkle EdDSA signature is not valid: \(d)"
        case .unpackFailed(let d): return "could not unpack the download: \(d)"
        case .unpackTooLarge(let d): return "unpacking needs too much disk space: \(d)"
        case .cleanupIncomplete(let d): return "could not remove temporary files, run `patched recover` to retry: \(d)"
        case .unresolved(let d): return "stopped without a verified result; the app was left stopped and nothing was deleted, run `patched recover`: \(d)"
        case .bundleNotFound(let d): return "no matching app in the download: \(d)"
        case .ambiguousBundle(let d): return "more than one matching app in the download: \(d)"
        case .unsafeSymlink(let d): return "unsafe symlink in the app: \(d)"
        case .signatureInvalid(let d): return "code signature check failed: \(d)"
        case .notarisationRejected(let d): return "Gatekeeper/notarisation check failed: \(d)"
        case .versionMismatch(let d): return "downloaded app version does not match the feed: \(d)"
        case .notNewer(let d): return "downloaded app is not newer than the installed one: \(d)"
        case .appRunning(let d): return "app is running (pass --quit to quit it first): \(d)"
        case .appWouldNotQuit(let d): return "app did not quit: \(d)"
        case .busy(let d): return "another patched run holds this app: \(d)"
        case .unfinishedTransaction(let d): return "an unfinished transaction exists, run `patched recover` first: \(d)"
        case .swapFailed(let d): return "could not swap the app bundle: \(d)"
        case .verificationFailedAfterSwap(let d): return "new app failed verification after the swap and the old app was put back: \(d)"
        case .journal(let d): return "journal error: \(d)"
        case .noBackup(let d): return "no backup: \(d)"
        case .rollbackUnsupported(let d): return "rollback is not supported for installer packages: \(d)"
        case .recoveryAmbiguous(let d): return "cannot recover automatically: \(d)"
        case .io(let d): return "file error: \(d)"
        case .needsInteractiveAdmin(let d): return "admin updates need you at this Mac to answer macOS's prompt: \(d)"
        case .adminDenied(let d): return "macOS did not grant admin rights, so nothing was changed: \(d)"
        case .privilegedReplaceFailed(let d): return "macOS could not replace the app with admin rights: \(d)"
        case .needsAdminApproval(let d): return "needs admin — run `patched update \(d)` to approve"
        case .adminReplaceUnavailable(let d): return "macOS refused the privileged replacement for this build; update this app manually: \(d)"
        case .packageSignatureInvalid(let d): return "installer package signature check failed: \(d)"
        case .packageMalformed(let d): return "installer package is not a plain flat package: \(d)"
        case .installerFailed(let d): return "could not open Apple's Installer: \(d)"
        case .installerNotFinished(let d): return "Apple's Installer did not install the update, so nothing was verified: \(d)"
        case .installedUnverified(let d): return "Apple's Installer changed the app, but it failed verification: \(d)"
        }
    }
}

extension InstallRefusal: CustomStringConvertible {
    public var description: String { "\(code): \(message)" }
}

/// Thrown by test fault injection to stop a transaction dead, as if the process had been killed.
/// Nothing cleans up after it, so recovery has to.
public struct SimulatedCrash: Error, Sendable, Equatable {
    public let phase: String
    public init(phase: String) { self.phase = phase }
}
