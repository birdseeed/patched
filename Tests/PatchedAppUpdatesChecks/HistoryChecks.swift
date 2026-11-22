import Foundation
import Darwin
import UpdateSources
import UpdateInstaller
import PatchedShell
@_spi(Testing) import PatchedClient

// The local update history: what each run records, the empty and deferred scheduled runs, retention and the file
// store. Everything is a fake or a temporary folder: no real clock, Library folder, timer or installer.

private let gmt: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "GMT")!
    return calendar
}()
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    gmt.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}
private struct NoManaged: ManagedPreferenceReading {
    func isForced(_ key: String) -> Bool { false }
    func forcedValue(forKey key: String) -> Any? { nil }
}
@MainActor private func automaticOn() -> AutomaticUpdateSettings {
    let store = MemoryAutomaticUpdateStore()
    store.enabled = true; store.time = TimeOfDay(string: "02:00")!
    return AutomaticUpdateSettings(store: store, managed: ManagedPreferences(reader: NoManaged()))
}
/// A scheduler rig with automatic updates on, due now, and a memory history on its controller.
@MainActor private func historyRig(_ outcomes: [AppCheckOutcome], installer: FakeInstaller = FakeInstaller()) -> (Rig, MemoryHistoryStore) {
    let rig = Rig(outcomes, installer: installer, automatic: automaticOn(), calendar: gmt)
    rig.clock.date = at(11, 2, 0)
    let store = MemoryHistoryStore()
    rig.controller.history = store
    rig.controller.historyNow = { rig.clock.date }
    return (rig, store)
}
private func temporaryFolder() throws -> String {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("patched-history-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return FileSafety.realPath(base) ?? base
}
private func run(_ start: Date, trigger: HistoryRun.Trigger = .updateAll, items: [HistoryItem] = []) -> HistoryRun {
    HistoryRun(startedAt: start, finishedAt: start, trigger: trigger, appsChecked: 3, updatesFound: items.count, items: items)
}

@MainActor func registerHistoryChecks() {
    check("history: Update All records one run, each app mapped from its step, with the Updates screen's wording") {
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            switch outcome.app.name {
            case "Bravo": throw InstallRefusal.signatureInvalid("bad seal")
            case "Charlie": throw InstallRefusal.appRunning("open")
            default: return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
            }
        }
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))),
                                                   outcome(app("Bravo"), .updateAvailable(offer("3.0"))),
                                                   outcome(app("Charlie"), .updateAvailable(offer("4.0"))),
                                                   outcome(app("Delta"), .upToDate)], installer: installer)
        let store = MemoryHistoryStore()
        controller.history = store
        await runCheck(controller)
        var seenAtFinish: UUID?
        await runOperation(controller) { _ = controller.updateAll(onFinished: { _ in seenAtFinish = controller.lastRun?.id }) }
        let runs = store.runs()
        try expect(runs.count == 1, "runs: \(runs.count)")
        let run = runs[0]
        try expect(run.trigger == .updateAll && run.appsChecked == 4 && run.updatesFound == 3 && run.outcome == .partial,
                   "run: \(run.trigger) \(run.appsChecked) \(run.updatesFound) \(run.outcome)")
        try expect(seenAtFinish == run.id && controller.lastRun == run, "the run was not recorded before onFinished")
        let byName = Dictionary(run.items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try expect(byName["Alpha"]?.result == .updated && byName["Alpha"]?.oldVersion == "1.0" && byName["Alpha"]?.newVersion == "2.0"
                   && byName["Alpha"]?.bundleID == "com.example.alpha", "Alpha: \(String(describing: byName["Alpha"]))")
        try expect(byName["Bravo"]?.result == .failed && byName["Bravo"]?.detail == "signature_invalid" && byName["Bravo"]?.newVersion == nil
                   && byName["Charlie"]?.newVersion == nil
                   && byName["Bravo"]?.reason == controller.row(id: "/Fake/Bravo.app")?.result?.text && byName["Bravo"]?.reason != nil,
                   "Bravo: \(String(describing: byName["Bravo"]))")
        try expect(byName["Charlie"]?.result == .skippedOpen && byName["Charlie"]?.reason?.contains("is open") == true,
                   "Charlie: \(String(describing: byName["Charlie"]))")
        try expect(byName["Delta"] == nil && run.hasFailures, "an up-to-date app was listed, or failures not flagged")
        try expect(run.summary == "1 updated, 1 failed, 1 skipped because open", "summary: \(run.summary)")
    }

    check("history: an app that updated itself while Patched worked is a success, counted as updated, and recorded as updated_itself") {
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Bravo" { throw InstallRefusal.updatedItself("Bravo.app is now 3.0 (300)") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))),
                                                   outcome(app("Bravo"), .updateAvailable(offer("3.0")))], installer: installer)
        let store = MemoryHistoryStore()
        controller.history = store
        await runCheck(controller)
        await runOperation(controller) { _ = controller.updateAll() }
        let row = controller.row(id: "/Fake/Bravo.app")
        let expected = PlainRefusalText.text(name: "Bravo", .updatedItself("Bravo.app is now 3.0 (300)"))
        try expect(row?.result?.kind == .success && row?.result?.text == expected, "row result: \(String(describing: row?.result))")
        try expect(controller.summary == "2 updated.", "summary: \(controller.summary)")
        let run = store.runs().first
        let item = run?.items.first { $0.name == "Bravo" }
        try expect(run?.outcome == .updated && run?.hasFailures == false && item?.result == .updated && item?.detail == "updated_itself",
                   "history: \(String(describing: run))")
    }

    check("history: a single app's update is its own run, and a Cancel is recorded as cancelled, not failed") {
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))),
                                                   outcome(app("Bravo"), .updateAvailable(offer("3.0")))])
        let store = MemoryHistoryStore()
        controller.history = store
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: "/Fake/Alpha.app") }
        try expect(store.runs().first?.trigger == .singleApp && store.runs().first?.items.map(\.name) == ["Alpha"]
                   && store.runs().first?.outcome == .updated, "single: \(String(describing: store.runs().first))")
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in throw CancellationError() }
        let cancelled = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0")))], installer: installer)
        let other = MemoryHistoryStore()
        cancelled.history = other
        await runCheck(cancelled)
        await runOperation(cancelled) { cancelled.update(id: "/Fake/Alpha.app") }
        try expect(other.runs().first?.items.first?.result == .cancelled && other.runs().first?.hasFailures == false
                   && other.runs().first?.outcome == .nothingInstalled, "cancel: \(String(describing: other.runs().first))")
    }

    check("history: without a store nothing is recorded and nothing changes") {
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        await runCheck(controller)
        await runOperation(controller) { _ = controller.updateAll() }
        try expect(controller.lastRun == nil && controller.history == nil, "recorded with no store")
    }

    check("history: a scheduled run with nothing to install is recorded as 'Checked N apps, all up to date'") {
        let (rig, store) = historyRig([outcome(app("Alpha"), .upToDate), outcome(app("Bravo"), .upToDate)])
        rig.scheduler.start(); await rig.settle()
        let runs = store.runs()
        try expect(runs.count == 1 && runs[0].trigger == .scheduled && runs[0].outcome == .upToDate && runs[0].items.isEmpty,
                   "runs: \(runs)")
        try expect(runs[0].summary == "Checked 2 apps, all up to date", "summary: \(runs[0].summary)")
        try expect(updateEvents(rig.installer).isEmpty && rig.controller.updateAllInvocations == 1, "it installed or skipped updateAll")
        // A second check the same day is not a second run.
        rig.clock.advance(UpdateCheckScheduler.interval); try rig.timer.fireActive(); await rig.settle()
        try expect(store.runs().count == 1, "a second scheduled run the same day: \(store.runs().count)")
        // Updates on offer that the automatic run may not install: found, none installed.
        let (store2Rig, store2) = historyRig([outcome(app("Alpha"), .updateAvailable(offer("2.0", format: .pkg)))])
        store2Rig.scheduler.start(); await store2Rig.settle()
        try expect(store2.runs().first?.outcome == .nothingInstalled && store2.runs().first?.updatesFound == 1
                   && store2.runs().first?.summary == "1 update found, none installed automatically",
                   "pkg-only: \(String(describing: store2.runs().first?.summary))")
    }

    check("history: an app whose check failed is not counted as up to date") {
        let (rig, store) = historyRig([outcome(app("Alpha"), .upToDate), outcome(app("Bravo"), .upToDate),
                                       outcome(app("Charlie"), .refused(.network("feed returned 500")))])
        rig.scheduler.start(); await rig.settle()
        let run = store.runs().first
        try expect(run?.appsChecked == 2 && run?.summary == "Checked 2 apps, all up to date, couldn't check 1 app",
                   "summary: \(String(describing: run?.summary)) checked \(String(describing: run?.appsChecked))")
    }

    check("history: a scheduled run that installs is recorded once, as scheduled") {
        let (rig, store) = historyRig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("Bravo"), .upToDate)])
        rig.scheduler.start(); await rig.settle()
        try expect(store.runs().count == 1 && store.runs()[0].trigger == .scheduled && store.runs()[0].outcome == .updated
                   && store.runs()[0].items.map(\.name) == ["Alpha"], "runs: \(store.runs())")
    }

    check("history: a scheduled run that must wait is recorded once as deferred with the reason, however often it retries") {
        let (rig, store) = historyRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        rig.installer.unreadable = ["/Fake/journal"]
        rig.scheduler.start(); await rig.settle()
        for _ in 0..<3 {
            guard let retry = rig.timer.active.first(where: { $0.delay == UpdateCheckScheduler.deferDelay }) else {
                throw CheckFailure(description: "no retry armed while blocked")
            }
            rig.clock.advance(UpdateCheckScheduler.deferDelay)
            retry.fired = true; retry.fire(); await rig.settle()
        }
        let runs = store.runs()
        try expect(runs.count == 1 && runs[0].outcome == .deferred && runs[0].trigger == .scheduled, "runs: \(runs)")
        try expect(runs[0].note == "an unfinished update record can't be read, so installing was paused"
                   && runs[0].summary.hasPrefix("Waited: "), "reason: \(String(describing: runs[0].note))")
        // Unblocked: the real run is recorded beside the wait.
        rig.installer.unreadable = []
        await rig.controller.refreshInstallerState()
        let retry = rig.timer.active.first { $0.delay == UpdateCheckScheduler.deferDelay }
        retry?.fired = true; retry?.fire(); await rig.settle()
        try expect(store.runs().count == 2 && store.runs()[0].outcome == .updated, "after unblocking: \(store.runs().map(\.outcome))")
    }

    check("history retention: 90 days or the last 500 runs, whichever is smaller") {
        let now = at(15, 12)
        let day: TimeInterval = 24 * 60 * 60
        let old = (0..<20).map { run(now.addingTimeInterval(-Double(91 + $0) * day)) }
        let recent = (0..<30).map { run(now.addingTimeInterval(-Double($0) * day)) }
        let kept = HistoryRetention.apply(old + recent, now: now)
        try expect(kept.count == 30 && kept.allSatisfy { now.timeIntervalSince($0.startedAt) <= 90 * day }, "age: \(kept.count)")
        try expect(kept.first?.startedAt == now, "not newest first")
        let many = (0..<700).map { run(now.addingTimeInterval(-Double($0) * 60)) }
        let capped = HistoryRetention.apply(many, now: now)
        try expect(capped.count == 500 && capped.first?.startedAt == now, "cap: \(capped.count)")
        let store = MemoryHistoryStore(runs: old + recent)
        store.prune(now: now)
        try expect(store.runs().count == 30, "memory prune: \(store.runs().count)")
    }

    check("history file: records and reads back, 0600, prunes, and two writers never lose each other's runs") {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let app = FileHistoryStore(folder: { folder + "/Patched" })
        let cli = FileHistoryStore(folder: { folder + "/Patched" })
        try expect(app.runs().isEmpty, "a missing file is not an empty history")
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let first = run(now.addingTimeInterval(-60), items: [HistoryItem(name: "Alpha", bundleID: "a", oldVersion: "1", newVersion: "2",
                                                                         result: .updated, reason: "Alpha: updated")])
        app.record(first)
        cli.record(run(now, trigger: .commandLine))
        app.record(run(now.addingTimeInterval(-100 * 24 * 60 * 60)))
        let path = folder + "/Patched/history.json"
        var info = stat()
        try expect(lstat(path, &info) == 0 && (info.st_mode & 0o777) == 0o600, "file mode: \(String(info.st_mode & 0o777, radix: 8))")
        let read = cli.runs()
        try expect(read.count == 3 && read[0].trigger == .commandLine && read[1] == first, "read back: \(read.map(\.trigger))")
        app.prune(now: now)
        try expect(cli.runs().count == 2, "prune: \(cli.runs().count)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder + "/Patched").filter { $0.hasPrefix(".tmp-") }
        try expect(leftovers.isEmpty, "temporary files left: \(leftovers)")
    }

    check("history file: an unreadable file is kept aside, never overwritten, and reads as empty") {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/history.json"
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        let store = FileHistoryStore(folder: { folder })
        try expect(store.runs().isEmpty, "garbage read as runs")
        store.record(run(Date()))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder)
        let aside = names.filter { $0.hasPrefix("history.json.unreadable-") }
        try expect(aside.count == 1, "files: \(names)")
        try expect(try String(contentsOfFile: folder + "/" + aside[0], encoding: .utf8) == "not json", "the old file was changed")
        try expect(store.runs().count == 1, "the new run was not recorded")
        // No folder: records nothing, and never fails the caller.
        let nowhere = FileHistoryStore(folder: { nil })
        nowhere.record(run(Date()))
        try expect(nowhere.runs().isEmpty, "a store with no folder recorded")
    }

    check("history file: a file from a newer Patched is left exactly as it is") {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let newer = #"{"version":2,"runs":[{"something":"new"}]}"#
        try Data(newer.utf8).write(to: URL(fileURLWithPath: folder + "/history.json"))
        let store = FileHistoryStore(folder: { folder })
        store.record(run(Date()))
        store.prune(now: Date())
        let names = try FileManager.default.contentsOfDirectory(atPath: folder).filter { !$0.hasPrefix(".") }
        try expect(names == ["history.json"] && (try String(contentsOfFile: folder + "/history.json", encoding: .utf8)) == newer,
                   "a newer history was changed or moved: \(names)")
    }

    check("history file: the standard store keeps to memory under the test tripwire") {
        let before = RealStateTripwire.tripCount
        let store = FileHistoryStore.standard()
        store.record(run(Date()))
        try expect(store.runs().count == 1 && RealStateTripwire.tripCount == before, "the standard store touched real state")
    }
}

