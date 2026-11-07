import Foundation
import PatchedClient
import UpdateSources
import UpdateInstaller

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
usage: patched check [--json] [--app <path>] [--explain <app path | bundle ID>]
         Reads installed apps and reports which have updates and where they come from.
         Read-only: nothing is downloaded or installed. Mac App Store apps are looked up with Apple's
         public App Store lookup (their bundle IDs go to Apple only) and reported; update them in the
         App Store. --explain prints why a source was or was not chosen for one app.
       patched update <app path | bundle ID> [--quit] [--dry-run] [--json]
       patched update --all [--quit] [--dry-run] [--json]
         Downloads, verifies and installs updates for apps you can replace without admin rights.
         --quit asks a running app to quit first (it is never force-killed). --dry-run verifies
         everything into a staging folder, then stops and cleans up.
       patched rollback <app path | bundle ID> [--quit]
         Puts back the newest backup and keeps the replaced version as the new backup.
       patched recover [--quit]
         Finishes or undoes any update interrupted by a crash. --quit asks an app that is running
         from an affected bundle to quit first.
       patched backups
         Lists backups.
"""

// MARK: Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
// `admin-probe` is hidden and experimental: see scripts/admin-probe-runbook.md.
guard let command = arguments.first, ["check", "update", "rollback", "recover", "backups", "admin-probe"].contains(command) else { fail(usage, code: 2) }
arguments.removeFirst()
var asJSON = false, quitIfRunning = false, dryRun = false, all = false
var appPath: String?
var explainTarget: String?
var positional: [String] = []
// Hidden, for testing: target a temporary folder instead of /Applications and keep state beside it.
var applicationsRoot: String?
var stateRoot: String?
// Hidden and experimental: admin updates (root-owned apps and .pkg installers through macOS's own prompt).
var enableAdminUpdates = false, enablePackageUpdates = false
var probePackage: String?, probeTeam: String?
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--json": asJSON = true
    case "--quit" where command == "update" || command == "rollback" || command == "recover": quitIfRunning = true
    case "--dry-run" where command == "update": dryRun = true
    case "--all" where command == "update": all = true
    case "--app" where command == "check":
        guard !arguments.isEmpty else { fail("--app needs a path\n" + usage, code: 2) }
        appPath = arguments.removeFirst()
    case "--explain" where command == "check":
        guard !arguments.isEmpty else { fail("--explain needs an app path or bundle ID\n" + usage, code: 2) }
        explainTarget = arguments.removeFirst()
    case "--applications-root":
        guard !arguments.isEmpty else { fail("--applications-root needs a folder", code: 2) }
        applicationsRoot = absolute(arguments.removeFirst())
    case "--state-root":
        guard !arguments.isEmpty else { fail("--state-root needs a folder", code: 2) }
        stateRoot = absolute(arguments.removeFirst())
    case AdminUpdateFlag.commandLineFlag where command == "update" || command == "rollback" || command == "admin-probe":
        enableAdminUpdates = true
    case AdminUpdateFlag.packageCommandLineFlag where command == "update" || command == "admin-probe":
        enablePackageUpdates = true
    case "--package" where command == "admin-probe":
        guard !arguments.isEmpty else { fail("--package needs a path", code: 2) }
        probePackage = absolute(arguments.removeFirst())
    case "--team" where command == "admin-probe":
        guard !arguments.isEmpty else { fail("--team needs a Team ID", code: 2) }
        probeTeam = arguments.removeFirst()
    default:
        if argument.hasPrefix("-") { fail("unknown argument \(argument)\n" + usage, code: 2) }
        positional.append(argument)
    }
}

func absolute(_ path: String) -> String {
    let joined = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    return FileSafety.lexicallyNormalised(joined)
}

// MARK: Inventory and checking

func installedApp(_ app: LocalApplicationObservation) -> InstalledApp { InstalledApp(observation: app) }

func scan(_ roots: [String]?) async -> [InstalledApp] {
    let inventory = roots.map { LocalApplicationInventory(scanningDirectories: $0) } ?? LocalApplicationInventory()
    return await inventory.scan().applications.map(installedApp)
}

// Chosen on first use, never at startup: `--help` and argument errors must not create, migrate or
// even inspect the user's state folders.
var cachedRuntimeLocations: InstallerLocations?
var runtimeLocations: InstallerLocations {
    if let cachedRuntimeLocations { return cachedRuntimeLocations }
    let chosen = selectedLocations()
    cachedRuntimeLocations = chosen
    return chosen
}

@MainActor func loadCatalogue() -> UserCatalogue {
    do { return try UserCatalogue.load(from: URL(fileURLWithPath: runtimeLocations.supportRoot).appendingPathComponent("catalogue.json")) } catch { fail("catalogue error: \(error)", code: 2) }
}

let fetcher = URLSessionFetcher()
@MainActor func makeChecker() -> UpdateChecker {
    UpdateChecker(fetcher: fetcher, caskIndex: CaskIndexProvider(fetcher: fetcher, cacheDirectory: URL(fileURLWithPath: runtimeLocations.downloads).deletingLastPathComponent()), catalogue: loadCatalogue())
}

/// An app path, or a bundle ID looked up in the applications root (or /Applications and ~/Applications).
@MainActor func resolveTarget(_ selector: String) async -> InstalledApp {
    if selector.contains("/") || selector.lowercased().hasSuffix(".app") {
        let path = absolute(selector)
        guard path.lowercased().hasSuffix(".app") else { fail("\(selector): expected a path ending in .app", code: 2) }
        let apps = await scan([(path as NSString).deletingLastPathComponent])
        guard let app = apps.first(where: { $0.path == path }) else { fail("\(selector): no app found at \(path)", code: 1) }
        return app
    }
    let apps = await scan(applicationsRoot.map { [$0] }).filter { $0.bundleID == selector }
    guard !apps.isEmpty else { fail("\(selector): no installed app has this bundle ID", code: 1) }
    guard apps.count == 1 else {
        fail("\(selector): several apps have this bundle ID, pass a path: " + apps.map(\.path).joined(separator: ", "), code: 1)
    }
    return apps[0]
}

// MARK: Installer

@MainActor func selectedLocations() -> InstallerLocations {
    let locations: InstallerLocations
    if let stateRoot { locations = .under(stateRoot) }
    else if let applicationsRoot { locations = .under(applicationsRoot + "/.Patched-state") }
    else {
        do { locations = try InstallerLocations.standard() } catch { fail("\(error)", code: 1) }
    }
    return locations
}

/// Each part is off unless its hidden flag or environment variable turns it on: privileged replacement
/// (PATCHED_ENABLE_ADMIN_UPDATES=1) and .pkg through Apple's Installer (PATCHED_ENABLE_PKG_UPDATES=1).
let adminUpdates = enableAdminUpdates || AdminUpdateFlag.isEnabled()
let packageUpdates = enablePackageUpdates || AdminUpdateFlag.isPackageEnabled()

@MainActor func makeInstaller() -> UpdateInstaller {
    UpdateInstaller(locations: runtimeLocations,
                    adminPath: AdminUpdatePath.ifEnabled(adminFlag: enableAdminUpdates, packageFlag: enablePackageUpdates))
}

/// Where "Apple's Installer has opened" goes. Admin consent itself is decided by `CommandLineUpdates`:
/// only for one named app, never for `update --all`.
@MainActor func installerNotice() -> @Sendable (String) -> Void {
    let toStderr = asJSON
    return { message in
        let text = message + " Waiting (up to 30 minutes)..."
        if toStderr { FileHandle.standardError.write(Data((text + "\n").utf8)) } else { print(text); fflush(stdout) }
    }
}

struct UpdateRow: Encodable {
    let name, path: String
    let bundleID: String?
    let status: String   // installed | dry_run_passed | rolled_back | up_to_date | no_source | refused
    let fromVersion, toVersion, backupFolder, reason, reasonDetail: String?
    /// Admin path only (for example "installed with admin rights"); absent otherwise.
    var note: String? = nil
}

func versionText(_ app: InstalledApp) -> String {
    switch (app.shortVersion, app.build) {
    case let (s?, b?) where s != b: return "\(s) (\(b))"
    case let (s?, _): return s
    case let (nil, b?): return b
    default: return "?"
    }
}

func row(_ app: InstalledApp, _ report: InstallReport) -> UpdateRow {
    UpdateRow(name: app.name, path: app.path, bundleID: app.bundleID, status: report.status.rawValue,
              fromVersion: report.fromVersion, toVersion: report.toVersion, backupFolder: report.backupFolder,
              reason: report.leftovers.isEmpty ? nil : "cleanup_incomplete",
              reasonDetail: report.leftovers.isEmpty ? nil : "could not remove (run `patched recover`): " + report.leftovers.joined(separator: ", "),
              note: report.note)
}
func refusedRow(_ app: InstalledApp, code: String, message: String) -> UpdateRow {
    UpdateRow(name: app.name, path: app.path, bundleID: app.bundleID, status: "refused", fromVersion: versionText(app),
              toVersion: nil, backupFolder: nil, reason: code, reasonDetail: message)
}

func describe(_ row: UpdateRow) -> String {
    OutcomeText.line(name: row.name, status: row.status, from: row.fromVersion, to: row.toVersion,
                     backupFolder: row.backupFolder, reason: row.reason, detail: row.reasonDetail, note: row.note)
}

@MainActor func updateOne(_ app: InstalledApp, installer: UpdateInstaller, checker: UpdateChecker) async -> UpdateRow {
    await install(await checker.checkOne(app), installer: installer, scope: .oneApp)
}

@MainActor func install(_ outcome: AppCheckOutcome, installer: UpdateInstaller, scope: CommandLineUpdates.Scope) async -> UpdateRow {
    let app = outcome.app
    switch outcome.result {
    case .upToDate:
        return UpdateRow(name: app.name, path: app.path, bundleID: app.bundleID, status: "up_to_date",
                         fromVersion: versionText(app), toVersion: nil, backupFolder: nil, reason: nil, reasonDetail: nil)
    case .noSource:
        return UpdateRow(name: app.name, path: app.path, bundleID: app.bundleID, status: "no_source",
                         fromVersion: versionText(app), toVersion: nil, backupFolder: nil, reason: nil, reasonDetail: nil)
    case .refused(let reason):
        return refusedRow(app, code: reason.code, message: reason.message)
    case .updateAvailable:
        // The App Store owns these; Patched only reports them.
        if let reason = outcome.managedByAppStore { return refusedRow(app, code: reason.code, message: reason.message) }
        // The app pins a Sparkle key that this offer can't satisfy; the installer would refuse it.
        if let block = outcome.edSignatureBlock { return refusedRow(app, code: block.code, message: block.message) }
        // A Homebrew match found by app filename alone is not proof of identity; the user
        // must confirm it with a catalogue entry before anything is installed.
        guard outcome.installable else {
            return refusedRow(app, code: "not_installable",
                              message: "matched to a Homebrew cask by filename only; add a catalogue entry for \(app.bundleID ?? app.name) to enable updates")
        }
        do {
            // The installer enforces `installable` itself as well.
            let report = try await CommandLineUpdates.update(outcome, installer: installer,
                                                             options: UpdateOptions(quitIfRunning: quitIfRunning, dryRun: dryRun),
                                                             scope: scope, notice: installerNotice())
            return row(app, report)
        } catch let refusal as InstallRefusal {
            return refusedRow(app, code: refusal.code, message: refusal.message)
        } catch {
            return refusedRow(app, code: "internal_error", message: "\(error)")
        }
    }
}

@MainActor func emit(_ rows: [UpdateRow]) -> Never {
    if asJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { FileHandle.standardOutput.write(try encoder.encode(rows)); print() }
        catch { fail("could not encode JSON: \(error)", code: 1) }
    } else {
        for row in rows { print(describe(row)) }
    }
    exit(rows.contains { $0.status == "refused" } ? 1 : 0)
}

// MARK: Commands

switch command {
case "update":
    let installer = makeInstaller(), checker = makeChecker()
    if all {
        guard positional.isEmpty else { fail("update --all takes no app\n" + usage, code: 2) }
        let apps = await scan(applicationsRoot.map { [$0] })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let outcomes = await checker.check(apps)
        var rows: [UpdateRow] = []
        for outcome in outcomes {
            guard case .updateAvailable = outcome.result, !outcome.isAppStoreUpdate else { continue }
            // Never with admin consent: such apps are reported with the single-app command to run.
            let result = await install(outcome, installer: installer, scope: .all)
            if !asJSON { print(describe(result)) }
            rows.append(result)
        }
        if !asJSON {
            let refused = rows.filter { $0.status == "refused" }.count
            print("\n\(outcomes.count) apps checked, \(rows.count) with updates, \(rows.count - refused) \(dryRun ? "verified" : "updated"), \(refused) refused.")
            exit(refused == 0 ? 0 : 1)
        }
        emit(rows)
    }
    guard positional.count == 1 else { fail("update needs one app path or bundle ID, or --all\n" + usage, code: 2) }
    let app = await resolveTarget(positional[0])
    emit([await updateOne(app, installer: installer, checker: checker)])

case "rollback":
    guard positional.count == 1 else { fail("rollback needs one app path or bundle ID\n" + usage, code: 2) }
    let app = await resolveTarget(positional[0])
    do {
        let report = try await CommandLineUpdates.rollback(appAt: app.path, installer: makeInstaller(), quitIfRunning: quitIfRunning,
                                                           notice: installerNotice())
        emit([row(app, report)])
    } catch let refusal as InstallRefusal {
        emit([refusedRow(app, code: refusal.code, message: refusal.message)])
    } catch {
        emit([refusedRow(app, code: "internal_error", message: "\(error)")])
    }

case "recover":
    guard positional.isEmpty else { fail(usage, code: 2) }
    let result = await makeInstaller().recover(quitIfRunning: quitIfRunning)
    for name in result.unreadable { print("journal \(name): unreadable, left in place for inspection") }
    if result.reports.isEmpty && result.unreadable.isEmpty { print("nothing to recover") }
    var failed = !result.unreadable.isEmpty
    for report in result.reports {
        switch report.result {
        case .success(let outcome):
            let text: String
            switch outcome {
            case .discarded: text = "interrupted before any change; leftovers removed"
            case .completed: text = "finished; new version installed, old version backed up"
            case .reverted: text = "undone; old version is back in place"
            case .cleanedUp: text = "leftover temporary files removed"
            }
            print("\(report.targetPath): \(text) (journal \(report.journalID))")
            if !report.leftovers.isEmpty {
                failed = true
                print("  could not remove (run `patched recover` again): " + report.leftovers.joined(separator: ", "))
            }
        case .failure(let refusal):
            failed = true
            print("\(report.targetPath): refused [\(refusal.code)] \(refusal.message) (journal \(report.journalID))")
        }
    }
    exit(failed ? 1 : 0)

case "admin-probe":
    guard positional.isEmpty else { fail("admin-probe takes no app", code: 2) }
    if let probePackage {
        guard packageUpdates else { fail("admin-probe --package needs \(AdminUpdateFlag.packageCommandLineFlag) or \(AdminUpdateFlag.packageEnvironmentVariable)=1", code: 2) }
        guard let probeTeam else { fail("admin-probe --package needs --team <Team ID>", code: 2) }
        exit(AdminProbe.checkPackage(probePackage, team: probeTeam))
    }
    guard adminUpdates else { fail("admin-probe needs \(AdminUpdateFlag.commandLineFlag) or \(AdminUpdateFlag.environmentVariable)=1", code: 2) }
    exit(await AdminProbe.replaceFakeApp())

case "backups":
    guard positional.isEmpty else { fail(usage, code: 2) }
    let records = makeInstaller().backups()
    if records.isEmpty { print("no backups") }
    for record in records {
        let version = [record.shortVersion, record.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        print("\(record.bundleID)  \(version)  \(record.createdAt)  \(record.bundlePath ?? "?")")
    }
    exit(0)

default:
    break
}

// MARK: check (Phase 1, read-only)

if explainTarget != nil && asJSON { fail("--explain prints text and cannot be combined with --json\n" + usage, code: 2) }
guard positional.isEmpty else { fail("unknown argument \(positional[0])\n" + usage, code: 2) }
var wantedPath: String?
var roots: [String]? = applicationsRoot.map { [$0] }
if let appPath {
    let url = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
    guard url.pathExtension == "app" else { fail("--app expects a path ending in .app", code: 2) }
    wantedPath = url.path
    roots = [url.deletingLastPathComponent().path]
}

let checker = makeChecker()
if let explainTarget {
    let installed = await scan(applicationsRoot.map { [$0] })
    let target = await resolveTarget(explainTarget)
    let (_, lines) = await checker.explain(target, installedBundleIDs: Set(installed.compactMap(\.bundleID)))
    print("\(target.name) (\(target.bundleID ?? "no bundle ID")) at \(target.path)")
    for line in lines { print("  " + line) }
    exit(0)
}
var apps = await scan(roots)
if let wantedPath { apps = apps.filter { $0.path == wantedPath } }
if let wantedPath, apps.isEmpty { fail("no app found at \(wantedPath)", code: 1) }

let outcomes = await checker.check(apps).sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }

if asJSON {
    do { FileHandle.standardOutput.write(try CheckReportRow.json(outcomes)); print() }
    catch { fail("could not encode JSON: \(error)", code: 1) }
    exit(0)
}

func statusText(_ outcome: AppCheckOutcome) -> String {
    switch outcome.result {
    case .upToDate: return "up to date"
    case .updateAvailable: return outcome.isAppStoreUpdate ? "UPDATE AVAILABLE (update in the App Store)" : "UPDATE AVAILABLE"
    case .noSource: return outcome.noSourceReason?.text ?? "no source"
    case .refused(let reason): return "refused: \(reason.message)"
    }
}
let rows: [[String]] = outcomes.map { outcome in
    var latest = "-"
    if case .updateAvailable(let offer) = outcome.result { latest = offer.displayVersion }
    return [outcome.app.name, outcome.app.shortVersion ?? outcome.app.build ?? "?", latest,
            outcome.source.map { ($0.isAppStore ? "app store" : $0.kind) + (outcome.lowConfidence ? "?" : "") } ?? "-", outcome.teamID ?? "-", statusText(outcome) + (outcome.lowConfidence ? " (add a catalogue entry to enable updates)" : "")]
}
let header = ["APP", "INSTALLED", "LATEST", "SOURCE", "TEAM ID", "STATUS"]
var measured = header.map(\.count)
for row in rows { for (i, cell) in row.enumerated() where i < 5 { measured[i] = max(measured[i], min(cell.count, 40)) } }
let widths = measured
func line(_ cells: [String]) -> String {
    cells.enumerated().map { i, cell in
        let text = cell.count > 40 && i < 5 ? String(cell.prefix(39)) + "…" : cell
        return i == cells.count - 1 ? text : text.padding(toLength: widths[i], withPad: " ", startingAt: 0)
    }.joined(separator: "  ")
}
print(line(header))
for row in rows { print(line(row)) }
let updates = outcomes.filter { if case .updateAvailable = $0.result { return true } else { return false } }.count
print("\n\(outcomes.count) apps checked, \(updates) with updates available.")
exit(0)
