import Foundation
import Darwin
import AppKit
import UpdateSources

/// A planner and an executor for removing Patched from this Mac, shared by `patched uninstall` and the app's
/// "Uninstall Patched…" item. Every root is injectable, so checks run in temporary folders.
///
/// The plan is read-only. The executor plans again before it deletes anything and refuses, deleting nothing at
/// all, when the plan is blocked: while any update is unfinished, nothing is removed that `patched recover`
/// might still need. There is no force option.
public enum Uninstall {
    public static let bundleID = NoSourceReason.patchedBundleID
    public static let agentLabel = "im.patched.check"
    public static let brewCommands = ["brew uninstall --cask patched", "brew untap birdseeed/patched"]
    public static let loginItemAdvice = "If Patched is listed in System Settings > General > Login Items, remove it there."

    // MARK: Inputs

    /// Where everything lives. `library` stands in for `~/Library`; every path Patched uses hangs off it.
    public struct Roots: Sendable, Equatable {
        public var library: String
        /// The Patched.app to remove, or nil when this process does not run from (or know of) one.
        public var appBundle: String?
        /// Folders that can hold `.patched-self-update-*` and `.mac-updater-*` staging folders.
        public var applicationFolders: [String]
        /// Homebrew prefixes whose `Caskroom/patched` or `bin/patched` mark the app as Homebrew's.
        public var homebrewPrefixes: [String]

        public init(library: String, appBundle: String?, applicationFolders: [String], homebrewPrefixes: [String]) {
            self.library = library; self.appBundle = appBundle
            self.applicationFolders = applicationFolders; self.homebrewPrefixes = homebrewPrefixes
        }

        /// This user's real folders. Refused while `PATCHED_FORBID_REAL_STATE=1`.
        public static func standard(appBundle: String?) throws -> Roots {
            try RealStateTripwire.check("Uninstall.Roots.standard()")
            guard let home = InstallerLocations.accountHome() else { throw InstallRefusal.io("cannot find the current user's home folder") }
            var folders = ["/Applications", home + "/Applications"]
            if let appBundle {
                let parent = (appBundle as NSString).deletingLastPathComponent
                if !folders.contains(parent) { folders.append(parent) }
            }
            return Roots(library: home + "/Library", appBundle: appBundle, applicationFolders: folders,
                         homebrewPrefixes: ["/opt/homebrew", "/usr/local"])
        }

        var supportParent: String { library + "/Application Support" }
        var cachesParent: String { library + "/Caches" }
        var launchAgentPath: String { library + "/LaunchAgents/" + agentLabel + ".plist" }
        var preferencesPath: String { library + "/Preferences/" + Uninstall.bundleID + ".plist" }
    }

    public struct Options: Sendable, Equatable {
        public var deleteBackups = false
        public var keepLogs = false
        public var keepApp = false
        public init(deleteBackups: Bool = false, keepLogs: Bool = false, keepApp: Bool = false) {
            self.deleteBackups = deleteBackups; self.keepLogs = keepLogs; self.keepApp = keepApp
        }
    }

    /// The outside world, behind closures so checks never touch launchd, the user defaults or the Bin.
    public struct Services: Sendable {
        /// Boots `gui/<uid>/<label>` out of launchd. True when launchd said yes.
        public var bootOutAgent: @Sendable (_ label: String) -> Bool
        /// Removes the user defaults domain.
        public var removeDefaults: @Sendable (_ domain: String) -> Void
        /// Process IDs of other running copies of Patched.
        public var runningInstances: @Sendable () -> [pid_t]
        /// Moves the app bundle to the Bin.
        public var trash: @Sendable (_ path: String) throws -> Void
        /// The CLI may delete the app outright when the Bin is not available; the app never does.
        public var deleteIfTrashFails: Bool