@MainActor private final class RunIDSummaries: UpdateSummaryNotifying {
    var automatic: [(UpdateAllSummary, UUID?)] = []
    func notify(summary: UpdateAllSummary) {}
    func notify(automaticSummary: UpdateAllSummary, historyRunID: UUID?) { automatic.append((automaticSummary, historyRunID)) }
}

private func item(_ name: String, _ result: HistoryItem.Result, id: String? = nil) -> HistoryItem {
    HistoryItem(name: name, bundleID: id ?? "com.example.\(name.lowercased())", oldVersion: "1.0", newVersion: result == .updated ? "2.0" : nil,
                result: result, reason: "\(name): \(result.rawValue)")
}

@MainActor func registerHistoryScreenChecks() {
    check("history screen: runs grouped by day, newest first, with Today and Yesterday") {
        let now = at(15, 12)
        let runs = [run(at(15, 3), items: [item("Alpha", .updated)]), run(at(14, 9)), run(at(15, 10)), run(at(12, 3))]
        let days = HistoryModel.days(runs, calendar: gmt)
        try expect(days.map(\.start) == [at(15, 0), at(14, 0), at(12, 0)], "days: \(days.map(\.start))")
        try expect(days[0].runs.map(\.startedAt) == [at(15, 10), at(15, 3)], "within a day: \(days[0].runs.map(\.startedAt))")
        let uk = Locale(identifier: "en_GB")
        try expect(HistoryModel.dayTitle(at(15, 0), now: now, calendar: gmt, locale: uk) == "Today"
                   && HistoryModel.dayTitle(at(14, 0), now: now, calendar: gmt, locale: uk) == "Yesterday"
                   && HistoryModel.dayTitle(at(12, 0), now: now, calendar: gmt, locale: uk).contains("12 November 2026"),
                   "titles: \(HistoryModel.dayTitle(at(12, 0), now: now, calendar: gmt, locale: uk))")
    }

    check("history screen: Failures only and one app narrow both the runs and the apps inside them") {
        let mixed = run(at(15, 3), items: [item("Alpha", .updated), item("Bravo", .failed)])
        let clean = run(at(14, 3), items: [item("Alpha", .updated)])
        let empty = run(at(13, 3))
        let all = [mixed, clean, empty]
        try expect(HistoryModel.visibleRuns(all, failuresOnly: false, app: nil).count == 3, "all")
        let failures = HistoryModel.visibleRuns(all, failuresOnly: true, app: nil)
        try expect(failures.map(\.id) == [mixed.id] && failures[0].items.map(\.name) == ["Bravo"]
                   && failures[0].outcome == mixed.outcome, "failures: \(failures.map { $0.items.map(\.name) })")
        let alpha = HistoryModel.visibleRuns(all, failuresOnly: false, app: "com.example.alpha")
        try expect(alpha.map(\.id) == [mixed.id, clean.id] && alpha.allSatisfy { $0.items.map(\.name) == ["Alpha"] }, "per app")
        try expect(HistoryModel.visibleRuns(all, failuresOnly: true, app: "com.example.alpha").isEmpty, "Alpha never failed")
        try expect(HistoryModel.apps(all).map(\.name) == ["Alpha", "Bravo"], "apps: \(HistoryModel.apps(all).map(\.name))")
        try expect(!HistoryModel.accessibilityLabel(clean, calendar: gmt).contains("failed")
                   && HistoryModel.accessibilityLabel(mixed, calendar: gmt).hasPrefix("Something failed."), "VoiceOver label")
    }

    check("history menu: a 'Last run' line only when something failed, marked, that opens the run in History") {
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), appUpdates: controller, urlOpener: RecordingOpener())
        try expect(!session.menuItems.contains { $0.id == "last-run" }, "a last-run line with no history")
        let store = MemoryHistoryStore()
        controller.history = store
        await runCheck(controller)
        await runOperation(controller) { _ = controller.updateAll() }
        // A clean run adds nothing to the menu; History still has it.
        try expect(controller.lastRun != nil && !session.menuItems.contains { $0.id == "last-run" }, "a last-run line for a clean run")
        let failing = HistoryRun(startedAt: at(15, 3), finishedAt: at(15, 3), trigger: .scheduled, appsChecked: 4, updatesFound: 2,
                                 items: [item("Alpha", .updated), item("Bravo", .failed)])
        try expect(HistoryModel.lastRunLine(failing, now: at(15, 12), calendar: gmt, locale: Locale(identifier: "en_GB"))
                   == "Last run: today 03:00, 1 updated, 1 failed", HistoryModel.lastRunLine(failing, now: at(15, 12), calendar: gmt,
                                                                                               locale: Locale(identifier: "en_GB")))
        let later = Date().addingTimeInterval(60)
        let newest = HistoryRun(startedAt: later, finishedAt: later, trigger: .scheduled, appsChecked: 4, updatesFound: 2, items: failing.items)
        store.record(newest)
        controller.reloadHistory()
        let line = session.menuItems.filter { $0.id == "last-run" }
        try expect(line.count == 1 && line[0].systemImage == "exclamationmark.triangle" && line[0].title.hasPrefix("Last run: ")
                   && line[0].action == .showHistory(runID: newest.id), "failure line: \(line)")
        // A run that waited and installed nothing is shown too, without the warning sign.
        let waitedAt = later.addingTimeInterval(60)
        let waited = HistoryRun(startedAt: waitedAt, finishedAt: waitedAt, trigger: .scheduled, appsChecked: 4, updatesFound: 2,
                                outcome: .deferred, note: "on battery", items: [])
        store.record(waited)
        controller.reloadHistory()
        let waitedLine = session.menuItems.filter { $0.id == "last-run" }
        try expect(waitedLine.count == 1 && waitedLine[0].systemImage == nil && waitedLine[0].action == .showHistory(runID: waited.id),
                   "waited line: \(waitedLine)")
        // Choosing it opens History at that run.
        try expect(session.showHistory(runID: newest.id) && session.navigation.destination == .history
                   && session.history.focusedRunID == newest.id && session.history.expanded.contains(newest.id)
                   && session.history.runs.count == 3, "did not open History at the run")
    }

    check("history notification: the automatic summary names its run, and clicking it opens that run in History") {
        let summaries = RunIDSummaries()
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], automatic: automaticOn(), summaryNotifier: summaries, calendar: gmt)
        rig.clock.date = at(11, 2, 0)
        let store = MemoryHistoryStore()
        rig.controller.history = store
        rig.scheduler.start(); await rig.settle()
        try expect(summaries.automatic.count == 1 && summaries.automatic[0].1 == store.runs().first?.id && summaries.automatic[0].1 != nil,
                   "run id: \(summaries.automatic.map(\.1)) vs \(String(describing: store.runs().first?.id))")
        // The click, including one that launched the app before a handler was set.
        let notifier = SystemUpdateNotifier()
        var opened: [UUID] = [], updates = 0
        notifier.onOpenUpdates = { updates += 1 }
        let id = UUID()
        let info: [AnyHashable: Any] = [SystemUpdateNotifier.historyRunUserInfoKey: id.uuidString]
        notifier.handle(requestIdentifier: SystemUpdateNotifier.summaryIdentifier,
                        actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info)
        notifier.onOpenHistory = { opened.append($0) }
        try expect(opened == [id] && updates == 0, "a launching click was not delivered to History: \(opened) \(updates)")
        notifier.handle(requestIdentifier: SystemUpdateNotifier.summaryIdentifier,
                        actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info)
        try expect(opened == [id, id] && updates == 0, "second click: \(opened)")
        // A summary without a run id (Update All finished) still opens Updates.
        notifier.handle(requestIdentifier: SystemUpdateNotifier.summaryIdentifier,
                        actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier")
        try expect(updates == 1 && opened.count == 2, "a plain summary did not open Updates")
    }
}

