import Foundation
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

// Automatic updates at a set time: the once-a-day timing rule on a fake clock, the managed (MDM) override, what
// the automatic run will and will not install, and its summary. Everything is a fake: no real clock, timer,
// preferences, notification centre or Applications folder.

private let gmt: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "GMT")!
    return calendar
}()
/// 2026-11-<day> at hour:minute GMT.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    gmt.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

/// Forced preferences for the managed reader. An empty dictionary means nothing is managed.
private struct FakeManaged: ManagedPreferenceReading {
    var forced: [String: Any] = [:]
    func isForced(_ key: String) -> Bool { forced[key] != nil }
    func forcedValue(forKey key: String) -> Any? { forced[key] }
}

@MainActor private final class AutoSummaries: UpdateSummaryNotifying {
    var automatic: [UpdateAllSummary] = []
    var plain: [UpdateAllSummary] = []
    func notify(summary: UpdateAllSummary) { plain.append(summary) }
    func notify(automaticSummary: UpdateAllSummary) { automatic.append(automaticSummary) }
}

@MainActor private func settings(enabled: Bool = true, time: String = "02:00", lastRunDay: String? = nil,
                                 managed: [String: Any] = [:]) -> (AutomaticUpdateSettings, MemoryAutomaticUpdateStore) {
    let store = MemoryAutomaticUpdateStore()
    store.enabled = enabled; store.time = TimeOfDay(string: time)!; store.lastRunDay = lastRunDay
    return (AutomaticUpdateSettings(store: store, managed: ManagedPreferences(reader: FakeManaged(forced: managed))), store)
}

@MainActor private func autoRig(_ outcomes: [AppCheckOutcome], now: Date, settings: AutomaticUpdateSettings,
                                summaries: AutoSummaries = AutoSummaries(), installer: FakeInstaller = FakeInstaller(),
                                gated: Bool = false, keepUpdatesOffered: Bool = false, packageUpdates: Bool = false) -> Rig {
    let rig = Rig(outcomes, gated: gated, installer: installer, packageUpdates: packageUpdates,
                  automatic: settings, summaryNotifier: summaries, calendar: gmt)
    rig.clock.date = now
    // Leaves the updates on offer after an install, so a second pass would install again if the rule allowed it.
    if keepUpdatesOffered { rig.installer.world = nil }
    return rig
}

@MainActor private func installs(_ rig: Rig) -> [String] { updateEvents(rig.installer) }

