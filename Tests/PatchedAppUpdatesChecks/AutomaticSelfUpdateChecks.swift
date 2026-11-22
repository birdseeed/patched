import Foundation
import Darwin
import UpdateSources
import UpdateInstaller
import PatchedShell
@_spi(Testing) import PatchedClient

// "Also update Patched itself": the second opt-in under automatic updates. The setting and its managed override,
// the 24-hour local soak, when the scheduled run may install Patched (after its app updates, only when idle, never
// from Update All), what a failure leaves behind, the history line, and the one-time offer after a confirmed
// self-update. Everything is a fake: no clock, timer, preferences, network, GitHub or real Patched.app.

private let gmtSelf: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "GMT")!
    return calendar
}()
/// 2026-11-<day> at hour:minute GMT.
private func on(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    gmtSelf.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}
private let hour: TimeInterval = 60 * 60

private struct SelfManaged: ManagedPreferenceReading {
    var forced: [String: Any] = [:]
    func isForced(_ key: String) -> Bool { forced[key] != nil }
    func forcedValue(forKey key: String) -> Any? { forced[key] }
}

@MainActor private func selfSettings(enabled: Bool = true, selfUpdates: Bool = true, managed: [String: Any] = [:],
                                     store: MemoryAutomaticUpdateStore = MemoryAutomaticUpdateStore())
    -> (AutomaticUpdateSettings, MemoryAutomaticUpdateStore) {
    store.enabled = enabled; store.selfUpdatesEnabled = selfUpdates
    return (AutomaticUpdateSettings(store: store, managed: ManagedPreferences(reader: SelfManaged(forced: managed))), store)
}

/// The content fingerprint a test release carries; `upload` stands for a file replaced under the same name.
private func fp(_ version: String, upload: Int = 1) -> String { "zip=\(upload)0\(version);sig=\(upload)1\(version)" }

private func signedRelease(_ version: String, upload: Int = 1, fingerprint: String?? = .none) -> PatchedReleaseResult {
    let zip = "https://github.com/birdseeed/patched/releases/download/v\(version)/Patched-\(version).zip"
    let mark: String? = fingerprint ?? fp(version, upload: upload)
    return .newer(PatchedRelease(version: version, pageURL: URL(string: "https://github.com/birdseeed/patched/releases/tag/v\(version)")!,
                                 assets: PatchedReleaseAssets(zipURL: URL(string: zip)!, signatureURL: URL(string: zip + ".sig")!,
                                                              fingerprint: mark)))
}

/// A lookup whose answer can change and which can be held open.
private final class SelfLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: PatchedReleaseResult
    private var _gate: Gate?
    init(_ result: PatchedReleaseResult) { _result = result }
    var result: PatchedReleaseResult { get { lock.withLock { _result } } set { lock.withLock { _result = newValue } } }
    var gate: Gate? { get { lock.withLock { _gate } } set { lock.withLock { _gate = newValue } } }
    var check: SelfUpdateCheck {
        { [self] in
            if let gate { await gate.wait() }
            return result
        }
    }
}

/// Stands in for `SelfUpdater`. Notes each install in the app installer's recorder, so the order against app
/// updates can be read back, and never touches a file.
private final class AutoSelfInstaller: SelfInstalling, @unchecked Sendable {
    let recorder: Recorder
    private let lock = NSLock()
    private var _relaunches = 0
    var failure: InstallRefusal?
    /// Installs, then cannot start the new copy.
    var relaunchFails = false
    /// Runs on the main actor at relaunch time, before Patched would quit.
    var onRelaunch: (@MainActor () -> Void)?
    init(recorder: Recorder) { self.recorder = recorder }
    var relaunches: Int { lock.withLock { _relaunches } }
    private var _fingerprints: [String?] = []
    /// The content fingerprint of each release handed to `install`, in order.
    var fingerprints: [String?] { lock.withLock { _fingerprints } }
    func install(_ release: PatchedRelease, progress: @escaping @Sendable (SelfUpdateStep) -> Void) async throws -> SelfUpdateReport {
        recorder.note("self-install \(release.version)")
        lock.withLock { _fingerprints.append(release.assets?.fingerprint) }
        if let failure { throw failure }
        return SelfUpdateReport(appPath: "/Applications/Patched.app", fromVersion: "0.1.0", toVersion: release.version, backupPath: nil, note: nil)
    }
    func relaunch(_ report: SelfUpdateReport) throws {
        lock.withLock { _relaunches += 1 }
        let hook = onRelaunch
        MainActor.assumeIsolated { hook?() }
        if relaunchFails { throw InstallRefusal.io("could not start the new copy") }
    }
}
@MainActor private final class Quits { var count = 0 }

/// A scheduler rig with Patched's own release, a fake self installer, a history and the given settings.
@MainActor private struct SelfRig {
    let rig: Rig
    let lookup: SelfLookup
    let selfInstaller: AutoSelfInstaller
    let history = MemoryHistoryStore()
    let quits = Quits()
    var controller: AppUpdatesController { rig.controller }
    init(_ outcomes: [AppCheckOutcome] = [outcome(app("Alpha"), .updateAvailable(offer("2.0")))], now: Date,
         settings: AutomaticUpdateSettings, release: PatchedReleaseResult = signedRelease("0.2.0")) {
        rig = Rig(outcomes, automatic: settings, calendar: gmtSelf)
        rig.clock.date = now
        lookup = SelfLookup(release)
        selfInstaller = AutoSelfInstaller(recorder: rig.installer.recorder)
        rig.controller.selfUpdateCheck = lookup.check
        rig.controller.selfInstaller = selfInstaller
        rig.controller.selfRunningVersion = "0.1.0"
        rig.controller.history = history
        let quits = quits
        rig.controller.selfTerminate = { quits.count += 1 }
    }
    var selfInstalls: [String] { rig.installer.recorder.events.filter { $0.hasPrefix("self-install") } }
    /// App updates and self-installs, in the order they happened.
    var installOrder: [String] { rig.installer.recorder.events.filter { $0.hasPrefix("update ") || $0.hasPrefix("self-install") } }
    func settle() async { await rig.settle(); await rig.settle() }
}

