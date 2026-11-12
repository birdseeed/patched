import Foundation

/// One-line, human-readable outcome per app, shared by the CLI (and later the UI) so warnings such as
/// incomplete cleanup are never dropped from one kind of result.
public enum OutcomeText {
    /// `note` is extra information that is not a warning, such as "installed with admin rights" from the
    /// experimental admin path; it is nil everywhere else, so those lines are unchanged.
    public static func line(name: String, status: String, from: String?, to: String?, backupFolder: String?,
                            reason: String?, detail: String?, note: String? = nil) -> String {
        let from = from ?? "?", to = to ?? "?"
        let warning = detail.map { "; warning: " + $0 } ?? ""
        let extra = note.map { "; " + $0 } ?? ""
        switch status {
        case "installed" where note != nil && backupFolder == nil:
            return "\(name): updated \(from) -> \(to); no backup kept" + extra + warning
        case "installed": return "\(name): updated \(from) -> \(to); backup in \(backupFolder ?? "?")" + extra + warning
        // Self Service: a new app, not an update. `backupFolder` carries the folder it was installed in.
        case "installed_new": return "\(name): installed \(to) in \(backupFolder ?? "?")" + extra + warning
        case "dry_run_passed": return "\(name): dry run passed, \(from) -> \(to) verified and cleaned up" + extra
        case "rolled_back": return "\(name): rolled back \(from) -> \(to); \(from) kept as backup in \(backupFolder ?? "?"); the app's data was not rolled back" + extra + warning
        case "up_to_date": return "\(name): up to date (\(from))"
        case "no_source": return "\(name): no update source"
        default: return "\(name): refused [\(reason ?? "?")] \(detail ?? "")"
        }
    }
}