@MainActor func registerAutomaticUpdateChecks() {
    check("automatic: off by default, and when off a due time installs nothing") {
        let (fresh, _) = settings(enabled: false)
        try expect(!AutomaticUpdateSettings(store: MemoryAutomaticUpdateStore(), managed: ManagedPreferences(reader: FakeManaged())).isEnabled
                   && !fresh.isEnabled, "automatic updates are on by default")
        try expect(TimeOfDay.default.string == "02:00", "default time: \(TimeOfDay.default.string)")
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 2, 5), settings: fresh)
        rig.scheduler.start(); await rig.settle()
        try rig.noInstallerActivity()
        try expect(rig.notifier.posted.count == 1 && fresh.lastRunDay == nil, "off: the normal notification should post and no run be recorded")
    }

    check("automatic: due at the chosen time installs once, records the day and posts one summary") {
        let (s, _) = settings()
        let summaries = AutoSummaries()
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: s, summaries: summaries)
        rig.scheduler.start(); await rig.settle()
        try expect(installs(rig) == ["update Alpha quit=false"], "events: \(installs(rig))")
        try expect(s.lastRunDay == "2026-11-11", "day: \(String(describing: s.lastRunDay))")
        try expect(summaries.automatic == [UpdateAllSummary(updated: 1, failed: 0, skippedOpen: 0, needsAdmin: 0)] && summaries.plain.isEmpty,
                   "summaries: \(summaries.automatic) \(summaries.plain)")
        try expect(rig.notifier.posted.isEmpty, "an 'updates available' notification was posted before the automatic run")
        try expect(rig.controller.rows.first?.status == .upToDate, "row after the run: \(String(describing: rig.controller.rows.first?.status))")
    }

    check("automatic: before the chosen time nothing installs; the next check after it does") {
        let (s, _) = settings()
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 1, 30), settings: s)
        rig.scheduler.start(); await rig.settle()
        try expect(installs(rig).isEmpty && s.lastRunDay == nil, "installed before 02:00")
        try expect(rig.notifier.posted.count == 1, "the early check should announce the update as usual")
        rig.clock.advance(30 * 60); try rig.timer.fireActive(); await rig.settle()
        try expect(installs(rig).isEmpty, "installed when the 3-hour timer had not come due")
        rig.clock.advance(3 * 60 * 60); try rig.timer.fireActive(); await rig.settle()
        try expect(installs(rig) == ["update Alpha quit=false"], "the 04:30 check did not install: \(installs(rig))")
    }

    check("automatic: a Mac that was asleep or a Patched that was not running still runs within 6 hours, not after") {
        for (hour, minute, expectRun) in [(7, 59, true), (8, 0, true), (8, 1, false), (23, 0, false)] {
            let (s, _) = settings()
            let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, hour, minute), settings: s)
            rig.scheduler.start(); await rig.settle()
            try expect((installs(rig).count == 1) == expectRun, "\(hour):\(minute) expected run=\(expectRun), events \(installs(rig))")
            try expect((s.lastRunDay != nil) == expectRun, "\(hour):\(minute) recorded day \(String(describing: s.lastRunDay))")
        }
        // A missed window waits for the next day.
        let (s, _) = settings()
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 9, 0), settings: s, keepUpdatesOffered: true)
        rig.scheduler.start(); await rig.settle()
        try expect(installs(rig).isEmpty, "ran after the window")
        rig.clock.date = at(12, 2, 10); rig.wake.wake(); try rig.timer.fireActive(); await rig.settle()
        try rig.timer.fireActive(); await rig.settle()
        try expect(installs(rig) == ["update Alpha quit=false"] && s.lastRunDay == "2026-11-12", "next day: \(installs(rig)) \(String(describing: s.lastRunDay))")
    }

    check("automatic: never twice in a day, a new day runs again, and a relaunch the same day does not rerun it") {
        let (s, store) = settings()
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: s, keepUpdatesOffered: true)
        rig.scheduler.start(); await rig.settle()
        try expect(installs(rig).count == 1, "first run: \(installs(rig))")
        // More checks inside the window, with the update still on offer: no second run.
        for _ in 0..<2 { rig.clock.advance(UpdateCheckScheduler.interval); try rig.timer.fireActive(); await rig.settle() }
        try expect(installs(rig).count == 1 && rig.controller.updateAllInvocations == 1, "a second run the same day: \(installs(rig))")
        // Patched is quit and reopened the same day: the stored day stops a rerun.
        rig.scheduler.stop()
        let again = AutomaticUpdateSettings(store: store, managed: ManagedPreferences(reader: FakeManaged()))
        let relaunched = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 3, 0), settings: again, keepUpdatesOffered: true)
        relaunched.scheduler.start(); await relaunched.settle()
        try expect(installs(relaunched).isEmpty && relaunched.controller.updateAllInvocations == 0, "relaunch reran: \(installs(relaunched))")
        // The next day it runs again.
        relaunched.clock.date = at(12, 2, 30); relaunched.wake.wake(); try relaunched.timer.fireActive(); await relaunched.settle()
        try relaunched.timer.fireActive(); await relaunched.settle()
        try expect(installs(relaunched).count == 1 && store.lastRunDay == "2026-11-12", "next day: \(installs(relaunched)) \(String(describing: store.lastRunDay))")
    }

    check("automatic: a check that mostly failed offline does not run it, and the next good check inside the window does") {
        let (s, _) = settings()
        let rig = autoRig([outcome(app("Alpha"), .refused(.offline("down"))), outcome(app("Bravo"), .refused(.offline("down")))],
                          now: at(11, 2, 0), settings: s)
        rig.scheduler.start(); await rig.settle()
        try expect(installs(rig).isEmpty && s.lastRunDay == nil && rig.controller.updateAllInvocations == 0, "ran after an offline check")
        rig.world["/Fake/Alpha.app"] = outcome(app("Alpha"), .updateAvailable(offer("2.0")))
        rig.world["/Fake/Bravo.app"] = outcome(app("Bravo"), .upToDate)
        rig.clock.advance(UpdateCheckScheduler.offlineRetryDelay + 60); try rig.timer.fireActive(); await rig.settle()
        try expect(installs(rig) == ["update Alpha quit=false"], "the retry did not run it: \(installs(rig))")
    }

    check("automatic: deferred while an install is running, then run when it is over") {
        let (s, _) = settings()
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: s, gated: true)
        let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
        rig.scheduler.start()
        while rig.checks.count == 0 { await Task.yield() }
        entry.requestUpdateAll()                 // queued behind the check; it starts the moment the check succeeds
        rig.gate?.open(); await rig.settle()
        try expect(installs(rig) == ["update Alpha quit=false"] && rig.controller.updateAllInvocations == 1, "manual run: \(installs(rig))")
        // The automatic run was due while that install ran: it waited, and nothing was recorded.
        try expect(s.lastRunDay == nil, "automatic recorded a run while an install was running: \(String(describing: s.lastRunDay))")
        let retry = rig.timer.active.first { $0.delay == UpdateCheckScheduler.deferDelay }
        try expect(retry != nil, "no retry armed while an install was running")
        retry?.fired = true; retry?.fire(); await rig.settle()
        try expect(s.lastRunDay == "2026-11-11" && rig.controller.updateAllInvocations == 2, "the retry did not run it: \(String(describing: s.lastRunDay))")
    }

    check("automatic: installs only what Update All installs, with no Patched, installer package, hidden, App Store or admin app") {
        let patchedItself = app("Patched", id: NoSourceReason.patchedBundleID)
        let pkg = app("Pkgy"), admin = app("Admin"), store = storeApp("Store")
        let hidden = app("Hidden", id: "com.vendor.hidden"), hiddenCopy = app("HiddenCopy", id: "com.vendor.hidden")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let ignoredOutcome = AppCheckOutcome(app: hidden, teamID: nil, source: nil, lowConfidence: false, installable: false,
                                             result: .noSource, noSourceReason: .ignored)
        let (s, _) = settings()
        let summaries = AutoSummaries()
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))),
                           outcome(patchedItself, .updateAvailable(offer("9.0"))),
                           outcome(pkg, .updateAvailable(offer("2.0", format: .pkg))),
                           storeOutcome(store), outcome(admin, .updateAvailable(offer("2.0"))),
                           ignoredOutcome, outcome(hiddenCopy, .updateAvailable(offer("2.0")))],
                          now: at(11, 2, 0), settings: s, summaries: summaries, installer: installer, packageUpdates: true)
        rig.scheduler.start(); await rig.settle()
        // Admin is only found out when the install is refused; nothing else may be tried.
        try expect(installs(rig) == ["update Admin quit=false", "update Alpha quit=false"], "tried to install: \(installs(rig))")
        try expect(adminEvents(rig.installer).isEmpty, "admin consent reached the installer: \(adminEvents(rig.installer))")
        try expect(rig.opener.nothingOpened, "the App Store (or anything else) was opened: \(rig.opener.urls) \(rig.opener.apps)")
        try expect(summaries.automatic.first?.appStore == 0 && summaries.automatic.first?.updated == 1, "summary: \(summaries.automatic)")
        try expect(rig.controller.rows.first { $0.name == "Pkgy" }?.privilege == .installer, "the installer row was not an installer row")
    }

    check("automatic: an App Store update alone does not open the App Store or install") {
        let (s, _) = settings()
        let summaries = AutoSummaries()
        let rig = autoRig([storeOutcome(storeApp("Store"))], now: at(11, 2, 0), settings: s, summaries: summaries)
        rig.scheduler.start(); await rig.settle()
        try expect(installs(rig).isEmpty && rig.opener.nothingOpened, "App Store: \(installs(rig)) \(rig.opener.urls)")
        try expect(summaries.automatic.isEmpty && summaries.plain.isEmpty, "a summary was posted for nothing")
    }

    check("automatic: open apps are skipped, never quit, listed in the summary and still offered") {
        let (s, _) = settings()
        let summaries = AutoSummaries()
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, quit in
            if outcome.app.name.hasPrefix("Open"), !quit { throw InstallRefusal.appRunning("open") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("Alpha2"), .updateAvailable(offer("2.0"))),
                           outcome(app("Alpha3"), .updateAvailable(offer("2.0"))),
                           outcome(app("OpenOne"), .updateAvailable(offer("2.0"))), outcome(app("OpenTwo"), .updateAvailable(offer("2.0")))],
                          now: at(11, 2, 0), settings: s, summaries: summaries, installer: installer)
        rig.scheduler.start(); await rig.settle()
        try expect(!rig.installer.recorder.events.contains { $0.hasSuffix("quit=true") }, "an app was quit: \(rig.installer.recorder.events)")
        let summary = try summaries.automatic.first.unwrap()
        try expect(summary.updated == 3 && summary.skippedOpen == 2, "summary: \(summary)")
        try expect(summary.text == "Updated 3 apps; 2 skipped because they are open", "text: \(summary.text)")
        try expect(rig.controller.pendingQuit == nil, "a quit prompt was raised")
        let stillOffered = rig.controller.rows.filter { $0.status == .updateAvailable }.map(\.name).sorted()
        try expect(stillOffered == ["OpenOne", "OpenTwo"], "still offered: \(stillOffered)")
        try expect(rig.controller.rows.first { $0.name == "Alpha" }?.result != nil, "an updated row shows no result")
    }

    check("automatic: roll back works on an automatically updated app") {
        let (s, _) = settings()
        let alpha = app("Alpha")
        let rig = autoRig([outcome(alpha, .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: s)
        rig.installer.backups = [try backup(alpha)]
        rig.scheduler.start(); await rig.settle()
        await runCheck(rig.controller)
        try expect(rig.controller.rows.first?.canRollBack == true, "no roll back offered after the run")
        await runOperation(rig.controller) { rig.controller.rollBack(id: alpha.path) }
        try expect(rig.installer.recorder.events.contains { $0.hasPrefix("rollback") }, "roll back did not reach the installer")
    }

    check("automatic summary text") {
        try expect(UpdateAllSummary(updated: 3, failed: 0, skippedOpen: 2, needsAdmin: 0).text == "Updated 3 apps; 2 skipped because they are open", "plural")
        try expect(UpdateAllSummary(updated: 1, failed: 0, skippedOpen: 1, needsAdmin: 0).text == "Updated 1 app; 1 skipped because it is open", "singular")
        try expect(UpdateAllSummary(updated: 2, failed: 1, skippedOpen: 0, needsAdmin: 1).text == "Updated 2 apps; 1 failed; 1 needs admin", "failed and admin")
    }

    check("automatic: time of day is read strictly") {
        for good in ["00:00", "02:00", "09:05", "23:59"] { try expect(TimeOfDay(string: good)?.string == good, "rejected \(good)") }
        for bad in ["", "2:00", "24:00", "02:60", "02:0", "0200", "02-00", " 02:00", "02:00 ", "02:00:00", "ab:cd", "+2:00", "٠٢:٠٠", "02:00\n"] {
            try expect(TimeOfDay(string: bad) == nil, "accepted \(bad.debugDescription)")
        }
    }

    check("automatic: the schedule rule on its own, with a fake clock") {
        let time = TimeOfDay(string: "23:00")!
        func due(_ date: Date, _ last: String? = nil) -> Bool { AutomaticUpdateSchedule.isDue(now: date, time: time, lastRunDay: last, calendar: gmt) }
        try expect(!due(at(11, 22, 59)) && due(at(11, 23, 0)) && due(at(11, 23, 59)), "late-evening window")
        try expect(!due(at(12, 0, 30)), "a window never carries into the next day")
        try expect(!due(at(11, 23, 30), "2026-11-11") && due(at(11, 23, 30), "2026-11-10"), "last-run day")
    }

    check("managed: a forced value locks the setting, wins over the user's choice and cannot be changed in the app") {
        let (s, store) = settings(enabled: false, time: "02:00",
                                  managed: [AutomaticUpdateSettings.enabledKey: true, AutomaticUpdateSettings.timeKey: "03:30"])
        try expect(s.isEnabled && s.enabledLocked && s.timeLocked && s.time.string == "03:30" && !s.managedValueIgnored, "managed values not applied")
        s.setEnabled(false); s.setTime(TimeOfDay(string: "05:00")!)
        try expect(s.isEnabled && s.time.string == "03:30" && !store.enabled && store.time.string == "02:00", "the user changed a managed setting")
        // The managed values drive the scheduler: not at 02:00, yes at 03:30.
        let early = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: s)
        early.scheduler.start(); await early.settle()
        try expect(installs(early).isEmpty, "ran at the user's time instead of the managed time")
        let late = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 3, 30), settings: s)
        late.scheduler.start(); await late.settle()
        try expect(installs(late) == ["update Alpha quit=false"], "did not run at the managed time")
        // A managed 'off' stops a user's 'on'.
        let (off, _) = settings(enabled: true, managed: [AutomaticUpdateSettings.enabledKey: false])
        try expect(!off.isEnabled && off.enabledLocked && !off.timeLocked, "managed off")
        let offRig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: off)
        offRig.scheduler.start(); await offRig.settle()
        try offRig.noInstallerActivity()
    }

    check("managed: one key managed locks only that key; unmanaged keys stay the user's") {
        let (s, store) = settings(enabled: true, time: "04:00", managed: [AutomaticUpdateSettings.timeKey: "01:15"])
        try expect(!s.enabledLocked && s.timeLocked && s.isEnabled && s.time.string == "01:15", "state")
        s.setEnabled(false)
        try expect(!s.isEnabled && !store.enabled, "the user could not change the unmanaged key")
    }

    check("managed: an invalid forced time is ignored; an invalid forced on/off value fails closed (off and locked)") {
        for managed in [[AutomaticUpdateSettings.timeKey: "3:30"], [AutomaticUpdateSettings.timeKey: 330],
                        [AutomaticUpdateSettings.timeKey: "25:00"]] as [[String: Any]] {
            let (s, _) = settings(enabled: true, time: "04:00", managed: managed)
            try expect(s.managedValueIgnored && !s.enabledLocked && !s.timeLocked, "\(managed) was not ignored")
            try expect(s.isEnabled && s.time.string == "04:00", "\(managed) changed the setting")
        }
        for bad in ["false", "no", "yes", 0, 1] as [Any] {
            let (s, store) = settings(enabled: true, time: "04:00", managed: [AutomaticUpdateSettings.enabledKey: bad])
            try expect(!s.isEnabled && s.enabledLocked && s.managedValueIgnored, "forced invalid \(bad) did not fail closed")
            s.setEnabled(true)
            try expect(!s.isEnabled && store.enabled, "the user turned on a setting the organisation forced")
            let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 4, 0), settings: s)
            rig.scheduler.start(); await rig.settle()
            try rig.noInstallerActivity()
        }
        try expect(AutomaticUpdateSettings.invalidNote == "Your organisation set a value Patched could not use. An invalid on or off value keeps automatic updates off. An invalid time is ignored.", "note text")
        try expect(AutomaticUpdateSettings.lockedNote == "Set by your organisation", "locked text")
    }

    check("managed: a value that is not forced is not managed, and the real reader reports nothing under the test tripwire") {
        struct UserOnly: ManagedPreferenceReading {
            func isForced(_ key: String) -> Bool { false }
            func forcedValue(forKey key: String) -> Any? { "03:30" }   // present for the user, not forced
        }
        let s = AutomaticUpdateSettings(store: MemoryAutomaticUpdateStore(), managed: ManagedPreferences(reader: UserOnly()))
        try expect(!s.timeLocked && s.time == .default, "a user value read as managed")
        let real = SystemManagedPreferences()
        try expect(!real.isForced(AutomaticUpdateSettings.enabledKey) && real.forcedValue(forKey: AutomaticUpdateSettings.timeKey) == nil,
                   "the real reader was consulted under the tripwire")
    }

    check("automatic notify: updates the run will not install are still announced; the ones it attempts are not") {
        let (s, _) = settings()
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), storeOutcome(storeApp("Store")),
                           outcome(app("Pkgy"), .updateAvailable(offer("2.0", format: .pkg))),
                           outcome(app("Patched", id: NoSourceReason.patchedBundleID), .updateAvailable(offer("9.0")))],
                          now: at(11, 2, 0), settings: s, installer: installer, packageUpdates: true)
        rig.scheduler.start(); await rig.settle()
        try expect(installs(rig) == ["update Alpha quit=false"], "events: \(installs(rig))")
        let announced = rig.notifier.posted.flatMap { $0 }.map(\.name).sorted()
        try expect(announced == ["Patched", "Pkgy", "Store"], "announced: \(announced)")
    }

    check("automatic notify: an app skipped because it was open is announced at a later check") {
        let (s, _) = settings()
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, quit in
            if outcome.app.name == "OpenOne", !quit { throw InstallRefusal.appRunning("open") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("OpenOne"), .updateAvailable(offer("2.0")))],
                          now: at(11, 2, 0), settings: s, installer: installer)
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.posted.isEmpty, "announced an attempted update before the run: \(rig.notifier.posted)")
        // The next check, later the same day: the run is spent, the skipped app is told to the user as usual.
        rig.clock.advance(UpdateCheckScheduler.interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.flatMap { $0 }.map(\.name) == ["OpenOne"], "later announcement: \(rig.notifier.posted.map { $0.map(\.name) })")
        // The next day it is open again at the chosen time: the run skips it, and it is not announced a second time.
        rig.clock.date = at(12, 2, 0); try rig.timer.fireActive(); await rig.settle()
        rig.clock.advance(UpdateCheckScheduler.interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.flatMap { $0 }.map(\.name) == ["OpenOne"], "announced again after the next day's run: \(rig.notifier.posted.map { $0.map(\.name) })")
        try expect(s.lastRunDay == "2026-11-12", "the second day's run did not happen: \(String(describing: s.lastRunDay))")
    }

    check("automatic: installing blocked defers the run without spending the day; it runs when unblocked, and not after the window") {
        let (s, _) = settings()
        let rig = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: s, keepUpdatesOffered: true)
        rig.installer.unreadable = ["/Fake/journal"]
        rig.scheduler.start(); await rig.settle()
        try expect(installs(rig).isEmpty && s.lastRunDay == nil, "ran or spent the day while blocked: \(installs(rig)) \(String(describing: s.lastRunDay))")
        let retry = rig.timer.active.first { $0.delay == UpdateCheckScheduler.deferDelay }
        try expect(retry != nil, "no retry armed while blocked")
        rig.installer.unreadable = []
        await rig.controller.refreshInstallerState()
        retry?.fired = true; retry?.fire(); await rig.settle()
        try expect(installs(rig) == ["update Alpha quit=false"] && s.lastRunDay == "2026-11-11", "did not run once unblocked: \(installs(rig))")
        // A deferral that outlasts the window means no run that day.
        let (late, _) = settings()
        let blocked = autoRig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: late)
        blocked.installer.unreadable = ["/Fake/journal"]
        blocked.scheduler.start(); await blocked.settle()
        let again = blocked.timer.active.first { $0.delay == UpdateCheckScheduler.deferDelay }
        try expect(again != nil, "no retry armed")
        blocked.installer.unreadable = []
        await blocked.controller.refreshInstallerState()
        blocked.clock.date = at(11, 8, 30)
        again?.fired = true; again?.fire(); await blocked.settle()
        try expect(installs(blocked).isEmpty && late.lastRunDay == nil, "ran after the window: \(installs(blocked))")
        try expect(blocked.timer.active.allSatisfy { $0.delay != UpdateCheckScheduler.deferDelay }, "kept retrying after the window")
    }

    check("automatic: waits while a roll back or a recovery runs, and while a quit question is open") {
        @MainActor func deferred() async throws -> (Rig, AutomaticUpdateSettings, FakeTimerToken) {
            let (s, _) = settings()
            let alpha = app("Alpha")
            let rig = autoRig([outcome(alpha, .updateAvailable(offer("2.0")))], now: at(11, 2, 0), settings: s, gated: true)
            rig.installer.backups = [try backup(alpha)]
            let entry = UpdateAllEntryPoint(controller: rig.controller, summaryNotifier: nil)
            rig.scheduler.start()
            while rig.checks.count == 0 { await Task.yield() }
            entry.requestUpdateAll()
            rig.gate?.open(); await rig.settle()
            guard s.lastRunDay == nil, let retry = rig.timer.active.first(where: { $0.delay == UpdateCheckScheduler.deferDelay }) else {
                throw CheckFailure(description: "the run was not deferred behind the queued Update All")
            }
            return (rig, s, retry)
        }
        // A roll back.
        do {
            let (rig, s, retry) = try await deferred()
            let hold = Gate()
            rig.installer.rollbackHandler = { _, _ in await hold.wait(); return AppUpdateReport(status: "rolled_back", fromVersion: "2.0", toVersion: "1.0", backupFolder: "/b2") }
            rig.controller.rollBack(id: "/Fake/Alpha.app")
            try expect(rig.controller.isWorking, "the roll back did not start")
            retry.fired = true; retry.fire()
            try expect(s.lastRunDay == nil && rig.controller.updateAllInvocations == 1, "ran during a roll back")
            let next = rig.timer.active.first { $0.delay == UpdateCheckScheduler.deferDelay }
            try expect(next != nil, "no new retry during a roll back")
            hold.open(); await rig.settle()
            next?.fired = true; next?.fire(); await rig.settle()
            try expect(s.lastRunDay == "2026-11-11", "did not run after the roll back")
        }
        // A recovery.
        do {
            let (rig, s, retry) = try await deferred()
            let hold = DispatchSemaphore(value: 0)
            rig.installer.unfinished = 1
            rig.installer.recovery = AppRecoveryResult(entries: [.init(targetPath: "/Fake/Alpha.app", result: .success(.reverted))])
            rig.installer.onRecover = { hold.wait() }
            rig.controller.recover()
            try expect(rig.controller.isWorking, "recovery did not start")
            retry.fired = true; retry.fire()
            try expect(s.lastRunDay == nil && rig.controller.updateAllInvocations == 1, "ran during a recovery")
            let next = rig.timer.active.first { $0.delay == UpdateCheckScheduler.deferDelay }
            try expect(next != nil, "no new retry during a recovery")
            hold.signal(); await rig.settle()
            next?.fired = true; next?.fire(); await rig.settle()
            try expect(s.lastRunDay == "2026-11-11", "did not run after the recovery")
        }
    }
}
