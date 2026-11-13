import Foundation
import UpdateInstaller

/// Short, plain sentences for the app's rows and results. The command line and `--explain` keep the full
/// technical text (`InstallRefusal.code` and `.message`); nothing here shows a code, a process ID or a file path.
public enum PlainRefusalText {
    /// "A", "A and B", or "A, B and others" (at most two names are shown).
    public nonisolated static func nameList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return String(localized: "\(names[0]) and \(names[1])")
        default: return String(localized: "\(names[0]), \(names[1]) and others")
        }
    }

    /// `installing` words the fallback for a Self Service install ("couldn't be installed") instead of an update.
    public nonisolated static func text(name app: String, _ refusal: InstallRefusal, installing: Bool = false) -> String {
        switch refusal {
        case .helperRunning(let detail):
            let names = HelperRefusalDetail.friendlyNames(in: detail)
            if names.isEmpty {
                return String(localized: "\(app) is still running in the background. Quit \(app) (check the menu bar too), or restart your Mac, then try again.")
            }
            let list = nameList(names)
            return String(localized: "\(app) is still running in the background (\(list)). Quit \(app) (check the menu bar too), or restart your Mac, then try again.")
        case .appRunning: return String(localized: "Quit \(app), then try again.")
        case .appWouldNotQuit: return String(localized: "\(app) didn't quit. Quit it yourself, then try again.")
        case .hashMismatch, .lengthMismatch, .edSignatureMissing, .edSignatureInvalid, .signatureInvalid, .notarisationRejected,
             .packageSignatureInvalid, .packageMalformed, .releaseSignatureInvalid, .releaseTeamMismatch, .releaseCertificateRevoked:
            return String(localized: "The download didn't pass Patched's security checks, so nothing was changed.")
        case .releaseCertificateUnchecked:
            return String(localized: "Patched couldn't check the download with Apple. Check your connection and try again. Nothing was changed.")
        case .insecureDownload:
            return String(localized: "The update for \(app) came from an address Patched doesn't trust, so nothing was changed.")
        case .download:
            return String(localized: "The download for \(app) failed. Check your connection and try again. Nothing was changed.")
        case .tooLarge, .unpackTooLarge:
            return String(localized: "The download for \(app) was larger than Patched allows, so nothing was changed.")
        case .unpackFailed:
            return String(localized: "Patched couldn't open the download for \(app). Nothing was changed.")
        case .versionMismatch, .notNewer, .bundleNotFound, .ambiguousBundle:
            return String(localized: "The download wasn't the update Patched expected for \(app), so nothing was changed.")
        case .appStoreManaged:
            return String(localized: "\(app) comes from the App Store. Update it there.")
        case .cannotPinIdentity:
            return String(localized: "Patched can't check who made \(app), so it left it alone. Nothing was changed.")
        case .needsAdmin, .needsAdminApproval, .needsInteractiveAdmin:
            return String(localized: "\(app) needs admin rights to update. Nothing was changed.")
        case .adminDenied:
            return String(localized: "macOS didn't give Patched admin rights, so nothing was changed.")
        case .busy:
            return String(localized: "Patched is already working on \(app). Try again in a moment.")
        case .unfinishedTransaction:
            return String(localized: "An earlier update didn't finish. Choose Recover, then try again.")
        case .unresolved, .recoveryAmbiguous:
            return String(localized: "Patched couldn't finish updating \(app) and may have left it closed. Choose Recover to put things right.")
        case .verificationFailedAfterSwap:
            return String(localized: "The new version of \(app) didn't pass Patched's checks, so the old version was put back.")
        case .noBackup:
            return String(localized: "There is no earlier version of \(app) to go back to.")
        case .rollbackUnsupported:
            return String(localized: "\(app) was updated with an installer package, which Patched can't undo.")
        case .destinationExists:
            return String(localized: "\(app) is already installed there, so nothing was changed.")
        default:
            return installing ? String(localized: "\(app) couldn't be installed. Nothing was changed.")
                              : String(localized: "\(app) couldn't be updated. Nothing was changed.")
        }
    }
}