@MainActor func registerHistoryAppsLineChecks() {
    check("history: a closed run names its apps, updated first, with versions when there is one") {
        let at3 = at(15, 3)
        func names(_ items: [HistoryItem]) -> String? {
            HistoryModel.appsLine(HistoryRun(startedAt: at3, finishedAt: at3, trigger: .updateAll, appsChecked: 9, updatesFound: items.count, items: items))
        }
        try expect(names([]) == nil, "no apps: \(String(describing: names([])))")
        try expect(names([item("DuckDuckGo", .updated)]) == "DuckDuckGo 1.0 → 2.0", "one: \(String(describing: names([item("DuckDuckGo", .updated)])))")
        let bare = HistoryItem(name: "Tool", bundleID: nil, oldVersion: nil, newVersion: nil, result: .failed, reason: nil)
        try expect(names([bare]) == "Tool", "no versions: just the name")
        try expect(names([item("Bravo", .failed)]) == "Bravo 1.0", "one failed shows only its version")
        try expect(names([item("Bravo", .failed), item("Alpha", .updated)]) == "Alpha and Bravo", "updated first")
        try expect(names([item("A", .updated), item("B", .updated), item("C", .skippedOpen)]) == "A, B and C", "three")
        let five = names(["A", "B", "C", "D", "E"].map { item($0, .updated) })
        try expect(five == "A, B, C and 2 more", "five: \(String(describing: five))")
        let run = HistoryRun(startedAt: at3, finishedAt: at3, trigger: .updateAll, appsChecked: 9, updatesFound: 1, items: [item("DuckDuckGo", .updated)])
        try expect(HistoryModel.accessibilityLabel(run, calendar: gmt).hasSuffix(". DuckDuckGo 1.0 → 2.0"), "VoiceOver names the app")
    }
}