        public init(bootOutAgent: @escaping @Sendable (String) -> Bool, removeDefaults: @escaping @Sendable (String) -> Void,
                    runningInstances: @escaping @Sendable () -> [pid_t], trash: @escaping @Sendable (String) throws -> Void,
                    deleteIfTrashFails: Bool) {
            self.bootOutAgent = bootOutAgent; self.removeDefaults = removeDefaults
            self.runningInstances = runningInstances; self.trash = trash; self.deleteIfTrashFails = deleteIfTrashFails
        }

        /// The real thing. `excludingPID` is the caller itself when it is Patched.app.
        public static func system(excludingPID: pid_t?, deleteIfTrashFails: Bool) -> Services {
            Services(
                bootOutAgent: { label in
                    ProcessRunner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20).succeeded
                },
                removeDefaults: { domain in UserDefaults.standard.removePersistentDomain(forName: domain) },
                runningInstances: {
                    NSRunningApplication.runningApplications(withBundleIdentifier: Uninstall.bundleID)
                        .filter { !$0.isTerminated && $0.processIdentifier != excludingPID }.map(\.processIdentifier)
                },
                trash: { path in try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) },
                deleteIfTrashFails: deleteIfTrashFails)
        }
    }

    // MARK: Plan

    public struct Item: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case launchAgent, support, legacySupport, migrationFile, cache, legacyCache, appCache, httpStorage, savedState
            case logs, stagingFolder, backups, defaults, appBundle
            /// A journal, lock or marker that stops the uninstall.
            case inProgress
        }
        public enum Status: String, Sendable { case delete, keep, blocked }
        public let path: String
        public let kind: Kind
        public let status: Status
        public let bytes: Int64
        public let reason: String
    }

    public struct Blocker: Sendable, Equatable {
        public let message: String
        public let paths: [String]
    }

    public struct Plan: Sendable, Equatable {
        public var items: [Item] = []
        public var blockers: [Blocker] = []
        /// Folders of kept or deleted backups that exist, and their total size.
        public var backupLocations: [String] = []
        public var backupBytes: Int64 = 0
        public var homebrewManaged = false
        public var options = Options()

        public var isBlocked: Bool { !blockers.isEmpty }
        public var willDeleteBackups: Bool { options.deleteBackups && !backupLocations.isEmpty }
        public var homebrewAdvice: String? {
            homebrewManaged ? "Patched was installed with Homebrew. Remove it with `\(brewCommands[0])` then `\(brewCommands[1])`." : nil
        }

        /// Plain text for the terminal: every path with its size and status, blocked entries labelled.
        public func report() -> String {
            var lines: [String] = []
            for item in items {
                let label = item.status == .blocked ? "BLOCKED" : item.status.rawValue
                lines.append("\(label.padding(toLength: 7, withPad: " ", startingAt: 0))  \(Uninstall.size(item.bytes).leftPad(10))  \(item.path)  (\(item.reason))")
            }
            if items.isEmpty { lines.append("nothing of Patched's was found") }
            if !backupLocations.isEmpty {
                let action = options.deleteBackups ? "will be deleted" : "are kept"
                lines.append("")
                lines.append("Backups \(action): \(Uninstall.size(backupBytes)) in \(backupLocations.joined(separator: ", "))")
            }
            if let homebrewAdvice { lines.append(""); lines.append(homebrewAdvice) }
            for blocker in blockers { lines.append(""); lines.append("Cannot uninstall: " + blocker.message) }
            return lines.joined(separator: "\n")
        }
    }

    public static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// Reads the disk and the process list; changes nothing.
    public static func plan(roots: Roots, options: Options, services: Services) -> Plan {
        var planner = Planner(roots: roots, options: options)
        planner.build(services: services)
        return planner.plan
    }

    // MARK: Execute

    public struct Result: Sendable, Equatable {
        /// Set when the plan was blocked: nothing at all was deleted.
        public var refused: Plan?
        public var removed: [String] = []
        public var failures: [String] = []
        public var warnings: [String] = []
        /// What happened, in order: `bootout:<label>`, `delete:<path>`, `defaults:<domain>`, `trash:<path>`.
        public var steps: [String] = []
        public var appRemoved = false
        public var homebrewAdvice: String?
        public var isSuccess: Bool { refused == nil && failures.isEmpty }
    }

    /// Plans again, refuses when blocked, then deletes: the LaunchAgent first, then data, then the user defaults,
    /// and the app last. A failure while removing data leaves the app (and the CLI inside it) in place so
    /// uninstalling can be run again.
    public static func execute(roots: Roots, options: Options, services: Services) -> Result {
        let plan = plan(roots: roots, options: options, services: services)
        var result = Result()
        if plan.isBlocked { result.refused = plan; return result }
        result.homebrewAdvice = plan.homebrewAdvice
        let doomed = plan.items.filter { $0.status == .delete }
        func remove(_ item: Item) {
            result.steps.append("delete:" + item.path)
            do { try deleteOne(item.path); result.removed.append(item.path) }
            catch { result.failures.append("\(item.path): \(error)") }
        }
        for item in doomed where item.kind == .launchAgent {
            result.steps.append("bootout:" + agentLabel)
            if !services.bootOutAgent(agentLabel) {
                result.warnings.append("launchd did not confirm stopping \(agentLabel); it will not start again once its file is gone")
            }
            remove(item)
        }
        let apps = doomed.filter { $0.kind == .appBundle }
        for item in doomed where ![.launchAgent, .defaults, .appBundle].contains(item.kind) {
            remove(item)
        }
        for item in doomed where item.kind == .defaults {
            result.steps.append("defaults:" + bundleID)
            services.removeDefaults(bundleID)
            // Removing the domain empties it but leaves the file behind, so remove the file too.
            if FileSafety.lstatInfo(item.path) != nil {
                do { try deleteOne(item.path) }
                catch { result.failures.append("\(item.path): \(error)"); continue }
            }
            result.removed.append(item.path)
        }
        for item in apps {
            guard result.failures.isEmpty else {
                result.warnings.append("Patched itself was left in place because something above could not be removed; run uninstall again")
                continue
            }
            result.steps.append("trash:" + item.path)
            do { try services.trash(item.path); result.appRemoved = true; result.removed.append(item.path) }
            catch {
                if services.deleteIfTrashFails {
                    do { try deleteOne(item.path); result.appRemoved = true; result.removed.append(item.path)
                         result.warnings.append("could not move Patched to the Bin, so it was deleted") }
                    catch { result.failures.append("\(item.path): \(error)") }
                } else {
                    result.failures.append("\(item.path): could not move to the Bin: \(error)")
                }
            }
        }
        return result
    }

    /// Deletes one path without following a symlink: a link is unlinked, a tree is removed with the safe helper.
    static func deleteOne(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard let info = FileSafety.lstatInfo(path) else { return }
        if FileSafety.isSymlink(info) {
            try FileSafety.requireNoSymlinks(parent)
            guard unlink(path) == 0 else { throw InstallRefusal.io("could not remove \(path): \(String(cString: strerror(errno)))") }
        } else {
            try FileSafety.removeTree(path, within: parent)
        }
    }

    // MARK: Planner

    private struct Planner {
        let roots: Roots
        let options: Options
        var plan: Plan

        init(roots: Roots, options: Options) {
            self.roots = roots; self.options = options
            plan = Plan(); plan.options = options
        }

        enum State { case absent, ok, symlink, unknown }

        func state(_ path: String) -> State {
            switch FileSafety.pathState(path) {
            case .absent: return .absent
            case .unknown: return .unknown
            case .present: break
            }
            do { try FileSafety.requireNoSymlinks(path) } catch { return .symlink }
            return .ok
        }

        func bytes(_ path: String) -> Int64 { FileSafety.boundedTreeScan(path, maxBytes: Int64.max, maxEntries: Int.max).bytes }

        mutating func block(_ message: String, _ paths: [String]) { plan.blockers.append(Blocker(message: message, paths: paths)) }

        mutating func add(_ path: String, _ kind: Item.Kind, _ status: Item.Status, _ reason: String, bytes size: Int64? = nil) {
            plan.items.append(Item(path: path, kind: kind, status: status, bytes: size ?? bytes(path), reason: reason))
        }

        /// A path to delete (or keep) as it is: absent paths are skipped, symlinks and unreadable paths block.
        @discardableResult
        mutating func simple(_ path: String, _ kind: Item.Kind, _ reason: String, keep: Bool = false) -> Bool {
            switch state(path) {
            case .absent: return false
            case .unknown:
                add(path, kind, .blocked, "cannot be inspected", bytes: 0)
                block("\(path) cannot be inspected, so nothing was removed.", [path]); return false
            case .symlink:
                add(path, kind, .blocked, "is a symbolic link, which is never followed", bytes: 0)
                block("\(path) is a symbolic link. Patched never follows one, so nothing was removed. Remove the link by hand if you want it gone.", [path])
                return false
            case .ok:
                add(path, kind, keep ? .keep : .delete, reason); return true
            }
        }

        mutating func build(services: Services) {
            let running = services.runningInstances()
            if !running.isEmpty {
                block("Patched is running (process \(running.map(String.init).joined(separator: ", "))). Quit Patched first.", [])
            }
            if state(roots.launchAgentPath) != .absent { simple(roots.launchAgentPath, .launchAgent, "optional check schedule; stopped first") }

            let newSupport = roots.supportParent + "/Patched", oldSupport = roots.supportParent + "/mac-updater"
            checkJournals(in: newSupport + "/Updater/transactions", legacy: false)
            checkJournals(in: oldSupport + "/transactions", legacy: true)
            checkMigrationMarker()
            supportItems(newSupport, backupsRelative: ["Updater", "backups"], kind: .support, reason: "Patched's catalogue, journals and settings")
            supportItems(oldSupport, backupsRelative: ["backups"], kind: .legacySupport, reason: "older mac-updater support folder")
            for name in [".patched-state-migration.json", ".patched-state-migration.lock", ".patched-state-migration.lease"] {
                simple(roots.supportParent + "/" + name, .migrationFile, "state migration file")
            }
            simple(roots.cachesParent + "/Patched", .cache, "downloads and the cask index")
            simple(roots.cachesParent + "/mac-updater", .legacyCache, "older mac-updater cache")
            simple(roots.cachesParent + "/" + bundleID, .appCache, "system cache for the app")
            simple(roots.library + "/HTTPStorages/" + bundleID, .httpStorage, "system HTTP storage for the app")
            simple(roots.library + "/Saved Application State/" + bundleID + ".savedState", .savedState, "saved window state")
            simple(roots.library + "/Logs/Patched", .logs, options.keepLogs ? "kept because you asked" : "check schedule logs", keep: options.keepLogs)
            stagingFolders()
            simple(roots.preferencesPath, .defaults, "user settings (managed preferences are never touched)")
            appBundle()
            // Every blocking path is shown as a blocked entry, even when it sits inside a folder listed above.
            for blocker in plan.blockers {
                for path in blocker.paths where !plan.items.contains(where: { $0.path == path }) {
                    add(path, .inProgress, .blocked, "stops the uninstall until it is dealt with")
                }
            }
        }

        // Journals and migration

        mutating func checkJournals(in directory: String, legacy: Bool) {
            switch state(directory) {
            case .absent: return
            case .unknown, .symlink:
                block("\(directory) cannot be inspected safely, so nothing was removed. Run `patched recover`, or inspect it by hand.", [directory]); return
            case .ok: break
            }
            let store = JournalStore(directory: directory)
            let found = store.all()
            for journal in found.journals {
                let path = store.path(for: journal.id)
                if legacy {
                    block("The older mac-updater folder still holds an update journal (\(path)). Run `patched recover` first.", [path])
                } else if !journal.isTerminal {
                    block("An update of \(journal.targetName) did not finish (journal \(path), phase \(journal.phase.rawValue)). Run `patched recover` first.", [path])
                } else if journal.cleanupPending?.isEmpty == false {
                    block("An update of \(journal.targetName) still has leftovers to clean up (journal \(path)). Run `patched recover` first.", [path])
                }
            }
            for name in found.unreadable {
                let path = directory + "/" + name
                block("The update journal \(path) cannot be read, and it could concern any app. Inspect it by hand, or run `patched recover`.", [path])
            }
            // A held app lock means an installer is running right now.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".lock") {
                let path = directory + "/" + name
                guard let info = FileSafety.lstatInfo(path), FileSafety.isRegular(info) else { continue }
                let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { continue }
                defer { close(fd) }
                if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                    block("An installer is running (\(path) is locked). Wait for it to finish.", [path])
                } else { flock(fd, LOCK_UN) }
            }
        }

        mutating func checkMigrationMarker() {
            let marker = roots.supportParent + "/.patched-state-migration.json"
            guard state(marker) == .ok else { return }  // absent, or a symlink that `simple` will block
            guard let info = FileSafety.lstatInfo(marker), FileSafety.isRegular(info),
                  let data = FileSafety.readSmallFile(marker, limit: 64 * 1024),
                  let saved = try? JSONDecoder().decode(LegacyStateMigration.Marker.self, from: data) else {
                block("The state migration marker \(marker) cannot be read. Inspect it by hand, or run `patched recover`.", [marker]); return
            }
            if saved.done != true {
                block("An older state migration did not finish (\(marker)). Run `patched recover` first.", [marker])
            }
        }

        // Support folders and backups

        func entries(_ directory: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        }

        mutating func supportItems(_ root: String, backupsRelative: [String], kind: Item.Kind, reason: String) {
            switch state(root) {
            case .absent: return
            case .unknown, .symlink:
                add(root, kind, .blocked, "cannot be followed or inspected", bytes: 0)
                block("\(root) is a symbolic link or cannot be inspected, so nothing was removed. Patched never follows a link; remove it by hand.", [root])
                return
            case .ok: break
            }
            let backups = root + "/" + backupsRelative.joined(separator: "/")
            var hasBackups = false
            if state(backups) == .ok, FileSafety.isDirectory(FileSafety.lstatInfo(backups) ?? stat()), !entries(backups).isEmpty { hasBackups = true }
            if hasBackups {
                plan.backupLocations.append(backups)
                plan.backupBytes += bytes(backups)
            }
            if !hasBackups || options.deleteBackups {
                add(root, kind, .delete, reason + (hasBackups ? " and its backups" : ""))
                return
            }
            keepingBackups(directory: root, remaining: backupsRelative[...], kind: kind, reason: reason)
        }

        /// Everything under `directory` except the path down to the backups folder, which is kept in place.
        mutating func keepingBackups(directory: String, remaining: ArraySlice<String>, kind: Item.Kind, reason: String) {
            guard let keepName = remaining.first else { return }
            for name in entries(directory) {
                let path = directory + "/" + name
                if name == keepName {
                    if remaining.count == 1 {
                        add(path, .backups, .keep, "kept so a reinstalled Patched can still roll back; use --delete-backups to remove")
                    } else {
                        keepingBackups(directory: path, remaining: remaining.dropFirst(), kind: kind, reason: reason)
                    }
                } else if let info = FileSafety.lstatInfo(path), FileSafety.isSymlink(info) {
                    add(path, kind, .delete, "symbolic link; only the link is removed", bytes: 0)
                } else {
                    add(path, kind, .delete, reason)
                }
            }
        }

        // Staging folders beside apps

        mutating func stagingFolders() {
            var named: [String] = []  // every path a journal names
            for directory in [roots.supportParent + "/Patched/Updater/transactions", roots.supportParent + "/mac-updater/transactions"] {
                for journal in JournalStore(directory: directory).all().journals {
                    named += [journal.stagingDir, journal.targetPath] + [journal.downloadDir, journal.mountPoint, journal.restoredFrom,
                              journal.backupDir, journal.backupCopyPartial].compactMap { $0 } + (journal.cleanupPending ?? [])
                }
            }
            var seen = Set<String>()
            for folder in roots.applicationFolders where seen.insert(folder).inserted {
                for name in entries(folder) where name.hasPrefix(".patched-self-update-") || name.hasPrefix(".mac-updater-") {
                    let path = folder + "/" + name
                    guard let info = FileSafety.lstatInfo(path) else { continue }
                    guard FileSafety.isDirectory(info) else {
                        add(path, .stagingFolder, .blocked, "not a plain folder", bytes: 0)
                        block("\(path) is not a plain folder, so nothing was removed. Check it by hand.", [path]); continue
                    }
                    let holdsApp = containsApp(path)
                    if name.hasPrefix(".patched-self-update-") {
                        if holdsApp {
                            add(path, .stagingFolder, .blocked, "holds an app", bytes: bytes(path))
                            block("\(path) still holds an app. It may be the previous Patched, left by an update that could not finish. Move it out by hand if you want to keep it, then run uninstall again.", [path])
                        } else {
                            add(path, .stagingFolder, .delete, "empty self-update staging folder")
                        }
                    } else {
                        let isNamed = named.contains { $0 == path || $0.hasPrefix(path + "/") }
                        if holdsApp || isNamed {
                            add(path, .stagingFolder, .blocked, isNamed ? "named by an update journal" : "holds an app", bytes: bytes(path))
                            block("\(path) is an update staging folder that \(isNamed ? "an update journal still names" : "holds an app"). Run `patched recover` first.", [path])
                        } else {
                            add(path, .stagingFolder, .delete, "empty update staging folder")
                        }
                    }
                }
            }
        }

        /// Whether a `.app` sits anywhere inside, at any depth. Symlinks are never followed.
        func containsApp(_ directory: String) -> Bool {
            guard let walker = FileManager.default.enumerator(atPath: directory) else { return false }
            while let relative = walker.nextObject() as? String {
                if (relative as NSString).lastPathComponent.lowercased().hasSuffix(".app") { return true }
            }
            return false
        }

        // The app

        mutating func appBundle() {
            guard let app = roots.appBundle, state(app) != .absent else { return }
            if homebrewManages(app) {
                plan.homebrewManaged = true
                add(app, .appBundle, .keep, "managed by Homebrew: remove with `\(brewCommands[0])` then `\(brewCommands[1])`")
            } else if options.keepApp {
                add(app, .appBundle, .keep, "kept because you asked")
            } else {
                simple(app, .appBundle, "moved to the Bin last")
            }
        }

        func homebrewManages(_ app: String) -> Bool {
            let fm = FileManager.default
            let normalisedApp = FileSafety.lexicallyNormalised(app)
            let realApp = FileSafety.realPath(app)
            for prefix in roots.homebrewPrefixes {
                if FileSafety.exists(prefix + "/Caskroom/patched") { return true }
                let link = prefix + "/bin/patched"
                guard let info = FileSafety.lstatInfo(link), FileSafety.isSymlink(info),
                      let destination = try? fm.destinationOfSymbolicLink(atPath: link) else { continue }
                let target = FileSafety.lexicallyNormalised(destination.hasPrefix("/") ? destination : prefix + "/bin/" + destination)
                let resolved = FileSafety.realPath(link)
                if target.hasPrefix(normalisedApp + "/") { return true }
                if let resolved, let realApp, resolved.hasPrefix(realApp + "/") { return true }
            }
            return false
        }
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
