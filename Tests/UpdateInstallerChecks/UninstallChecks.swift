import Foundation
import Darwin
import UpdateSources
import UpdateInstaller

// `Uninstall` and `patched uninstall`, in temporary folders only. A fake library stands in for ~/Library, a
// fake Applications folder for /Applications, and every outside effect (launchd, defaults, the Bin) is recorded.

final class UninstallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func add(_ event: String) { lock.lock(); log.append(event); lock.unlock() }
}

struct UninstallFixture {
    let box: Sandbox
    let library: String
    let applications: String
    let brew: String
    let managed: String
    let outside: String
    let app: String
    let recorder = UninstallRecorder()
    var support: String { library + "/Application Support/Patched/Updater" }
    var plist: String { library + "/LaunchAgents/im.patched.check.plist" }

    init() throws {
        box = try Sandbox()
        library = box.root + "/home/Library"
        applications = box.root + "/Applications"
        brew = box.root + "/brew"
        managed = box.root + "/Library/Managed Preferences"
        outside = box.root + "/outside"
        app = applications + "/Patched.app"
        let fm = FileManager.default
        func write(_ path: String, _ text: String = "x") throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
        try write(support + "/catalogue.json", "{}")
        try write(support + "/catalogue.json.lock")
        try write(support + "/transactions/test.app.lock")
        try write(support + "/backups/com.vendor.tool/1.0-1/Tool.app/Contents/Info.plist", String(repeating: "b", count: 5000))
        try write(support + "/backups/im.patched.app/previous-abc/Patched.app/Contents/Info.plist", "old patched")
        try write(library + "/Application Support/Patched/Preferences/record.json")
        try write(library + "/Application Support/mac-updater/catalogue.json")
        for name in [".patched-state-migration.json", ".patched-state-migration.lock", ".patched-state-migration.lease"] {
            try write(library + "/Application Support/" + name, name.hasSuffix(".json") ? #"{"version":1,"moves":[],"done":true}"# : "")
        }
        try write(library + "/Caches/Patched/Updater/cask-index.json")
        try write(library + "/Caches/mac-updater/old")
        try write(library + "/Caches/im.patched.app/c")
        try write(library + "/HTTPStorages/im.patched.app/h")
        try write(library + "/Saved Application State/im.patched.app.savedState/s")
        try write(library + "/Logs/Patched/check.log")
        try write(plist, "<plist/>")
        try write(library + "/Preferences/im.patched.app.plist", "prefs")
        try write(managed + "/im.patched.app.plist", "managed by the organisation")
        try write(outside + "/canary", "do not delete")
        try makeApp(at: app, id: "im.patched.app", short: "0.2.2", build: "1")
        try fm.createDirectory(atPath: applications + "/.patched-self-update-AAA", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: applications + "/.mac-updater-BBB", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: brew + "/bin", withIntermediateDirectories: true)
    }

    var roots: Uninstall.Roots {
        Uninstall.Roots(library: library, appBundle: app, applicationFolders: [applications], homebrewPrefixes: [brew])
    }

    /// Services that record what happens, and delete the defaults file the way the real domain removal does.
    func services(running: [pid_t] = []) -> Uninstall.Services {
        let recorder = self.recorder, plist = self.plist, prefs = library + "/Preferences/im.patched.app.plist"
        return Uninstall.Services(
            bootOutAgent: { label in
                recorder.add("bootout:\(label):plistPresent=\(FileManager.default.fileExists(atPath: plist))"); return true
            },
            removeDefaults: { domain in recorder.add("defaults:\(domain)"); try? FileManager.default.removeItem(atPath: prefs) },
            runningInstances: { running },
            trash: { path in recorder.add("trash:\(path)"); try FileManager.default.removeItem(atPath: path) },
            deleteIfTrashFails: false)
    }

    /// Every path under the library, applications and outside folders, to compare before and after.
    func snapshot() -> [String] {
        var all: [String] = []
        for root in [box.root + "/home", applications, managed, outside, brew] {
            all.append(root)
            for case let relative as String in FileManager.default.enumerator(atPath: root) ?? FileManager.default.enumerator(atPath: "/var/empty")! {
                all.append(root + "/" + relative)
            }
        }
        return all.sorted()
    }

    func writeJournal(_ phase: TransactionJournal.Phase, id: String = "11111111-1111-1111-1111-111111111111", staging: String? = nil,
                      cleanupPending: [String]? = nil) throws {
        var journal = TransactionJournal(id: id, kind: .update, phase: phase, bundleID: "com.vendor.tool", teamID: teamA,
                                         targetPath: applications + "/Tool.app", stagingDir: staging ?? applications + "/.mac-updater-ZZZ",
                                         createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        journal.cleanupPending = cleanupPending
        let directory = support + "/transactions"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try JournalStore(directory: directory).write(&journal)
    }
}

func uninstallBlockedText(_ plan: Uninstall.Plan) -> String { plan.blockers.map(\.message).joined(separator: "\n") }

/// Runs the built `patched` next to this executable. Returns the exit code and what it printed.
func runPatchedCLI(_ arguments: [String], unsetting: [String] = []) throws -> (status: Int32, output: String) {
    guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { throw CheckFailure(description: "no executable path") }
    let process = Process()
    process.executableURL = dir.appendingPathComponent("patched")
    guard FileManager.default.isExecutableFile(atPath: process.executableURL!.path) else { throw CheckFailure(description: "patched is not built beside the checks") }
    process.arguments = arguments
    if !unsetting.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.filter { !unsetting.contains($0.key) }
    }
    process.standardInput = FileHandle(forReadingAtPath: "/dev/null")  // not a terminal
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func registerUninstallChecks() {
    check("uninstall: a dry run lists every Patched path and deletes nothing") {
        let f = try UninstallFixture()
        let before = f.snapshot()
        let plan = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(!plan.isBlocked, "blocked: \(uninstallBlockedText(plan))")
        let kinds = Set(plan.items.map(\.kind))
        for kind: Uninstall.Item.Kind in [.launchAgent, .support, .legacySupport, .migrationFile, .cache, .legacyCache, .appCache, .httpStorage,
                                          .savedState, .logs, .stagingFolder, .backups, .defaults, .appBundle] {
            try expect(kinds.contains(kind), "missing \(kind) in \(plan.items.map(\.kind))")
        }
        try expect(plan.items.filter { $0.kind == .migrationFile }.count == 3, "migration files")
        try expect(plan.items.filter { $0.kind == .stagingFolder }.count == 2, "staging folders")
        try expect(plan.items.allSatisfy { !$0.reason.isEmpty }, "reasons")
        try expect(plan.items.first { $0.kind == .backups }?.status == .keep, "backups not kept")
        try expect(plan.items.first { $0.kind == .appBundle }?.bytes ?? 0 > 0, "app size")
        try expect(plan.report().contains(f.library + "/Logs/Patched"), "report misses logs")
        try expectEqual(f.snapshot(), before, "plan changed the disk")
        try expectEqual(f.recorder.events, [], "plan had side effects")
    }

    check("uninstall: refuses, deleting nothing, on an unfinished journal and points at recover") {
        let f = try UninstallFixture()
        try f.writeJournal(.backedUp)
        let before = f.snapshot()
        let plan = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(plan.isBlocked && uninstallBlockedText(plan).contains("patched recover") && uninstallBlockedText(plan).contains("11111111-1111"), uninstallBlockedText(plan))
        let result = Uninstall.execute(roots: f.roots, options: Uninstall.Options(deleteBackups: true), services: f.services())
        try expect(result.refused != nil && result.removed.isEmpty && result.steps.isEmpty, "executed anyway: \(result.steps)")
        try expectEqual(f.snapshot(), before, "refusal changed the disk")
        try expectEqual(f.recorder.events, [], "refusal had side effects")
    }

    check("uninstall: refuses on a cleanupPending journal, even a settled one") {
        let f = try UninstallFixture()
        try f.writeJournal(.finished, cleanupPending: [f.applications + "/.mac-updater-ZZZ"])
        let plan = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(plan.isBlocked && uninstallBlockedText(plan).contains("leftovers") && uninstallBlockedText(plan).contains("patched recover"), uninstallBlockedText(plan))
        // The same journal without leftovers is only a record and does not block.
        let g = try UninstallFixture()
        try g.writeJournal(.finished)
        try expect(!Uninstall.plan(roots: g.roots, options: Uninstall.Options(), services: g.services()).isBlocked, "finished record blocked")
    }

    check("uninstall: refuses on an unfinished migration marker and on legacy folders that still hold journals") {
        let f = try UninstallFixture()
        try Data(#"{"version":1,"moves":[],"done":false}"#.utf8).write(to: URL(fileURLWithPath: f.library + "/Application Support/.patched-state-migration.json"))
        let marker = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(marker.isBlocked && uninstallBlockedText(marker).contains("did not finish") && uninstallBlockedText(marker).contains("patched recover"), uninstallBlockedText(marker))
        let g = try UninstallFixture()
        let legacy = g.library + "/Application Support/mac-updater/transactions"
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        var journal = TransactionJournal(id: "22222222-2222-2222-2222-222222222222", kind: .update, phase: .finished, bundleID: "com.vendor.tool", teamID: teamA,
                                         targetPath: "/x/Tool.app", stagingDir: "/x/s", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        try JournalStore(directory: legacy).write(&journal)
        let plan = Uninstall.plan(roots: g.roots, options: Uninstall.Options(), services: g.services())
        try expect(plan.isBlocked && uninstallBlockedText(plan).contains("older mac-updater folder still holds"), uninstallBlockedText(plan))
    }

    check("uninstall: a self-update folder holding an app blocks; an empty one is removed") {
        let f = try UninstallFixture()
        try FileManager.default.createDirectory(atPath: f.applications + "/.patched-self-update-AAA/deep/er/Patched.app/Contents", withIntermediateDirectories: true)
        let plan = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(plan.isBlocked && uninstallBlockedText(plan).contains(".patched-self-update-AAA") && uninstallBlockedText(plan).contains("previous Patched"), uninstallBlockedText(plan))
        try expect(plan.items.contains { $0.status == .blocked && $0.path.hasSuffix(".patched-self-update-AAA") }, "item not labelled blocked")
        let g = try UninstallFixture()
        let result = Uninstall.execute(roots: g.roots, options: Uninstall.Options(), services: g.services())
        try expect(result.isSuccess, "\(result.failures)")
        try expect(!FileManager.default.fileExists(atPath: g.applications + "/.patched-self-update-AAA"), "empty self-update folder kept")
        try expect(!FileManager.default.fileExists(atPath: g.applications + "/.mac-updater-BBB"), "empty staging folder kept")
    }

    check("uninstall: a staging folder named by a journal, or holding an app, blocks") {
        let f = try UninstallFixture()
        try f.writeJournal(.finished, staging: f.applications + "/.mac-updater-BBB")
        let named = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(named.isBlocked && uninstallBlockedText(named).contains(".mac-updater-BBB") && uninstallBlockedText(named).contains("journal"), uninstallBlockedText(named))
        let g = try UninstallFixture()
        try FileManager.default.createDirectory(atPath: g.applications + "/.mac-updater-BBB/Tool.app", withIntermediateDirectories: true)
        let holds = Uninstall.plan(roots: g.roots, options: Uninstall.Options(), services: g.services())
        try expect(holds.isBlocked && uninstallBlockedText(holds).contains("holds an app"), uninstallBlockedText(holds))
    }

    check("uninstall: backups are kept in place by default and deleted only with deleteBackups") {
        let f = try UninstallFixture()
        let plan = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(plan.backupLocations == [f.support + "/backups"] && plan.backupBytes > 5000, "backup summary: \(plan.backupLocations) \(plan.backupBytes)")
        let result = Uninstall.execute(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(result.isSuccess, "\(result.failures)")
        let fm = FileManager.default
        try expect(fm.fileExists(atPath: f.support + "/backups/com.vendor.tool/1.0-1/Tool.app/Contents/Info.plist"), "backup deleted")
        try expect(fm.fileExists(atPath: f.support + "/backups/im.patched.app/previous-abc/Patched.app/Contents/Info.plist"), "previous Patched deleted")
        for gone in [f.support + "/catalogue.json", f.support + "/transactions", f.library + "/Application Support/Patched/Preferences",
                     f.library + "/Application Support/mac-updater", f.library + "/Caches/Patched", f.library + "/Caches/mac-updater",
                     f.library + "/Caches/im.patched.app", f.library + "/HTTPStorages/im.patched.app",
                     f.library + "/Saved Application State/im.patched.app.savedState", f.library + "/Logs/Patched", f.plist,
                     f.library + "/Application Support/.patched-state-migration.json", f.library + "/Application Support/.patched-state-migration.lock",
                     f.library + "/Application Support/.patched-state-migration.lease", f.library + "/Preferences/im.patched.app.plist", f.app] {
            try expect(!fm.fileExists(atPath: gone), "still there: \(gone)")
        }
        let g = try UninstallFixture()
        let all = Uninstall.execute(roots: g.roots, options: Uninstall.Options(deleteBackups: true), services: g.services())
        try expect(all.isSuccess, "\(all.failures)")
        try expect(!fm.fileExists(atPath: g.library + "/Application Support/Patched"), "Patched support folder (with backups) kept")
    }

    check("uninstall: a symlinked root is refused and never followed") {
        for link in ["/Caches/Patched", "/Application Support/Patched", "/Logs/Patched"] {
            let f = try UninstallFixture()
            try FileManager.default.removeItem(atPath: f.library + link)
            try FileManager.default.createSymbolicLink(atPath: f.library + link, withDestinationPath: f.outside)
            let plan = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
            try expect(plan.isBlocked && plan.items.contains { $0.status == .blocked && $0.path == f.library + link }, "\(link): \(plan.report())")
            let result = Uninstall.execute(roots: f.roots, options: Uninstall.Options(deleteBackups: true), services: f.services())
            try expect(result.refused != nil && FileManager.default.fileExists(atPath: f.outside + "/canary"), "\(link): followed or deleted")
            try expect(FileManager.default.fileExists(atPath: f.library + "/Caches/im.patched.app/c"), "\(link): deleted something anyway")
        }
    }

    check("uninstall: managed preferences are never touched, and only Patched's own defaults domain is removed") {
        let f = try UninstallFixture()
        let result = Uninstall.execute(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(result.isSuccess, "\(result.failures)")
        try expectEqual(try String(contentsOfFile: f.managed + "/im.patched.app.plist", encoding: .utf8), "managed by the organisation")
        try expect(f.recorder.events.filter { $0.hasPrefix("defaults:") } == ["defaults:im.patched.app"], "\(f.recorder.events)")
        try expect(!result.steps.contains { $0.contains("Managed Preferences") }, "touched managed folder")
    }

    check("uninstall: the LaunchAgent is booted out before its file is deleted") {
        let f = try UninstallFixture()
        let result = Uninstall.execute(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(result.isSuccess, "\(result.failures)")
        try expect(f.recorder.events.first == "bootout:im.patched.check:plistPresent=true", "\(f.recorder.events)")
        let boot = result.steps.firstIndex(of: "bootout:im.patched.check"), del = result.steps.firstIndex(of: "delete:" + f.plist)
        try expect(boot != nil && del != nil && boot! < del!, "order: \(result.steps)")
        try expect(!FileManager.default.fileExists(atPath: f.plist), "plist kept")
    }

    check("uninstall: the app is removed last, after data and defaults, and stays if data could not be removed") {
        let f = try UninstallFixture()
        let result = Uninstall.execute(roots: f.roots, options: Uninstall.Options(), services: f.services())
        try expect(result.steps.last == "trash:" + f.app && result.appRemoved, "steps: \(result.steps)")
        let defaults = result.steps.firstIndex(of: "defaults:im.patched.app")!
        try expect(result.steps.indices.filter { result.steps[$0].hasPrefix("delete:") }.allSatisfy { $0 < defaults }, "data after defaults: \(result.steps)")
        // A data folder that cannot be deleted must keep the app (and the CLI inside it).
        let g = try UninstallFixture()
        let locked = g.library + "/Logs"
        chmod(locked, 0o500)
        defer { chmod(locked, 0o700) }
        let blocked = Uninstall.execute(roots: g.roots, options: Uninstall.Options(), services: g.services())
        try expect(!blocked.failures.isEmpty && !blocked.appRemoved && FileManager.default.fileExists(atPath: g.app)
                   && !g.recorder.events.contains { $0.hasPrefix("trash:") }, "app removed despite failure: \(blocked.steps) \(blocked.failures)")
    }

    check("uninstall: a Homebrew-managed app is not deleted and the brew commands are reported") {
        for style in ["caskroom", "link"] {
            let f = try UninstallFixture()
            if style == "caskroom" { try FileManager.default.createDirectory(atPath: f.brew + "/Caskroom/patched/0.2.2", withIntermediateDirectories: true) }
            else { try FileManager.default.createSymbolicLink(atPath: f.brew + "/bin/patched", withDestinationPath: f.app + "/Contents/Helpers/patched") }
            let plan = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services())
            try expect(plan.homebrewManaged && plan.items.first { $0.kind == .appBundle }?.status == .keep, "\(style): \(plan.report())")
            try expect(plan.report().contains("brew uninstall --cask patched") && plan.report().contains("brew untap birdseeed/patched"), "\(style): commands missing")
            let result = Uninstall.execute(roots: f.roots, options: Uninstall.Options(), services: f.services())
            try expect(result.isSuccess && !result.appRemoved && FileManager.default.fileExists(atPath: f.app)
                       && !f.recorder.events.contains { $0.hasPrefix("trash:") }, "\(style): app handled")
            try expect(result.homebrewAdvice?.contains("brew untap birdseeed/patched") == true, "\(style): advice")
        }
    }

    check("uninstall: another running Patched blocks, and keepLogs and keepApp are honoured") {
        let f = try UninstallFixture()
        let running = Uninstall.plan(roots: f.roots, options: Uninstall.Options(), services: f.services(running: [4242]))
        try expect(running.isBlocked && uninstallBlockedText(running).contains("Quit Patched first"), uninstallBlockedText(running))
        let g = try UninstallFixture()
        let result = Uninstall.execute(roots: g.roots, options: Uninstall.Options(keepLogs: true, keepApp: true), services: g.services())
        try expect(result.isSuccess && FileManager.default.fileExists(atPath: g.library + "/Logs/Patched/check.log")
                   && FileManager.default.fileExists(atPath: g.app) && !result.appRemoved, "keep options: \(result.steps)")
    }

    check("uninstall: the defaults file is removed even when emptying the domain leaves it on disk") {
        let f = try UninstallFixture()
        let prefs = f.library + "/Preferences/im.patched.app.plist"
        try expect(FileManager.default.fileExists(atPath: prefs), "fixture has no defaults file")
        var services = f.services()
        services.removeDefaults = { _ in }  // what the real removal does to the file: nothing
        let result = Uninstall.execute(roots: f.roots, options: Uninstall.Options(), services: services)
        try expect(result.isSuccess && !FileManager.default.fileExists(atPath: prefs), "defaults file left: \(result.failures)")
    }

    check("uninstall CLI: only uninstall gates --applications-root; the other commands still take it") {
        for command in ["check", "update", "rollback", "backups"] {
            let run = try runPatchedCLI([command, "--applications-root"], unsetting: ["PATCHED_FORBID_REAL_STATE"])
            try expect(run.output.contains("--applications-root needs a folder") && !run.output.contains("unknown argument"), "\(command): \(run)")
        }
        let gated = try runPatchedCLI(["uninstall", "--applications-root", "/tmp"], unsetting: ["PATCHED_FORBID_REAL_STATE"])
        try expect(gated.status == 2 && gated.output.contains("unknown argument --applications-root"), "uninstall: \(gated)")
    }

    check("uninstall CLI: dry run exits 0 and deletes nothing; blocked exits 1; usage errors exit 2; no terminal needs --yes") {
        let f = try UninstallFixture()
        let base = ["uninstall", "--library-root", f.library, "--app-bundle", f.app, "--applications-root", f.applications]
        let before = f.snapshot()
        let dry = try runPatchedCLI(base + ["--dry-run"])
        try expect(dry.status == 0 && dry.output.contains(f.library + "/Logs/Patched") && dry.output.contains("Backups are kept"), "dry run: \(dry)")
        let json = try runPatchedCLI(base + ["--dry-run", "--json"])
        let object = try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
        try expect(json.status == 0 && (object?["items"] as? [[String: Any]])?.isEmpty == false && object?["blocked"] as? Bool == false, "json: \(json.output)")
        try expectEqual(f.snapshot(), before, "dry run changed the disk")
        let usage = try runPatchedCLI(["uninstall", "--bogus"])
        try expect(usage.status == 2, "usage: \(usage)")
        let positional = try runPatchedCLI(["uninstall", "extra"])
        try expect(positional.status == 2, "positional: \(positional)")
        let noTTY = try runPatchedCLI(base)
        try expect(noTTY.status == 1 && noTTY.output.contains("--yes"), "no tty: \(noTTY)")
        try expectEqual(f.snapshot(), before, "unconfirmed run changed the disk")
        try f.writeJournal(.staging)
        let blocked = try runPatchedCLI(base + ["--yes"])
        try expect(blocked.status == 1 && blocked.output.contains("patched recover"), "blocked: \(blocked)")
        let blockedDry = try runPatchedCLI(base + ["--dry-run"])
        try expect(blockedDry.status == 0 && blockedDry.output.contains("BLOCKED"), "blocked dry run: \(blockedDry)")
        let go = try UninstallFixture()
        let done = try runPatchedCLI(["uninstall", "--library-root", go.library, "--app-bundle", go.app, "--applications-root", go.applications, "--yes"])
        try expect(done.status == 0 && done.output.contains("Login Items"), "done: \(done)")
        try expect(!FileManager.default.fileExists(atPath: go.library + "/Logs/Patched") && !FileManager.default.fileExists(atPath: go.app)
                   && FileManager.default.fileExists(atPath: go.support + "/backups/com.vendor.tool/1.0-1/Tool.app/Contents/Info.plist"), "cli run: \(done.output)")
        try expect(FileManager.default.fileExists(atPath: go.managed + "/im.patched.app.plist"), "managed prefs touched")
    }
}