@MainActor func registerHistoryRenderChecks() {
    check("history screen: renders its days, runs and filters in light and dark, with no em dash") {
        let controller = makeController(outcomes: [])
        let failing = HistoryRun(startedAt: Date(), finishedAt: Date(), trigger: .scheduled, appsChecked: 4, updatesFound: 2,
                                 items: [item("Alpha", .updated), item("Bravo", .failed)])
        let store = MemoryHistoryStore(runs: [failing, run(Date().addingTimeInterval(-86_400))])
        controller.history = store
        let history = HistoryController(store: { store })
        history.reload()
        let light = try paintView(HistoryView(history: history, updates: controller), width: 820, height: 480)
        let dark = try paintView(HistoryView(history: history, updates: controller), width: 820, height: 480, dark: true)
        try expect(light.count > 5_000 && dark.count > 5_000 && light != dark, "renders look blank")
        if let dir = ProcessInfo.processInfo.environment["PATCHED_HISTORY_PNG_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try light.write(to: URL(fileURLWithPath: dir + "/history.png")); try dark.write(to: URL(fileURLWithPath: dir + "/history-dark.png"))
            history.focus(runID: failing.id)
            try paintView(HistoryView(history: history, updates: controller), width: 820, height: 480)
                .write(to: URL(fileURLWithPath: dir + "/history-expanded.png"))
        }
        let text = try paintedText(HistoryView(history: history, updates: controller))
        for expected in ["Today", "Yesterday", "Scheduled", "1 updated, 1 failed", "Alpha and Bravo", "Failures only", "All apps", "kept on this Mac"] {
            try expect(text.contains(expected), "History text lacks \(expected): \(text)")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/PatchedClient/HistoryView.swift", "Sources/PatchedClient/UpdateHistory.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            try expect(!source.contains("\u{2014}"), "em dash in \(file)")
        }
        let empty = HistoryController(store: { MemoryHistoryStore() })
        try expect(try paintedText(HistoryView(history: empty, updates: controller)).contains("No update runs yet"), "empty state")
    }
}