@MainActor func registerAutomaticSelfUpdateChecks() {
    // MARK: Setting

    check("self automatic: off by default, and only in effect while automatic updates are on") {
        let fresh = AutomaticUpdateSettings(store: MemoryAutomaticUpdateStore(), managed: ManagedPreferences(reader: SelfManaged()))
        try expect(!fresh.selfUpdatesChoice && !fresh.selfUpdatesEnabled && !fresh.selfUpdatesLocked, "on by default")
        try expect(!fresh.canChangeSelfUpdates, "the box can be ticked while automatic updates are off")
        fresh.setSelfUpdatesEnabled(true)
        try expect(!fresh.selfUpdatesChoice, "turned on while automatic updates were off")
        fresh.setEnabled(true)
        try expect(fresh.canChangeSelfUpdates && !fresh.selfUpdatesEnabled, "automatic on did not enable the box, or ticked it")
        fresh.setSelfUpdatesEnabled(true)
        try expect(fresh.selfUpdatesEnabled, "the box did not turn on")
        fresh.setEnabled(false)
        try expect(!fresh.selfUpdatesEnabled && fresh.selfUpdatesChoice, "automatic off left Patched's own updates in effect")
        // Stored choice on, automatic updates off: not in effect.
        let (stale, _) = selfSettings(enabled: false, selfUpdates: true)
        try expect(!stale.selfUpdatesEnabled, "a stored choice works without automatic updates")
    }

    check("self automatic: managed true, false and invalid lock the box; a managed off for automatic updates keeps it off") {
        let (forcedOn, storeOn) = selfSettings(selfUpdates: false, managed: [AutomaticUpdateSettings.selfUpdatesKey: true])
        try expect(forcedOn.selfUpdatesEnabled && forcedOn.selfUpdatesLocked && !forcedOn.canChangeSelfUpdates, "managed true")
        forcedOn.setSelfUpdatesEnabled(false)
        try expect(forcedOn.selfUpdatesEnabled && !storeOn.selfUpdatesEnabled, "a locked box changed")
        let (forcedOff, _) = selfSettings(selfUpdates: true, managed: [AutomaticUpdateSettings.selfUpdatesKey: false])
        try expect(!forcedOff.selfUpdatesEnabled && forcedOff.selfUpdatesLocked, "managed false")
        forcedOff.setSelfUpdatesEnabled(true)
        try expect(!forcedOff.selfUpdatesEnabled, "managed false overridden")
        for bad in ["true", "yes", 1, 0] as [Any] {
            let (invalid, _) = selfSettings(selfUpdates: true, managed: [AutomaticUpdateSettings.selfUpdatesKey: bad])
            try expect(!invalid.selfUpdatesEnabled && invalid.selfUpdatesLocked && invalid.managedValueIgnored, "invalid \(bad) did not fail closed")
        }
        // Automatic updates managed off (or invalid) keep it off, even with the box itself forced on.
        for automaticValue in [false, "nope"] as [Any] {
            let (off, _) = selfSettings(selfUpdates: true, managed: [AutomaticUpdateSettings.enabledKey: automaticValue,
                                                                    AutomaticUpdateSettings.selfUpdatesKey: true])
            try expect(!off.selfUpdatesEnabled && !off.canChangeSelfUpdates, "automatic managed \(automaticValue) left it on")
        }
    }

    // MARK: Soak

    check("self automatic: the soak needs 24 hours on this Mac for that exact version, and a future sighting never counts") {
        let t = on(11, 2)
        let first = SelfUpdateSoak.observe("0.2.0", fingerprint: fp("0.2.0"), now: t, record: nil)
        try expect(first == SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: t), "first sighting: \(first)")
        let again = SelfUpdateSoak.observe("0.2.0", fingerprint: fp("0.2.0"), now: t + 5 * hour, record: first)
        try expect(again == first, "a second sighting moved the clock: \(again)")
        try expect(!SelfUpdateSoak.isSoaked("0.2.0", fingerprint: fp("0.2.0"), now: t + 23 * hour + 59 * 60, record: first), "installs before 24 hours")
        try expect(SelfUpdateSoak.isSoaked("0.2.0", fingerprint: fp("0.2.0"), now: t + 24 * hour, record: first), "not soaked at 24 hours")
        try expect(!SelfUpdateSoak.isSoaked("0.3.0", fingerprint: fp("0.3.0"), now: t + 48 * hour, record: first), "another version counted as soaked")
        let newer = SelfUpdateSoak.observe("0.3.0", fingerprint: fp("0.3.0"), now: t + 30 * hour, record: first)
        try expect(newer == SelfReleaseSighting(version: "0.3.0", fingerprint: fp("0.3.0"), firstSeen: t + 30 * hour), "a newer version did not reset: \(newer)")
        let future = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: t + 100 * hour)
        try expect(!SelfUpdateSoak.isSoaked("0.2.0", fingerprint: fp("0.2.0"), now: t, record: future), "a sighting in the future counted")
        try expect(SelfUpdateSoak.observe("0.2.0", fingerprint: fp("0.2.0"), now: t, record: future) == future,
                   "a sighting in the future was rewritten, so a clock set back could restart the soak early")
    }

    check("self automatic: a clock set back never shortens the soak; it stays unsoaked until 24 hours after the first sighting") {
        let t = on(11, 2)
        let first = SelfUpdateSoak.observe("0.2.0", fingerprint: fp("0.2.0"), now: t, record: nil)
        // The clock is set back 25 hours and a check runs: the sighting is kept as it is, and is not soaked.
        let back = SelfUpdateSoak.observe("0.2.0", fingerprint: fp("0.2.0"), now: t - 25 * hour, record: first)
        try expect(back == first, "a check with the clock set back moved the sighting: \(back)")
        try expect(!SelfUpdateSoak.isSoaked("0.2.0", fingerprint: fp("0.2.0"), now: t - 25 * hour, record: back), "soaked with the clock set back")
        // Real time goes on: an hour after the first sighting it is still not soaked; at 24 hours it is.
        let later = SelfUpdateSoak.observe("0.2.0", fingerprint: fp("0.2.0"), now: t + hour, record: back)
        try expect(later == first, "the sighting moved: \(later)")
        try expect(!SelfUpdateSoak.isSoaked("0.2.0", fingerprint: fp("0.2.0"), now: t + hour, record: later), "soaked an hour after the first sighting")
        try expect(SelfUpdateSoak.isSoaked("0.2.0", fingerprint: fp("0.2.0"), now: t + 24 * hour, record: later), "not soaked 24 hours after the first sighting")
    }

    check("self automatic: the first sighting is recorded once by the check, whatever the setting, and a newer version resets it") {
        let (s, store) = selfSettings(enabled: false, selfUpdates: false)
        let r = SelfRig(now: on(11, 9), settings: s)
        r.rig.scheduler.start(); await r.settle()
        try expect(store.selfReleaseSighting == SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(11, 9)),
                   "first sighting: \(String(describing: store.selfReleaseSighting))")
        r.rig.clock.advance(UpdateCheckScheduler.interval); try r.rig.timer.fireActive(); await r.settle()
        try expect(store.selfReleaseSighting?.firstSeen == on(11, 9), "a later check moved the first sighting")
        r.lookup.result = signedRelease("0.3.0")
        r.rig.clock.advance(UpdateCheckScheduler.interval); try r.rig.timer.fireActive(); await r.settle()
        try expect(store.selfReleaseSighting == SelfReleaseSighting(version: "0.3.0", fingerprint: fp("0.3.0"), firstSeen: on(11, 15)),
                   "a newer version did not reset: \(String(describing: store.selfReleaseSighting))")
        try expect(r.selfInstalls.isEmpty, "installed with the setting off")
    }

    // MARK: The scheduled run

    check("self automatic: soaked and on, the scheduled run installs Patched once, after its app updates, and records it") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(10, 1))
        let r = SelfRig(now: on(11, 2), settings: s)
        var historyAtRelaunch: [HistoryRun] = []
        let history = r.history
        r.selfInstaller.onRelaunch = { historyAtRelaunch = history.runs() }
        r.rig.scheduler.start(); await r.settle()
        try expect(r.installOrder == ["update Alpha quit=false", "self-install 0.2.0"], "order: \(r.installOrder)")
        try expect(r.selfInstaller.relaunches == 1 && r.quits.count == 1, "relaunch \(r.selfInstaller.relaunches) quit \(r.quits.count)")
        try expect(r.rig.opener.nothingOpened, "something was opened: \(r.rig.opener.urls)")
        // Written before Patched reopens, so the new copy finds it.
        let own = historyAtRelaunch.first
        try expect(own?.trigger == .scheduled && own?.outcome == .updated && own?.items.count == 1, "history at relaunch: \(historyAtRelaunch)")
        let item = own?.items.first
        try expect(item?.name == "Patched" && item?.bundleID == "im.patched.app" && item?.oldVersion == "0.1.0"
                   && item?.newVersion == "0.2.0" && item?.result == .updated, "Patched's line: \(String(describing: item))")
        try expect(historyAtRelaunch.count == 2 && historyAtRelaunch[1].items.first?.name == "Alpha", "the app run is not kept apart: \(historyAtRelaunch)")
        // Later checks the same day never install it again.
        r.rig.clock.advance(UpdateCheckScheduler.interval); try r.rig.timer.fireActive(); await r.settle()
        try expect(r.selfInstalls.count == 1, "a later check installed again: \(r.selfInstalls)")
    }

    check("self automatic: with nothing else to install, the run still updates Patched") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(10, 1))
        let r = SelfRig([outcome(app("Alpha"), .upToDate)], now: on(11, 2), settings: s)
        r.rig.scheduler.start(); await r.settle()
        try expect(r.installOrder == ["self-install 0.2.0"], "order: \(r.installOrder)")
    }

    check("self automatic: Stop during the run's last app also cancels Patched's own update") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(10, 1))
        let r = SelfRig(now: on(11, 2), settings: s)
        let controller = r.controller
        // Stop is pressed while the only app is installing, so nothing is left for it to skip.
        r.rig.installer.updateHandler = { outcome, _ in
            await MainActor.run { controller.stopUpdateAll() }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        r.rig.scheduler.start(); await r.settle()
        try expect(r.installOrder == ["update Alpha quit=false"], "Patched was updated after Stop: \(r.installOrder)")
        try expect(r.selfInstaller.relaunches == 0 && r.quits.count == 0, "reopened after Stop")
        // Later checks the same day do not bring it back.
        r.rig.clock.advance(UpdateCheckScheduler.interval); try r.rig.timer.fireActive(); await r.settle()
        try expect(r.selfInstalls.isEmpty, "a later check installed Patched after Stop: \(r.selfInstalls)")
    }

    check("self automatic: under 24 hours nothing installs; the next day's run, past 24 hours, does") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(10, 3))
        let r = SelfRig(now: on(11, 2), settings: s)
        r.rig.scheduler.start(); await r.settle()
        try expect(r.installOrder == ["update Alpha quit=false"], "installed Patched after 23 hours: \(r.installOrder)")
        try expect(r.selfInstaller.relaunches == 0 && r.quits.count == 0, "reopened")
        r.rig.clock.date = on(12, 2, 10); r.rig.wake.wake(); try r.rig.timer.fireActive(); await r.settle()
        try r.rig.timer.fireActive(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0"], "next day: \(r.selfInstalls)")
    }

    check("self automatic: a release first seen in the future (a clock set back) does not install and keeps its sighting") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(20, 1))
        let r = SelfRig(now: on(11, 2), settings: s)
        r.rig.scheduler.start(); await r.settle()
        try expect(r.selfInstalls.isEmpty, "installed on a future sighting")
        try expect(store.selfReleaseSighting?.firstSeen == on(20, 1), "the future sighting was rewritten: \(String(describing: store.selfReleaseSighting))")
    }

    // MARK: Bound to a fresh offer and to the release content

    check("self automatic: a lookup that fails on the run's own check never installs from an earlier offer, even when soaked") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        // The evening before: a check outside the window finds 0.2.0, so the offer is on screen.
        let r = SelfRig(now: on(10, 23), settings: s)
        r.rig.scheduler.start(); await r.settle()
        try expect(r.controller.selfUpdate?.version == "0.2.0" && r.selfInstalls.isEmpty, "the evening check: \(String(describing: r.controller.selfUpdate))")
        // The run's own check: GitHub cannot be reached. The earlier offer stays on screen, but is not acted on.
        r.lookup.result = .unavailable
        r.rig.clock.advance(UpdateCheckScheduler.interval); try r.rig.timer.fireActive(); await r.settle()
        try expect(r.controller.lastRun?.trigger == .scheduled, "the scheduled run did not happen: \(String(describing: r.controller.lastRun))")
        try expect(r.controller.selfUpdate?.version == "0.2.0", "a failed lookup dropped the offer")
        try expect(r.selfInstalls.isEmpty && r.quits.count == 0, "installed from a stale offer: \(r.selfInstalls)")
        try expect(store.selfReleaseSighting?.firstSeen == on(1, 1), "a failed lookup changed the sighting: \(String(describing: store.selfReleaseSighting))")
        // The controller refuses too, whatever the caller says.
        try expect(!r.controller.installSelfUpdateAutomatically(version: "0.2.0", fingerprint: fp("0.2.0"), checkGeneration: r.controller.checkGeneration),
                   "the controller installed after a failed lookup")
        try expect(r.selfInstalls.isEmpty, "installed: \(r.selfInstalls)")
    }

    check("self automatic: a release that vanishes clears its sighting; when it returns, the 24 hours start again") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        let r = SelfRig(now: on(10, 23), settings: s, release: .noNews)
        r.rig.scheduler.start(); await r.settle()
        try expect(store.selfReleaseSighting == nil, "no news kept the sighting: \(String(describing: store.selfReleaseSighting))")
        // It is published again, just before the run's own check.
        r.lookup.result = signedRelease("0.2.0")
        r.rig.clock.advance(UpdateCheckScheduler.interval); try r.rig.timer.fireActive(); await r.settle()
        try expect(r.controller.lastRun?.trigger == .scheduled, "the scheduled run did not happen")
        try expect(store.selfReleaseSighting == SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(11, 2)),
                   "the returned release did not start again: \(String(describing: store.selfReleaseSighting))")
        try expect(r.selfInstalls.isEmpty, "installed a release that came back minutes ago: \(r.selfInstalls)")
        // The next day's run, 24 hours after it came back, installs it.
        r.rig.clock.date = on(12, 2, 10); r.rig.wake.wake(); try r.rig.timer.fireActive(); await r.settle()
        try r.rig.timer.fireActive(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0"], "next day: \(r.selfInstalls)")
    }

    check("self automatic: the same version with a replaced file starts the 24 hours again, and installs the content that waited") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        // Soaked for 0.2.0 as first uploaded, but the run's check sees a new upload under the same names.
        let r = SelfRig(now: on(11, 2), settings: s, release: signedRelease("0.2.0", upload: 2))
        r.rig.scheduler.start(); await r.settle()
        try expect(r.controller.lastRun?.trigger == .scheduled, "the scheduled run did not happen")
        try expect(store.selfReleaseSighting == SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0", upload: 2), firstSeen: on(11, 2)),
                   "a replaced file kept the old sighting: \(String(describing: store.selfReleaseSighting))")
        try expect(r.selfInstalls.isEmpty, "installed a replaced file before 24 hours: \(r.selfInstalls)")
        try expect(!r.controller.installSelfUpdateAutomatically(version: "0.2.0", fingerprint: fp("0.2.0"), checkGeneration: r.controller.checkGeneration),
                   "the controller installed the content that soaked although the offer is now another")
        // A day later, the new upload has waited its 24 hours: that is what is installed.
        r.rig.clock.date = on(12, 2, 10); r.rig.wake.wake(); try r.rig.timer.fireActive(); await r.settle()
        try r.rig.timer.fireActive(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0"] && r.selfInstaller.fingerprints == [fp("0.2.0", upload: 2)],
                   "next day: \(r.selfInstalls) \(r.selfInstaller.fingerprints)")
    }

    check("self automatic: a release without a content fingerprint can be installed with a click, never automatically") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: nil, firstSeen: on(1, 1))
        let r = SelfRig(now: on(11, 2), settings: s, release: signedRelease("0.2.0", fingerprint: .some(nil)))
        r.rig.scheduler.start(); await r.settle()
        try expect(r.controller.lastRun?.trigger == .scheduled, "the scheduled run did not happen")
        try expect(r.selfInstalls.isEmpty, "installed a release with no fingerprint: \(r.selfInstalls)")
        try expect(r.controller.canInstallSelfUpdate, "a click can no longer install it")
        // A sighting stored before fingerprints (nil) is a new sighting once a fingerprinted release is seen.
        let (s2, store2) = selfSettings()
        store2.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: nil, firstSeen: on(1, 1))
        let old = SelfRig(now: on(11, 2), settings: s2)
        old.rig.scheduler.start(); await old.settle()
        try expect(old.selfInstalls.isEmpty && store2.selfReleaseSighting == SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(11, 2)),
                   "an unfingerprinted sighting counted: \(old.selfInstalls) \(String(describing: store2.selfReleaseSighting))")
    }

    check("self automatic: never with the box off, automatic updates off, or managed off") {
        let cases: [(String, Bool, Bool, [String: Any])] = [
            ("box off", true, false, [:]),
            ("automatic off", false, true, [:]),
            ("automatic managed off", true, true, [AutomaticUpdateSettings.enabledKey: false]),
            ("box managed off", true, true, [AutomaticUpdateSettings.selfUpdatesKey: false]),
            ("box managed invalid", true, true, [AutomaticUpdateSettings.selfUpdatesKey: "yes"])]
        for (name, enabled, box, managed) in cases {
            let (s, store) = selfSettings(enabled: enabled, selfUpdates: box, managed: managed)
            store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
            let r = SelfRig(now: on(11, 2), settings: s)
            r.rig.scheduler.start(); await r.settle()
            try expect(r.selfInstalls.isEmpty && r.quits.count == 0, "\(name): installed Patched")
        }
    }

    check("self automatic: never from Update All, a check or a release that has no signed zip") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        // Past today's window: checks run, Update All runs, Patched is never installed.
        let r = SelfRig(now: on(11, 9), settings: s)
        r.rig.scheduler.start(); await r.settle()
        try expect(r.controller.updateAll(), "Update All did not start")
        await r.settle()
        try expect(r.installOrder == ["update Alpha quit=false"], "Update All or a check installed Patched: \(r.installOrder)")
        r.rig.clock.advance(UpdateCheckScheduler.interval); try r.rig.timer.fireActive(); await r.settle()
        try expect(r.selfInstalls.isEmpty, "a check installed Patched: \(r.selfInstalls)")
        // Due, but the release can only be downloaded by hand.
        let (s2, store2) = selfSettings()
        store2.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        let page = URL(string: "https://github.com/birdseeed/patched/releases/tag/v0.2.0")!
        let notifyOnly = SelfRig(now: on(11, 2), settings: s2, release: .newer(PatchedRelease(version: "0.2.0", pageURL: page)))
        notifyOnly.rig.scheduler.start(); await notifyOnly.settle()
        try expect(notifyOnly.selfInstalls.isEmpty && notifyOnly.rig.opener.nothingOpened, "a notify-only release installed or opened")
    }

    check("self automatic: waits for Patched's own lookup to answer, then installs") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        let r = SelfRig([outcome(app("Alpha"), .upToDate)], now: on(11, 2), settings: s)
        let gate = Gate(); r.lookup.gate = gate
        r.rig.scheduler.start()
        var spins = 0
        while (r.controller.lastRun == nil || r.controller.isWorking || r.controller.phase != .idle) && spins < 10_000 { await Task.yield(); spins += 1 }
        try expect(r.controller.lastRun != nil, "the run did not finish")
        try expect(r.selfInstalls.isEmpty && r.controller.selfLookupPending, "installed before the lookup answered")
        gate.open(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0"], "did not install once the lookup answered: \(r.selfInstalls)")
    }

    check("self automatic: never over an open question or work in progress") {
        let (s, _) = selfSettings()
        let r = SelfRig(now: on(11, 1), settings: s)
        await runCheck(r.controller)
        try expect(r.controller.idleForAutomaticSelfUpdate, "an idle controller is not idle")
        r.controller.requestSelfUpdate()
        try expect(!r.controller.idleForAutomaticSelfUpdate && !r.controller.installSelfUpdateAutomatically(version: "0.2.0", fingerprint: fp("0.2.0"), checkGeneration: r.controller.checkGeneration),
                   "installed over the user's open confirmation")
        r.controller.cancelSelfUpdate()
        try expect(!r.controller.installSelfUpdateAutomatically(version: "0.3.0", fingerprint: fp("0.3.0"), checkGeneration: r.controller.checkGeneration), "installed a version that is not on offer")
        let held = r.rig.hold()
        r.controller.check()
        try expect(!r.controller.installSelfUpdateAutomatically(version: "0.2.0", fingerprint: fp("0.2.0"), checkGeneration: r.controller.checkGeneration), "installed during a check")
        held.open(); await r.settle()
        try expect(r.selfInstalls.isEmpty, "installed: \(r.selfInstalls)")
        // An automatic run that has to wait for an open confirmation installs nothing, Patched included.
        let (s2, store2) = selfSettings()
        store2.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        let waiting = SelfRig(now: on(11, 1), settings: s2)
        await runCheck(waiting.controller)
        waiting.controller.requestSelfUpdate()
        waiting.rig.clock.date = on(11, 2)
        waiting.rig.scheduler.start(); await waiting.settle()
        try expect(waiting.installOrder.isEmpty, "ran over an open confirmation: \(waiting.installOrder)")
    }

    check("self automatic: a failure leaves Patched as it was, opens nothing, keeps the offer and is recorded") {
        let cases: [(InstallRefusal, String)] = [(.releaseSignatureInvalid("does not match"), "isn't signed with Patched's release key"),
                                                 (.needsAdmin("root-owned"), "without admin rights")]
        for (refusal, words) in cases {
            let (s, store) = selfSettings()
            store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
            let r = SelfRig(now: on(11, 2), settings: s)
            r.selfInstaller.failure = refusal
            r.rig.scheduler.start(); await r.settle()
            try expect(r.selfInstalls == ["self-install 0.2.0"], "\(refusal.code): \(r.selfInstalls)")
            try expect(r.selfInstaller.relaunches == 0 && r.quits.count == 0, "\(refusal.code): reopened or quit")
            try expect(r.rig.opener.nothingOpened, "\(refusal.code): opened \(r.rig.opener.urls)")
            try expect(r.controller.selfInstall == .idle && r.controller.canInstallSelfUpdate && !r.controller.isWorking,
                       "\(refusal.code): state \(r.controller.selfInstall)")
            let run = r.history.runs().first
            let item = run?.items.first
            try expect(run?.trigger == .scheduled && run?.outcome == .failed && item?.name == "Patched" && item?.result == .failed
                       && item?.oldVersion == "0.1.0" && item?.newVersion == nil && item?.detail == refusal.code
                       && (item?.reason ?? "").contains(words), "\(refusal.code): history \(String(describing: run))")
        }
    }

    check("self automatic: a failed release is not tried automatically again; a click still can, and a new version or upload is tried") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        let r = SelfRig(now: on(11, 2), settings: s)
        r.selfInstaller.failure = .releaseSignatureInvalid("does not match")
        r.rig.scheduler.start(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0"], "first day: \(r.selfInstalls)")
        try expect(store.selfUpdateAttempt == SelfReleaseAttempt(version: "0.2.0", fingerprint: fp("0.2.0")), "attempt not recorded")
        // The next day's run leaves the same release alone (and writes no second failure), but the offer stays.
        r.rig.clock.date = on(12, 2, 10); r.rig.wake.wake(); try r.rig.timer.fireActive(); await r.settle()
        try r.rig.timer.fireActive(); await r.settle()
        try expect(r.controller.lastRun?.trigger == .scheduled, "the next day's run did not happen")
        try expect(r.selfInstalls == ["self-install 0.2.0"], "retried the same release: \(r.selfInstalls)")
        try expect(r.history.runs().filter { $0.items.contains { $0.name == "Patched" } }.count == 1, "a second Patched line in the history")
        try expect(r.controller.canInstallSelfUpdate, "a click can no longer install it")
        // The same version with a new upload, once it has waited 24 hours, is tried (and fails again here).
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0", upload: 2), firstSeen: on(1, 1))
        r.lookup.result = signedRelease("0.2.0", upload: 2)
        r.rig.clock.date = on(13, 2, 10); r.rig.wake.wake(); try r.rig.timer.fireActive(); await r.settle()
        try r.rig.timer.fireActive(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0", "self-install 0.2.0"] && r.selfInstaller.fingerprints.last == fp("0.2.0", upload: 2),
                   "a new upload was not tried: \(r.selfInstalls)")
        // A newer version is tried too.
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.3.0", fingerprint: fp("0.3.0"), firstSeen: on(1, 1))
        r.lookup.result = signedRelease("0.3.0")
        r.rig.clock.date = on(14, 2, 10); r.rig.wake.wake(); try r.rig.timer.fireActive(); await r.settle()
        try r.rig.timer.fireActive(); await r.settle()
        try expect(r.selfInstalls.last == "self-install 0.3.0" && r.selfInstalls.count == 3, "a newer version was not tried: \(r.selfInstalls)")
        // A click still installs a release the automatic path gave up on.
        r.selfInstaller.failure = nil
        r.controller.requestSelfUpdate(); r.controller.confirmSelfUpdate(); await r.settle()
        try expect(r.selfInstalls.count == 4 && r.selfInstalls.last == "self-install 0.3.0", "the click did not install: \(r.selfInstalls)")
    }

    check("self automatic: installed but could not reopen: the old copy does not install it again each day") {
        let (s, store) = selfSettings()
        store.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        let r = SelfRig(now: on(11, 2), settings: s)
        r.selfInstaller.relaunchFails = true
        r.rig.scheduler.start(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0"] && r.selfInstaller.relaunches == 1 && r.quits.count == 0,
                   "first day: \(r.selfInstalls) relaunches \(r.selfInstaller.relaunches) quits \(r.quits.count)")
        // The old process keeps running and still reports its old version, so the lookup still says 0.2.0 is newer.
        r.rig.clock.date = on(12, 2, 10); r.rig.wake.wake(); try r.rig.timer.fireActive(); await r.settle()
        try r.rig.timer.fireActive(); await r.settle()
        try expect(r.controller.lastRun?.trigger == .scheduled, "the next day's run did not happen")
        try expect(r.selfInstalls == ["self-install 0.2.0"], "installed again: \(r.selfInstalls)")
    }

    check("self automatic: only the scheduler's opt-in path calls the automatic install, once, and it adds no installer of its own") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources").path
        let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String]) ?? []
        var callers: [String: Int] = [:]
        for relative in files where relative.hasSuffix(".swift") {
            let text = try String(contentsOfFile: root + "/" + relative, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            let n = code.components(separatedBy: "installSelfUpdateAutomatically(").count - 1
            if n > 0 { callers[relative] = n }
        }
        try expect(callers == ["PatchedClient/BackgroundUpdateChecks.swift": 1, "PatchedClient/AppUpdatesController.swift": 1],
                   "automatic self-install callers: \(callers)")
        let controller = try String(contentsOfFile: root + "/PatchedClient/AppUpdatesController.swift", encoding: .utf8)
        // Both entries share one install body; neither builds its own SelfUpdater.
        try expect(controller.components(separatedBy: "startSelfInstall(").count - 1 == 3, "the two entries do not share startSelfInstall")
        try expect(controller.components(separatedBy: "SelfUpdater(").count - 1 == 1, "a second SelfUpdater appeared")
    }

    // MARK: The one-time offer after a confirmed self-update

    check("self offer: a confirmed self-update offers it once in the reopened Patched; an automatic one does not") {
        let (s, store) = selfSettings(enabled: false, selfUpdates: false)
        let r = SelfRig(now: on(11, 9), settings: s)
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), appUpdates: r.controller,
                                          automaticUpdates: s)
        await runCheck(r.controller)
        try expect(!s.showsSelfUpdateNote && !store.selfUpdateNotePending, "offered before any self-update")
        r.controller.requestSelfUpdate(); r.controller.confirmSelfUpdate(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0"] && store.selfUpdateNotePending, "the confirmed update did not mark the offer")
        _ = session
        // The reopened copy reads the same store.
        let (reopened, _) = selfSettings(enabled: false, selfUpdates: false, store: store)
        try expect(reopened.showsSelfUpdateNote, "not offered after the confirmed update")
        try expect(reopened.selfUpdateNoteText.contains("This also turns on automatic updates")
                   && reopened.selfUpdateNoteAcceptTitle == "Turn on automatic updates", "does not say it turns on automatic updates: \(reopened.selfUpdateNoteText)")
        let text = try paintedText(AppUpdatesView(controller: r.controller, automaticUpdates: reopened))
        try expect(text.contains("Not now") && text.contains("update itself"), "the offer is not on the Updates screen: \(text)")
        reopened.selfUpdateNoteShown()
        try expect(reopened.showsSelfUpdateNote && store.selfUpdateNoteDone && !store.selfUpdateNotePending, "shown did not persist, or hid it")
        let (third, _) = selfSettings(enabled: false, selfUpdates: false, store: store)
        try expect(!third.showsSelfUpdateNote, "offered a second time")
        // A later confirmed self-update never brings it back.
        third.markSelfUpdateNotePending()
        try expect(!store.selfUpdateNotePending && !selfSettings(enabled: false, selfUpdates: false, store: store).0.showsSelfUpdateNote, "came back")

        // The automatic path never marks it.
        let (auto, autoStore) = selfSettings()
        autoStore.selfReleaseSighting = SelfReleaseSighting(version: "0.2.0", fingerprint: fp("0.2.0"), firstSeen: on(1, 1))
        let a = SelfRig(now: on(11, 2), settings: auto)
        let autoSession = NativeClientSession(navigation: ShellNavigation(destination: .updates), appUpdates: a.controller, automaticUpdates: auto)
        a.rig.scheduler.start(); await a.settle()
        try expect(a.selfInstalls == ["self-install 0.2.0"] && !autoStore.selfUpdateNotePending, "the automatic update marked the offer")
        _ = autoSession
    }

    check("self manual: a confirmed update is recorded as a single-app run before Patched reopens") {
        let (s, _) = selfSettings(enabled: false, selfUpdates: false)
        let r = SelfRig(now: on(11, 9), settings: s)
        var historyAtRelaunch: [HistoryRun] = []
        let history = r.history
        r.selfInstaller.onRelaunch = { historyAtRelaunch = history.runs() }
        await runCheck(r.controller)
        try expect(history.runs().isEmpty, "recorded before the update")
        r.controller.requestSelfUpdate(); r.controller.confirmSelfUpdate(); await r.settle()
        try expect(r.selfInstalls == ["self-install 0.2.0"] && r.selfInstaller.relaunches == 1, "installs \(r.selfInstalls)")
        let own = historyAtRelaunch.first
        try expect(historyAtRelaunch.count == 1 && own?.trigger == .singleApp && own?.outcome == .updated && own?.items.count == 1,
                   "history at relaunch: \(historyAtRelaunch)")
        let item = own?.items.first
        try expect(item?.name == "Patched" && item?.bundleID == "im.patched.app" && item?.oldVersion == "0.1.0"
                   && item?.newVersion == "0.2.0" && item?.result == .updated, "Patched's line: \(String(describing: item))")
        try expect(history.runs().count == 1, "recorded more than once: \(history.runs().count)")
    }

    check("self manual: a failed confirmed update is recorded, and the failure screen and release page are as before") {
        let cases: [(InstallRefusal, String)] = [(.releaseSignatureInvalid("does not match"), "isn't signed with Patched's release key"),
                                                 (.needsAdmin("root-owned"), "without admin rights")]
        for (refusal, words) in cases {
            let (s, _) = selfSettings(enabled: false, selfUpdates: false)
            let r = SelfRig(now: on(11, 9), settings: s)
            r.selfInstaller.failure = refusal
            await runCheck(r.controller)
            r.controller.requestSelfUpdate(); r.controller.confirmSelfUpdate(); await r.settle()
            try expect(r.selfInstaller.relaunches == 0 && r.quits.count == 0, "\(refusal.code): reopened or quit")
            try expect(r.controller.selfInstall.isFailed && !r.controller.isWorking, "\(refusal.code): state \(r.controller.selfInstall)")
            try expect(r.rig.opener.nothingOpened == (refusal.code != "needs_admin"), "\(refusal.code): opened \(r.rig.opener.urls)")
            let run = r.history.runs().first
            let item = run?.items.first
            try expect(r.history.runs().count == 1 && run?.trigger == .singleApp && run?.outcome == .failed && item?.name == "Patched"
                       && item?.result == .failed && item?.oldVersion == "0.1.0" && item?.newVersion == nil && item?.detail == refusal.code
                       && (item?.reason ?? "").contains(words), "\(refusal.code): history \(String(describing: run))")
        }
    }

    check("self offer: Turn on switches on automatic updates and the box; Not now changes nothing; both end it") {
        let pending = MemoryAutomaticUpdateStore(); pending.selfUpdateNotePending = true
        let (accept, store) = selfSettings(enabled: false, selfUpdates: false, store: pending)
        try expect(accept.showsSelfUpdateNote, "not offered")
        accept.acceptSelfUpdateNote()
        try expect(store.enabled && store.selfUpdatesEnabled && accept.selfUpdatesEnabled, "Turn on did not turn both on")
        try expect(!accept.showsSelfUpdateNote && store.selfUpdateNoteDone, "Turn on left the offer")
        // Automatic updates already on: it says so and only ticks the box.
        let onStore = MemoryAutomaticUpdateStore(); onStore.selfUpdateNotePending = true
        let (already, _) = selfSettings(enabled: true, selfUpdates: false, store: onStore)
        try expect(already.selfUpdateNoteAcceptTitle == "Turn on" && !already.selfUpdateNoteText.contains("This also turns on"), "wording with automatic on")
        already.acceptSelfUpdateNote()
        try expect(onStore.selfUpdatesEnabled && onStore.selfUpdateNoteDone, "Turn on with automatic on")
        let noStore = MemoryAutomaticUpdateStore(); noStore.selfUpdateNotePending = true
        let (decline, _) = selfSettings(enabled: false, selfUpdates: false, store: noStore)
        decline.declineSelfUpdateNote()
        try expect(!noStore.enabled && !noStore.selfUpdatesEnabled && noStore.selfUpdateNoteDone && !decline.showsSelfUpdateNote, "Not now changed something or stayed")
        try expect(!selfSettings(enabled: false, selfUpdates: false, store: noStore).0.showsSelfUpdateNote, "Not now came back")
    }

    check("self offer: never shown when managed, when automatic updates are managed off, or when already on") {
        let cases: [(String, Bool, Bool, [String: Any])] = [
            ("box managed off", true, false, [AutomaticUpdateSettings.selfUpdatesKey: false]),
            ("box managed on", true, true, [AutomaticUpdateSettings.selfUpdatesKey: true]),
            ("box managed invalid", true, false, [AutomaticUpdateSettings.selfUpdatesKey: 1]),
            ("automatic managed off", false, false, [AutomaticUpdateSettings.enabledKey: false]),
            ("automatic managed invalid", false, false, [AutomaticUpdateSettings.enabledKey: "on"]),
            ("already on", true, true, [:])]
        for (name, enabled, box, managed) in cases {
            let store = MemoryAutomaticUpdateStore(); store.selfUpdateNotePending = true
            let (s, _) = selfSettings(enabled: enabled, selfUpdates: box, managed: managed, store: store)
            try expect(!s.showsSelfUpdateNote, "\(name): offered")
            s.acceptSelfUpdateNote()
            try expect(store.selfUpdatesEnabled == box && store.enabled == enabled, "\(name): Turn on changed a setting it may not")
        }
        // Automatic updates managed on with the box free: offered, and Turn on ticks only the box.
        let store = MemoryAutomaticUpdateStore(); store.selfUpdateNotePending = true
        let (s, _) = selfSettings(enabled: false, selfUpdates: false, managed: [AutomaticUpdateSettings.enabledKey: true], store: store)
        try expect(s.showsSelfUpdateNote && s.selfUpdateNoteAcceptTitle == "Turn on", "managed on, box free: not offered")
        s.acceptSelfUpdateNote()
        try expect(s.selfUpdatesEnabled && !store.enabled, "Turn on wrote the managed automatic setting")
    }
}
