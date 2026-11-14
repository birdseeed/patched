import Foundation
import UpdateSources
import UpdateInstaller
import PatchedShell
@_spi(Testing) import PatchedClient

// Scheduled-check behaviour: launch, 3-hour cadence, wake, single flight, deferral, notifications,
// badge and Open at login. Everything is a fake: no real timer, notification centre, login item,
// UserDefaults or network.

@MainActor final class FakeClock { var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) } }

@MainActor final class FakeTimerToken: CancellableToken {
    var cancelled = false, fired = false
    let delay: TimeInterval
    let fire: @MainActor () -> Void
    init(delay: TimeInterval, fire: @escaping @MainActor () -> Void) { self.delay = delay; self.fire = fire }
    func cancel() { cancelled = true }
}
@MainActor final class FakeTimer: CheckTimerScheduling {
    var all: [FakeTimerToken] = []
    var active: [FakeTimerToken] { all.filter { !$0.cancelled && !$0.fired } }
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> any CancellableToken {
        let token = FakeTimerToken(delay: seconds, fire: fire); all.append(token); return token
    }
    /// Fires the one live timer, as the run loop would.
    func fireActive() throws {
        guard active.count == 1, let token = active.first else { throw CheckFailure(description: "expected exactly one live timer, have \(active.count)") }
        token.fired = true; token.fire()
    }
}
@MainActor final class FakeWake: WakeEventSourcing {
    var handler: (@MainActor () -> Void)?
    private final class Token: CancellableToken { var onCancel: () -> Void = {}; func cancel() { onCancel() } }
    func observe(_ handler: @escaping @MainActor () -> Void) -> any CancellableToken {
        self.handler = handler
        let token = Token(); token.onCancel = { [weak self] in self?.handler = nil }; return token
    }
    func wake() { handler?() }
}
@MainActor final class FakeNotifier: UpdateNotifying {
    var posted: [[AvailableUpdate]] = []
    /// Whether the system accepted the notification (false = permission denied or posting failed).
    var delivers = true
    func notify(updates: [AvailableUpdate], completion: @escaping @MainActor (Bool) -> Void) {
        posted.append(updates); completion(delivers)
    }
    /// Patched's own release announcements.
    var postedSelf: [SelfUpdate] = []
    /// macOS announcements and reminders.
    var postedMacOS: [(notice: MacOSUpdateNotice, reminder: Bool)] = []
    func notify(macOSUpdate: MacOSUpdateNotice, reminder: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        postedMacOS.append((macOSUpdate, reminder)); completion(delivers)
    }
    /// When set, self-update completions wait here until the test releases them (a slow permission prompt).
    var holdSelf = false
    var heldSelf: [@MainActor (Bool) -> Void] = []
    func notify(selfUpdate: SelfUpdate, completion: @escaping @MainActor (Bool) -> Void) {
        postedSelf.append(selfUpdate)
        if holdSelf { heldSelf.append(completion) } else { completion(delivers) }
    }
}
@MainActor final class FakeStore: BackgroundCheckStoring {
    var lastCheck: Date?
    var notifiedKeys: Set<String> = []
}
@MainActor final class FakeLoginItem: LoginItemControlling {
    var status: LoginItemStatus = .notRegistered
    var registerResult: LoginItemStatus = .enabled
    var registerError: Error?
    var registers = 0, unregisters = 0, openedSettings = 0
    func register() throws { registers += 1; if let registerError { throw registerError }; status = registerResult }
    func unregister() throws { unregisters += 1; status = .notRegistered }
    func openSystemSettings() { openedSettings += 1 }
}

/// `SMAppService.mainApp` for `SystemLoginItem`: records what was asked of it and never registers anything real.
@MainActor final class FakeMainAppService: MainAppServicing {
    var status: LoginItemStatus = .notRegistered
    var registerResult: LoginItemStatus = .enabled
    var registers = 0, unregisters = 0, openedSettings = 0
    func register() throws { registers += 1; status = registerResult }
    func unregister() throws { unregisters += 1; status = .notRegistered }
    func openSystemSettingsLoginItems() { openedSettings += 1 }
}

