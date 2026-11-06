import Foundation
import UpdateSources

/// How the `patched` command line asks for admin consent. Kept here, outside the CLI's top-level code,
/// so checks can drive exactly what `main.swift` does.
///
/// Consent belongs to one app the user named: `patched update <app>` or `patched rollback <app>`.
/// `patched update --all` never creates it, so a batch can never ask macOS for admin rights or open
/// Apple's Installer; apps that would need either are reported with the single-app command to run.
public enum CommandLineUpdates {
    public enum Scope: Sendable, Equatable {
        /// `update <app>` or `rollback <app>`: the user named this one app.
        case oneApp
        /// `update --all`.
        case all
    }

    /// The consent token for one command, or nil: always nil for `--all`, and when both admin parts are off.
    public static func consent(_ scope: Scope, installer: UpdateInstaller,
                               notice: @escaping @Sendable (String) -> Void) -> AdminInteraction? {
        guard scope == .oneApp, installer.adminUpdatesEnabled || installer.packageUpdatesEnabled else { return nil }
        return AdminInteraction(onInstallerOpened: notice)
    }

    /// One update, as the CLI runs it. Under `--all`, an app that the switched-on admin path could handle
    /// is refused with `needs_admin_approval`, naming the single-app command; nothing privileged is tried.
    public static func update(_ outcome: AppCheckOutcome, installer: UpdateInstaller, options: UpdateOptions,
                              scope: Scope, notice: @escaping @Sendable (String) -> Void) async throws -> InstallReport {
        do {
            return try await installer.update(outcome, options: options, admin: consent(scope, installer: installer, notice: notice))
        } catch let refusal as InstallRefusal where scope == .all {
            var isPackage = false
            if case .updateAvailable(let offer) = outcome.result { isPackage = offer.format == .pkg }
            switch refusal {
            case .needsAdmin where installer.adminUpdatesEnabled,
                 .unsupportedFormat where isPackage && installer.packageUpdatesEnabled:
                throw InstallRefusal.needsAdminApproval(outcome.app.path)
            default:
                throw refusal
            }
        }
    }

    public static func rollback(appAt path: String, installer: UpdateInstaller, quitIfRunning: Bool,
                                notice: @escaping @Sendable (String) -> Void) async throws -> InstallReport {
        try await installer.rollback(appAt: path, quitIfRunning: quitIfRunning,
                                     admin: consent(.oneApp, installer: installer, notice: notice))
    }
}