@MainActor func registerHistoryExportChecks() {
    check("history CSV: one row per app, one for a run with none, quoted, and never a spreadsheet formula") {
        let tricky = HistoryItem(name: "=HYPERLINK(\"x\")", bundleID: "com.example.tricky", oldVersion: "1.0", newVersion: "2.0",
                                 result: .failed, reason: "Tricky: a, b\nand \"c\"", detail: "-signature_invalid")
        let withApps = HistoryRun(startedAt: at(15, 3), finishedAt: at(15, 3, 2), trigger: .scheduled, appsChecked: 5, updatesFound: 2,
                                  items: [item("Alpha", .updated), tricky])
        let empty = run(at(14, 3))
        let text = HistoryCSV.text([empty, withApps], timeZone: TimeZone(identifier: "GMT")!)
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        try expect(lines.first == HistoryCSV.header.joined(separator: ","), "header: \(lines.first ?? "")")
        try expect(text.hasPrefix("Run ID,Started,") && text.hasSuffix("\r\n"), "framing")
        try expect(lines.count == 4, "lines (the quoted newline is not a record break): \(lines.count)\n\(text)")
        try expect(lines[1].hasPrefix(withApps.id.uuidString + ",2026-11-15T03:00:00Z,2026-11-15T03:02:00Z,Scheduled,partial,"),
                   "newest first with GMT times: \(lines[1])")
        try expect(lines[1].hasSuffix(",Alpha,com.example.alpha,1.0,2.0,Updated,Alpha: updated,"), "Alpha row: \(lines[1])")
        try expect(text.contains(",'=HYPERLINK(\"\"x\"\")\",") || text.contains(",\"'=HYPERLINK(\"\"x\"\")\","), "formula not neutralised: \(text)")
        try expect(text.contains("\"Tricky: a, b\nand \"\"c\"\"\"") && text.contains(",'-signature_invalid"), "quoting: \(text)")
        try expect(lines.last?.hasPrefix(empty.id.uuidString) == true && lines.last?.hasSuffix(",,,,,,,") == true, "empty run row: \(lines.last ?? "")")
    }

    check("history CSV: a formula after leading spaces is neutralised too") {
        let spaced = HistoryItem(name: "  =1+1", bundleID: "com.example.spaced", oldVersion: "1.0", newVersion: nil,
                                 result: .failed, reason: "\u{00A0}+SUM(A1)", detail: nil)
        let text = HistoryCSV.text([HistoryRun(startedAt: at(15, 3), finishedAt: at(15, 3, 1), trigger: .scheduled, appsChecked: 1,
                                               updatesFound: 1, items: [spaced])], timeZone: TimeZone(identifier: "GMT")!)
        try expect(text.contains(",'  =1+1,") && text.contains(",'\u{00A0}+SUM(A1),"), "spaced formula not neutralised: \(text)")
        for value in ["\u{3000}=1", "\u{FEFF}+1", "\u{2009}-1", " \t1"] {
            try expect(HistoryCSV.cell(value).hasPrefix("'") || HistoryCSV.cell(value).hasPrefix("\"'"), "not neutralised: \(value.debugDescription)")
        }
        try expect(HistoryCSV.cell("  Alpha") == "  Alpha" && HistoryCSV.cell("1.0") == "1.0", "plain text changed")
    }

    check("history CSV: the optional date range includes whole days at both ends") {
        let runs = [run(at(10, 23, 59)), run(at(11, 0, 0)), run(at(12, 12)), run(at(13, 23, 59)), run(at(14, 0, 0))]
        let picked = HistoryCSV.runs(runs, from: at(11, 15), to: at(13, 1), calendar: gmt)
        try expect(picked.map(\.startedAt) == [at(13, 23, 59), at(12, 12), at(11, 0, 0)], "range: \(picked.map(\.startedAt))")
        try expect(HistoryCSV.runs(runs, from: nil, to: nil, calendar: gmt).count == 5, "no range")
    }

    check("history export: only the Export… button writes, through a save panel, and nothing is sent") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/PatchedClient/HistoryView.swift"), encoding: .utf8)
        try expect(view.components(separatedBy: "NSSavePanel()").count == 2 && view.contains("panel.begin { response in")
                   && view.contains("guard response == .OK, let url = panel.url"), "save panel missing or duplicated")
        try expect(view.components(separatedBy: "data.write(to: url").count == 2 && view.contains("Button(action: export)"),
                   "the file is written somewhere other than the save panel's answer")
        for forbidden in ["URLSession", "URLRequest", ".onAppear { export", "Task { export"] {
            try expect(!view.contains(forbidden), "History view contains \(forbidden)")
        }
        let model = try String(contentsOf: root.appendingPathComponent("Sources/PatchedClient/UpdateHistory.swift"), encoding: .utf8)
        for forbidden in ["URLSession", "URLRequest", "HTTPFetching", "NSSavePanel"] {
            try expect(!model.contains(forbidden), "UpdateHistory contains \(forbidden)")
        }
    }
}