/// Holds a fake network call open until the check releases it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); continuation.resume() } else { waiter = continuation; lock.unlock() }
        }
    }
    func open() {
        lock.lock(); opened = true; let w = waiter; waiter = nil; lock.unlock(); w?.resume()
    }
}
final class GateHolder: @unchecked Sendable {
    private let lock = NSLock(); private var _current: Gate?
    var current: Gate? { get { lock.lock(); defer { lock.unlock() }; return _current } set { lock.lock(); _current = newValue; lock.unlock() } }
}
final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0; private var _fail = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var failing: Bool { get { lock.lock(); defer { lock.unlock() }; return _fail } set { lock.lock(); _fail = newValue; lock.unlock() } }
}
struct FakeNetworkDown: Error {}

@MainActor struct Rig {
    let clock = FakeClock(), timer = FakeTimer(), wake = FakeWake(), notifier = FakeNotifier(), store = FakeStore()
    let controller: AppUpdatesController
    let installer: FakeInstaller
    let world: World
    let checks = CheckCounter()
    let holder = GateHolder()
    var gate: Gate? { holder.current }
    let scheduler: UpdateCheckScheduler
    /// Records every URL or app the controller is asked to open; the scheduler must never cause one.
    let opener = RecordingOpener()

    init(_ outcomes: [AppCheckOutcome], gated: Bool = false, installer: FakeInstaller = FakeInstaller(), adminUpdates: Bool = false,
         packageUpdates: Bool = false, automatic: AutomaticUpdateSettings? = nil,
         summaryNotifier: (any UpdateSummaryNotifying)? = nil, macOSReminders: MacOSReminderSettings? = nil,
         calendar: Calendar = .current) {
        let world = World(outcomes), checks = checks, holder = holder
        if gated { holder.current = Gate() }
        installer.world = world
        self.installer = installer; self.world = world
        let paths = outcomes.map(\.app.path)
        controller = AppUpdatesController(
            scan: { paths.compactMap { world[$0] }.map { AppUpdateScannedApp(app: $0.app, icon: nil) } },
            check: { apps in
                checks.bump()
                if let gate = holder.current { await gate.wait() }
                if checks.failing { throw FakeNetworkDown() }
                return apps.compactMap { world[$0.path] }
            },
            recheck: { world[$0] }, installer: installer, adminUpdates: adminUpdates, packageUpdates: packageUpdates)
        controller.urlOpener = opener
        let clock = clock, timer = timer, wake = wake, notifier = notifier, store = store
        scheduler = UpdateCheckScheduler(controller: controller, now: { clock.date }, timer: timer, notifier: notifier, wake: wake, store: store,
                                        automatic: automatic, summaryNotifier: summaryNotifier, macOSReminders: macOSReminders,
                                        calendar: calendar)
    }
    /// Makes every later check wait until the returned gate is opened.
    func hold() -> Gate { let g = Gate(); holder.current = g; return g }
    func settle() async { await controller.waitUntilIdle() }
    func noInstallerActivity() throws {
        let events = installer.recorder.events.filter { $0.hasPrefix("update") || $0.hasPrefix("rollback") || $0.hasPrefix("recover") || $0.hasPrefix("admin") }
        try expect(events.isEmpty, "scheduler path reached the installer: \(events)")
        try expect(controller.updateAllInvocations == 0, "scheduler path called updateAll")
        try expect(opener.nothingOpened, "scheduler path opened a URL or app: \(opener.urls) \(opener.apps)")
    }
}

@MainActor func registerBackgroundCheckChecks() {
    let interval = UpdateCheckScheduler.interval

    check("schedule: opening the app checks once, records the time and arms a 3-hour timer") {
        let rig = Rig([outcome(app("Alpha"), .upToDate)])
        rig.scheduler.start(); await rig.settle()
        try expect(rig.checks.count == 1, "launch checks: \(rig.checks.count)")
        try expect(rig.store.lastCheck == rig.clock.date, "last check not recorded")
        try expect(rig.timer.active.count == 1 && rig.timer.active[0].delay == interval, "timer: \(rig.timer.active.map(\.delay))")
        rig.scheduler.start(); await rig.settle()
        try expect(rig.checks.count == 1, "second start() must not check again")
        try rig.noInstallerActivity()
    }

    check("schedule: launch check is skipped within 10 minutes of a previous check, runs after") {
        let recent = Rig([outcome(app("Alpha"), .upToDate)])
        recent.store.lastCheck = recent.clock.date.addingTimeInterval(-9 * 60)
        recent.scheduler.start(); await recent.settle()
        try expect(recent.checks.count == 0, "checked despite a check 9 minutes ago")
        try expect(recent.timer.active.count == 1 && recent.timer.active[0].delay == interval - 9 * 60,
                   "next check should be due 3h after the last: \(recent.timer.active.map(\.delay))")
        let older = Rig([outcome(app("Alpha"), .upToDate)])
        older.store.lastCheck = older.clock.date.addingTimeInterval(-11 * 60)
        older.scheduler.start(); await older.settle()
        try expect(older.checks.count == 1, "no launch check 11 minutes after the last")
    }

    check("schedule: a copy reopened by its own self-update checks at once, even minutes after the last check") {
        let rig = Rig([outcome(app("Alpha"), .upToDate)])
        rig.store.lastCheck = rig.clock.date.addingTimeInterval(-2 * 60)
        rig.scheduler.start(afterSelfUpdate: true); await rig.settle()
        try expect(rig.checks.count == 1, "no check after a self-update relaunch")
        try expect(rig.store.lastCheck == rig.clock.date, "last check not recorded")
        try expect(rig.timer.active.count == 1 && rig.timer.active[0].delay == interval, "timer: \(rig.timer.active.map(\.delay))")
        // After the forced check the normal 3-hour cadence applies.
        rig.clock.advance(60)
        try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == 1, "timer fired early or checked twice: \(rig.checks.count)")
        try rig.noInstallerActivity()
    }

    check("schedule: 3-hour cadence follows the wall clock") {
        let rig = Rig([outcome(app("Alpha"), .upToDate)])
        rig.scheduler.start(); await rig.settle()
        rig.clock.advance(interval - 1)
        try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == 1, "checked 1s early")
        try expect(rig.timer.active.count == 1 && rig.timer.active[0].delay == 1, "should re-arm for the remaining second: \(rig.timer.active.map(\.delay))")
        rig.clock.advance(1)
        try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == 2, "no check at exactly 3h: \(rig.checks.count)")
        try expect(rig.timer.active.count == 1 && rig.timer.active[0].delay == interval, "not re-armed for another 3h")
        try rig.noInstallerActivity()
    }

    check("schedule: waking after 5 hours checks soon; waking after 1 hour does not") {
        let long = Rig([outcome(app("Alpha"), .upToDate)])
        long.scheduler.start(); await long.settle()
        long.clock.advance(5 * 3600)
        long.wake.wake()
        try expect(long.checks.count == 1, "checked synchronously on wake instead of after the network delay")
        try expect(long.timer.active.count == 1 && long.timer.active[0].delay == UpdateCheckScheduler.wakeDelay, "wake delay: \(long.timer.active.map(\.delay))")
        try long.timer.fireActive(); await long.settle()
        try expect(long.checks.count == 2, "no check after a 5 hour sleep")
        let short = Rig([outcome(app("Alpha"), .upToDate)])
        short.scheduler.start(); await short.settle()
        short.clock.advance(3600)
        short.wake.wake()
        try short.timer.fireActive(); await short.settle()
        try expect(short.checks.count == 1, "checked after only 1 hour")
        try expect(short.timer.active.count == 1 && short.timer.active[0].delay == interval - 3600, "should keep the original due time: \(short.timer.active.map(\.delay))")
    }

    check("schedule: checks never overlap, including the user's own check") {
        let rig = Rig([outcome(app("Alpha"), .upToDate)], gated: true)
        rig.scheduler.start()
        while rig.checks.count == 0 { await Task.yield() }
        try expect(rig.controller.phase == .checking, "launch check not in flight")
        let startedAt = rig.store.lastCheck
        rig.clock.advance(interval * 2)
        rig.wake.wake()
        try rig.timer.fireActive()
        try expect(rig.checks.count == 1, "a second check started while one was running")
        try expect(rig.store.lastCheck == startedAt, "an overlapping attempt was recorded as a check")
        rig.gate?.open(); await rig.settle()
        try expect(rig.checks.count == 1 && rig.timer.active.count == 1, "after finishing: checks \(rig.checks.count), timers \(rig.timer.active.count)")
        // The user's own check in flight blocks the scheduler too, and counts as the latest check.
        let manual = Rig([outcome(app("Alpha"), .upToDate)], gated: true)
        manual.store.lastCheck = manual.clock.date.addingTimeInterval(-interval)
        manual.controller.check()
        while manual.checks.count == 0 { await Task.yield() }
        manual.scheduler.start()
        try expect(manual.checks.count == 1 && manual.controller.phase == .checking, "scheduler started a check over the user's")
        manual.gate?.open(); await manual.settle()
        try expect(manual.checks.count == 1, "scheduler checked again after the user's check")
        try expect(manual.store.lastCheck == manual.clock.date, "the user's check was not recorded as the latest")
        try expect(manual.timer.active.count == 1 && manual.timer.active[0].delay == interval, "timer not armed after the user's check")
    }

    check("schedule: a check is deferred while an install is in progress, then runs") {
        let installer = FakeInstaller()
        let hold = Gate()
        installer.updateHandler = { _, _ in
            await hold.wait()
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], installer: installer)
        await runCheck(rig.controller)
        let before = rig.checks.count
        rig.controller.update(id: "/Fake/Alpha.app")
        while !installer.recorder.events.contains(where: { $0.hasPrefix("update") }) { await Task.yield() }
        try expect(rig.controller.isWorking, "install not in progress")
        rig.scheduler.start()
        try expect(rig.checks.count == before, "checked during an install")
        try expect(rig.timer.active.count == 1 && rig.timer.active[0].delay == UpdateCheckScheduler.deferDelay, "deferral timer: \(rig.timer.active.map(\.delay))")
        try rig.timer.fireActive()
        try expect(rig.checks.count == before, "checked during an install on the retry")
        hold.open(); await rig.settle()
        try expect(rig.controller.isWorking == false, "install did not finish")
        try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == before + 1, "deferred check did not run once the install ended: \(rig.checks.count)")
        let updates = installer.recorder.events.filter { $0.hasPrefix("update") }
        try expect(updates.count == 1, "the scheduler started an install: \(updates)")
    }

    check("notify: only when the set of available updates changes") {
        let alpha = app("Alpha"), bravo = app("Bravo")
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0"))), outcome(bravo, .upToDate)])
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.posted.count == 1 && rig.notifier.posted[0].map(\.name) == ["Alpha"], "first: \(rig.notifier.posted)")
        // Same set at the next interval: silence.
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == 2 && rig.notifier.posted.count == 1, "repeat notification for an unchanged set")
        // A second app gains an update: notify with both.
        rig.world[bravo.path] = outcome(bravo, .updateAvailable(offer("5.0")))
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 2 && rig.notifier.posted[1].map(\.name) == ["Alpha", "Bravo"], "second: \(rig.notifier.posted)")
        // A newer version of an app already notified about is a change.
        rig.world[alpha.path] = outcome(alpha, .updateAvailable(offer("2.1")))
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 3 && rig.notifier.posted[2].first?.version == "2.1", "third: \(rig.notifier.posted)")
        // Updates disappear (installed elsewhere): nothing to say.
        rig.world[alpha.path] = outcome(alpha, .upToDate); rig.world[bravo.path] = outcome(bravo, .upToDate)
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 3, "notified about an empty set")
        try rig.noInstallerActivity()
    }

    check("notify: none for an empty first check or a check with no updates") {
        let rig = Rig([outcome(app("Alpha"), .upToDate), outcome(app("Bravo"), .noSource, noSource: true),
                       outcome(app("Charlie"), .updateAvailable(offer("3.0", source: .homebrewCask(token: "c"))), source: .homebrewCask(token: "c"), low: true),
                       outcome(app("Delta"), .updateAvailable(offer("4.0", format: .pkg)))])
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.posted.isEmpty, "notified for apps Patched cannot install: \(rig.notifier.posted)")
        try expect(rig.controller.availableUpdateCount == 0, "badge counts non-installable updates")
    }

    check("notify: a failed check, or an app that could not be checked, never notifies or repeats") {
        let alpha = app("Alpha")
        let failing = Rig([outcome(alpha, .updateAvailable(offer("2.0")))])
        failing.checks.failing = true
        failing.scheduler.start(); await failing.settle()
        try expect(failing.notifier.posted.isEmpty, "notified after a failed check")
        try expect(failing.timer.active.count == 1 && failing.timer.active[0].delay == interval, "failed check should retry at the next interval")
        // Per-app network failure after a successful notification: silent, and no repeat when it recovers.
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0")))])
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "first notification missing")
        rig.world[alpha.path] = outcome(alpha, .refused(.network("offline")))
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "notified for a network failure")
        rig.world[alpha.path] = outcome(alpha, .updateAvailable(offer("2.0")))
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "re-notified after a transient network failure")
    }

    check("offline: one offline check keeps the known updates and statuses, with a note, and does not notify again") {
        let alpha = app("Alpha"), bravo = app("Bravo"), charlie = app("Charlie")
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0"))), outcome(bravo, .upToDate), outcome(charlie, .noSource, noSource: true)])
        rig.scheduler.start(); await rig.settle()
        try expect(rig.controller.availableUpdateCount == 1 && rig.notifier.posted.count == 1, "setup")
        for a in [alpha, bravo] { rig.world[a.path] = outcome(a, .refused(.offline("offline"))) }
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        let rows = rig.controller.rows
        try expect(rows.first { $0.name == "Alpha" }?.status == .updateAvailable, "update erased: \(rows.map(\.status))")
        try expect(rows.first { $0.name == "Bravo" }?.status == .upToDate, "up to date erased")
        try expect(rows.first { $0.name == "Alpha" }?.recheckNote == AppUpdateRow.offlineRecheckNote, "no note on a kept row")
        try expect(rows.first { $0.name == "Charlie" }?.recheckNote == nil, "note on a row that never needed the network")
        try expect(rig.controller.availableUpdateCount == 1 && rig.controller.canUpdate(rows.first { $0.name == "Alpha" }!), "badge or Update lost")
        let menu = rig.controller.menuUpdates()
        try expect(menu.rows.map(\.name) == ["Alpha"] && menu.header == "1 update available" && menu.note == "Couldn't re-check 2 apps (offline)",
                   "menu: \(menu.header) / \(menu.note ?? "-") / \(menu.rows.map(\.name))")
        try expect(rig.notifier.posted.count == 1, "re-notified for a kept status")
        // Back online with the same offer: still silent. A changed install on disk is not kept: it is refused.
        rig.world[alpha.path] = outcome(alpha, .updateAvailable(offer("2.0"))); rig.world[bravo.path] = outcome(bravo, .upToDate)
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 1 && rig.controller.rows.allSatisfy { $0.recheckNote == nil }, "note stuck after recovery")
        let changed = app("Alpha", version: "1.5")
        rig.world[alpha.path] = outcome(changed, .refused(.offline("offline")))
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        if case .refused = rig.controller.rows.first(where: { $0.name == "Alpha" })?.status {} else {
            throw CheckFailure(description: "a row for a different installed version was kept")
        }
    }

    check("offline: a check that is mostly offline retries in 10 minutes; a half-answered one waits the full interval") {
        let retry = UpdateCheckScheduler.offlineRetryDelay
        try expect(retry >= 10 * 60 && retry <= 15 * 60, "retry delay \(retry)")
        let alpha = app("Alpha"), bravo = app("Bravo")
        let rig = Rig([outcome(alpha, .refused(.offline("offline"))), outcome(bravo, .refused(.offline("offline")))])
        rig.scheduler.start(); await rig.settle()
        try expect(rig.timer.active.count == 1 && rig.timer.active[0].delay == retry, "offline retry: \(rig.timer.active.map(\.delay))")
        rig.clock.advance(retry); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == 2, "the short retry did not check: \(rig.checks.count)")
        // Back online: the next check is a full interval away.
        rig.world[alpha.path] = outcome(alpha, .upToDate); rig.world[bravo.path] = outcome(bravo, .upToDate)
        rig.clock.advance(retry); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == 3 && rig.timer.active.count == 1 && rig.timer.active[0].delay == interval,
                   "after recovery: \(rig.checks.count) checks, \(rig.timer.active.map(\.delay))")
        // One failure in three is not "offline".
        let charlie = app("Charlie")
        let mixed = Rig([outcome(alpha, .refused(.network("x"))), outcome(bravo, .upToDate), outcome(charlie, .upToDate)])
        mixed.scheduler.start(); await mixed.settle()
        try expect(mixed.timer.active.count == 1 && mixed.timer.active[0].delay == interval, "mixed: \(mixed.timer.active.map(\.delay))")
        // An HTTP error (a moved or broken feed) is not "offline": it is shown as refused and never speeds up the schedule.
        let broken = Rig([outcome(alpha, .upToDate)])
        broken.scheduler.start(); await broken.settle()
        broken.world[alpha.path] = outcome(alpha, .refused(.network("HTTP 404")))
        broken.clock.advance(interval); try broken.timer.fireActive(); await broken.settle()
        let row = broken.controller.rows.first { $0.name == "Alpha" }
        if case .refused? = row?.status {} else { throw CheckFailure(description: "a 404 kept the old status: \(String(describing: row?.status))") }
        try expect(row?.recheckNote == nil, "a 404 was labelled offline")
        try expect(broken.timer.active.count == 1 && broken.timer.active[0].delay == interval, "a 404 sped up the schedule: \(broken.timer.active.map(\.delay))")
    }

    check("notify: the badge matches, and a user-run check seen on screen does not notify") {
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("Bravo"), .updateAvailable(offer("3.0"))),
                       outcome(app("Charlie"), .upToDate)], gated: true)
        rig.gate?.open()
        rig.scheduler.start(); await rig.settle()
        try expect(rig.controller.availableUpdateCount == 2 && rig.notifier.posted.first?.count == 2,
                   "badge \(rig.controller.availableUpdateCount) vs notification \(rig.notifier.posted.map(\.count))")
        // The user checks again: no notification, and the next scheduled check stays quiet too.
        await runCheck(rig.controller)
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "user-run or unchanged check notified")
        // A user-run check that discovers a new update shows it on screen; it does not also notify.
        rig.world[app("Charlie").path] = outcome(app("Charlie"), .updateAvailable(offer("9.0")))
        await runCheck(rig.controller)
        try expect(rig.controller.availableUpdateCount == 3 && rig.notifier.posted.count == 1, "user-run check notified: \(rig.notifier.posted.count)")
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "the update the user already saw was notified afterwards")
        // Installing one app lowers the badge.
        rig.world.install("/Fake/Alpha.app", version: "2.0")
        rig.controller.update(id: "/Fake/Alpha.app")
        await rig.settle()
        try expect(rig.controller.availableUpdateCount == 2, "badge after install: \(rig.controller.availableUpdateCount)")
    }

    check("notify: the badge keeps its count while a check is running") {
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("Bravo"), .upToDate)])
        await runCheck(rig.controller)
        try expect(rig.controller.availableUpdateCount == 1 && rig.checks.count == 1, "no badge after the first check")
        let release = rig.hold()
        rig.controller.check()
        while rig.checks.count < 2 { await Task.yield() }
        try expect(rig.controller.phase == .checking, "second check not running")
        try expect(rig.controller.rows.allSatisfy { $0.status == .pending }, "rows are not pending, so this proves nothing")
        try expect(rig.controller.availableUpdateCount == 1, "badge dropped while checking: \(rig.controller.availableUpdateCount)")
        release.open(); await rig.settle()
        try expect(rig.controller.availableUpdateCount == 1, "badge wrong after the check")
    }

    check("notify: a denied or failed notification is not marked as announced, and is retried once allowed") {
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))])
        rig.notifier.delivers = false
        rig.scheduler.start(); await rig.settle()
        try expect(rig.notifier.posted.count == 1 && rig.store.notifiedKeys.isEmpty, "denied notification was recorded as announced")
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 2, "denied notification was not retried")
        rig.notifier.delivers = true
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 3 && rig.store.notifiedKeys.count == 1, "granted permission did not deliver and record")
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 3, "delivered update notified again")
    }

    check("notify: a newer build of the same display version is a change") {
        let alpha = app("Alpha")
        let rig = Rig([outcome(alpha, .updateAvailable(offer("2.0", build: "100")))])
        rig.scheduler.start(); await rig.settle()
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 1, "same build repeated")
        rig.world[alpha.path] = outcome(alpha, .updateAvailable(offer("2.0", build: "101")))
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.notifier.posted.count == 2 && rig.notifier.posted[1].first?.build == "101", "new build not notified: \(rig.notifier.posted)")
    }

    check("schedule: stopping during a check, then restarting, still checks at the next deadline") {
        let rig = Rig([outcome(app("Alpha"), .upToDate)], gated: true)
        rig.scheduler.start()
        while rig.checks.count == 0 { await Task.yield() }
        rig.scheduler.stop()
        rig.gate?.open(); await rig.settle()
        try expect(rig.timer.active.isEmpty, "stopped scheduler left a timer")
        rig.scheduler.start()
        try expect(rig.timer.active.count == 1, "restart did not arm a timer")
        rig.clock.advance(interval); try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == 2, "restarted scheduler stalled: \(rig.checks.count) checks")
    }

    check("notification click: an open request before the handler or window exists is kept, then delivered once") {
        let notifier = SystemUpdateNotifier()
        notifier.openRequested()
        var opened = 0
        notifier.onOpenUpdates = { opened += 1 }
        try expect(opened == 1, "queued click not delivered when the handler arrived: \(opened)")
        notifier.onOpenUpdates = { opened += 1 }
        try expect(opened == 1, "click delivered twice")
        notifier.openRequested()
        try expect(opened == 2, "later click not delivered")
        let coordinator = NativeClientReopenCoordinator()
        var windows = 0
        coordinator.open()
        coordinator.register(opener: { windows += 1 })
        try expect(windows == 1, "window request before the opener existed was lost: \(windows)")
        coordinator.register(opener: { windows += 1 })
        try expect(windows == 1, "queued window request replayed")
        coordinator.open()
        try expect(windows == 2, "open with an opener did nothing")
    }

    check("login item: toggling registers and unregisters, and approval is surfaced") {
        let item = FakeLoginItem()
        let controller = OpenAtLoginController(item: item)
        try expect(!controller.isOn && item.registers == 0, "starts on or registered")
        controller.setEnabled(true)
        try expect(item.registers == 1 && controller.isOn && controller.status == .enabled, "register: \(item.registers) \(controller.status)")
        controller.setEnabled(false)
        try expect(item.unregisters == 1 && !controller.isOn, "unregister: \(item.unregisters)")
        item.registerResult = .requiresApproval
        controller.setEnabled(true)
        try expect(controller.needsApproval && controller.isOn, "requiresApproval not surfaced")
        try expect(controller.statusText.contains("System Settings > General > Login Items"), "approval text: \(controller.statusText)")
        controller.openSystemSettings()
        try expect(item.openedSettings == 1, "settings not opened")
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let failing = FakeLoginItem(); failing.registerError = Boom()
        let broken = OpenAtLoginController(item: failing)
        broken.setEnabled(true)
        try expect(!broken.isOn && broken.statusText.contains("boom"), "register failure hidden: \(broken.statusText)")
        let missing = FakeLoginItem(); missing.status = .notFound
        try expect(!OpenAtLoginController(item: missing).isAvailable, "notFound offered as available")
    }

    check("login item: an ad-hoc signed Patched shows Open at login greyed out with why, and never touches SMAppService") {
        let service = FakeMainAppService()
        let item = SystemLoginItem(inAppBundle: { true }, teamID: { nil }, service: service)
        let controller = OpenAtLoginController(item: item)
        try expect(controller.status == .needsDeveloperID && !controller.isAvailable && !controller.isOn && !controller.needsApproval,
                   "ad-hoc: \(controller.status)")
        try expect(controller.statusText.contains("signed with a Developer ID") && controller.statusText.contains("ad-hoc signed"),
                   "ad-hoc text: \(controller.statusText)")
        controller.setEnabled(true); controller.refresh()
        try item.register()
        try expect(service.registers == 0, "ad-hoc build registered: \(service.registers)")
        // An empty Team ID is no Team ID.
        let blank = OpenAtLoginController(item: SystemLoginItem(inAppBundle: { true }, teamID: { "" }, service: service))
        try expect(blank.status == .needsDeveloperID, "empty Team ID: \(blank.status)")
        // Outside an app bundle the bundle message wins and the signature is not even read.
        var signatureReads = 0
        let loose = OpenAtLoginController(item: SystemLoginItem(inAppBundle: { false }, teamID: { signatureReads += 1; return nil }, service: service))
        try expect(loose.status == .notFound && !loose.isAvailable && signatureReads == 0, "outside a bundle: \(loose.status), reads \(signatureReads)")
    }

    check("login item: an ad-hoc Patched that is already a login item shows it and can turn it off, but not back on") {
        for already in [LoginItemStatus.enabled, .requiresApproval] {
            let service = FakeMainAppService()
            service.status = already
            let controller = OpenAtLoginController(item: SystemLoginItem(inAppBundle: { true }, teamID: { nil }, service: service))
            try expect(controller.status == already && controller.isOn && controller.isAvailable, "\(already): \(controller.status)")
            controller.setEnabled(false)
            try expect(service.unregisters == 1 && !controller.isOn, "\(already): could not turn it off: \(service.unregisters)")
            try expect(controller.status == .needsDeveloperID && !controller.isAvailable, "\(already): after turning off: \(controller.status)")
            controller.setEnabled(true)
            try expect(service.registers == 0 && !controller.isOn, "\(already): ad-hoc build registered again")
        }
        // The check runner itself is ad-hoc (linker) signed, so its own dynamic code has no Team ID.
        try expect(RunningCodeSignature.teamID() == nil, "the check runner reports a Team ID: \(RunningCodeSignature.teamID() ?? "")")
    }

    check("login item: a Developer ID signed Patched registers and unregisters through SMAppService") {
        let service = FakeMainAppService()
        var signatureReads = 0
        let item = SystemLoginItem(inAppBundle: { true }, teamID: { signatureReads += 1; return "ABCDE12345" }, service: service)
        let controller = OpenAtLoginController(item: item)
        try expect(controller.isAvailable && !controller.isOn && controller.status == .notRegistered, "signed: \(controller.status)")
        controller.setEnabled(true)
        try expect(service.registers == 1 && controller.isOn && controller.status == .enabled, "register: \(service.registers) \(controller.status)")
        try expect(controller.statusText == "Patched opens when you log in.", "enabled text: \(controller.statusText)")
        controller.setEnabled(false)
        try expect(service.unregisters == 1 && !controller.isOn && controller.status == .notRegistered, "unregister: \(service.unregisters)")
        try expect(signatureReads == 1, "the signature was read \(signatureReads) times")
    }

    check("login item: a registration waiting for approval says where to allow it and offers the Login Items button") {
        let service = FakeMainAppService()
        service.registerResult = .requiresApproval
        let controller = OpenAtLoginController(item: SystemLoginItem(inAppBundle: { true }, teamID: { "ABCDE12345" }, service: service))
        controller.setEnabled(true)
        try expect(controller.needsApproval && controller.isOn && controller.isAvailable, "approval: \(controller.status)")
        try expect(controller.statusText.contains("System Settings > General > Login Items"), "approval text: \(controller.statusText)")
        controller.openSystemSettings()
        try expect(service.openedSettings == 1, "Login Items settings not opened")
        let view = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/PatchedAppUpdatesChecks/BackgroundCheckChecks.swift",
                                                                              with: "Sources/PatchedClient/OpenAtLoginView.swift"), encoding: .utf8)
        try expect(view.contains("if controller.needsApproval") && view.contains("controller.openSystemSettings()")
                   && view.contains(".disabled(!controller.isAvailable)"), "the view lost the approval button or the greyed-out state")
    }

    check("session: the testing session has no schedule and the production seams stay inert until started") {
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates))
        session.startBackgroundChecks(showMainWindow: {})
        try expect(!session.backgroundChecksRunning, "fixture session started a schedule")
        try expect(!session.openAtLogin.isAvailable && !session.openAtLogin.isOn, "fixture session exposes a real login item")
    }
}
