import Foundation
import UpdateSources
import UpdateInstaller
import PatchedShell
@_spi(Testing) import PatchedClient

// macOS notifications on a fake clock: once per version, the optional reminder schedule, never for a major and
// never while Patched is installing, rolling back or recovering. Nothing real is notified, stored or opened.

private let day: TimeInterval = 24 * 60 * 60

@MainActor private func macRig(_ result: MacOSUpdateResult, days: Int? = nil,
                               outcomes: [AppCheckOutcome] = [outcome(app("Alpha"), .upToDate)],
                               installer: FakeInstaller = FakeInstaller()) -> (Rig, FakeMacOSLookup, MemoryMacOSReminderStore) {
    let store = MemoryMacOSReminderStore(reminderDays: days)
    let rig = Rig(outcomes, installer: installer, macOSReminders: MacOSReminderSettings(store: store))
    let lookup = FakeMacOSLookup(result)
    rig.controller.macOSUpdateCheck = lookup.check
    return (rig, lookup, store)
}

/// Moves the fake clock on and lets the 3-hour timer fire a scheduled check.
@MainActor private func scheduledCheck(_ rig: Rig, after seconds: TimeInterval) async throws {
    rig.clock.advance(seconds)
    try rig.timer.fireActive()
    await rig.settle()
}

@MainActor private func macPosts(_ rig: Rig) -> [String] {
    rig.notifier.postedMacOS.map { ($0.reminder ? "reminder " : "") + $0.notice.update.version }
}

@MainActor func registerMacOSReminderChecks() {
    check("macOS notify: one notification per version, and none for the same version again") {
        let (rig, lookup, store) = macRig(.found(macOSStatus()))
        rig.scheduler.start(); await rig.settle()
        try expect(macPosts(rig) == ["27.2.1"], "posted: \(macPosts(rig))")
        try expect(store.notifiedKey == "im.patched.macos\u{1F}minor\u{1F}27.2.1" && store.notifiedAt == rig.clock.date, "not recorded: \(String(describing: store.notifiedKey))")
        for _ in 0..<8 { try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1) }
        try expect(macPosts(rig) == ["27.2.1"], "repeated without reminders: \(macPosts(rig))")
        lookup.result = .found(macOSStatus(minor: "27.2.2"))
        try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1)
        try expect(macPosts(rig) == ["27.2.1", "27.2.2"], "next version: \(macPosts(rig))")
        // The app-updates notification never carries macOS, and nothing was opened.
        try expect(!rig.notifier.posted.joined().contains { $0.name.contains("macOS") }, "macOS in the app notification")
        try rig.noInstallerActivity()
    }

    check("macOS notify: reminders are off by default; a denied notification is tried again") {
        let settings = MacOSReminderSettings(store: MemoryMacOSReminderStore())
        try expect(settings.reminderDays == nil && MacOSReminderSettings.choices == [1, 3, 7], "default: \(String(describing: settings.reminderDays))")
        settings.setReminderDays(5)
        try expect(settings.reminderDays == nil, "an unoffered interval was kept")
        settings.setReminderDays(3)
        try expect(settings.reminderDays == 3 && MacOSReminderSettings.choiceTitle(3) == "Every 3 days" && MacOSReminderSettings.choiceTitle(1) == "Every day"
                   && MacOSReminderSettings.choiceTitle(nil) == "Off", "titles")
        let (rig, _, store) = macRig(.found(macOSStatus()))
        rig.notifier.delivers = false
        rig.scheduler.start(); await rig.settle()
        try expect(store.notifiedKey == nil && macPosts(rig).count == 1, "a denied notification counted as told")
        rig.notifier.delivers = true
        try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1)
        try expect(macPosts(rig) == ["27.2.1", "27.2.1"] && store.notifiedKey != nil, "not retried: \(macPosts(rig))")
    }

    check("macOS notify: a reminder every N days while the same update is outstanding, at most once a day") {
        let (rig, lookup, _) = macRig(.found(macOSStatus()), days: 3)
        rig.scheduler.start(); await rig.settle()
        // Scheduled checks every 3 hours for 7 days.
        var log: [(Double, [String])] = []
        for step in 1...56 {
            try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1)
            log.append((Double(step) * (UpdateCheckScheduler.interval + 1) / day, macPosts(rig)))
        }
        try expect(macPosts(rig) == ["27.2.1", "reminder 27.2.1", "reminder 27.2.1"], "posted: \(macPosts(rig))")
        // The first reminder came at the first check at least 3 days later.
        let firstReminder = try log.first { $0.1.count == 2 }.unwrap().0
        try expect(firstReminder >= 3 && firstReminder < 3.2, "first reminder after \(firstReminder) days")
        // Daily: one notification per day at most, however often Patched checks.
        let (daily, _, _) = macRig(.found(macOSStatus()), days: 1)
        daily.scheduler.start(); await daily.settle()
        for _ in 1...24 { try await scheduledCheck(daily, after: UpdateCheckScheduler.interval + 1) }
        try expect(macPosts(daily).count == 4, "daily over 3 days: \(macPosts(daily))")
        // Installed (up to date): reminders stop.
        lookup.result = .found(macOSStatus(minor: nil, running: "27.2.1"))
        try await scheduledCheck(rig, after: 4 * day)
        try expect(macPosts(rig).count == 3, "reminded after the update was installed: \(macPosts(rig))")
    }

    check("macOS notify: never for a new major, and not for a version hidden with Not now") {
        let (rig, _, _) = macRig(.found(macOSStatus(minor: nil, major: "28.0")), days: 1)
        rig.scheduler.start(); await rig.settle()
        for _ in 0..<16 { try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1) }
        try expect(rig.notifier.postedMacOS.isEmpty, "notified a major: \(macPosts(rig))")
        try expect(rig.controller.macOSNotice?.isMajor == true, "fixture has no major row")
        let (hidden, _, _) = macRig(.found(macOSStatus()), days: 1)
        hidden.controller.macOSHiding = MemoryMacOSUpdateHiding(hiddenKeys: ["im.patched.macos\u{1F}minor\u{1F}27.2.1"])
        hidden.scheduler.start(); await hidden.settle()
        for _ in 0..<16 { try await scheduledCheck(hidden, after: UpdateCheckScheduler.interval + 1) }
        try expect(hidden.notifier.postedMacOS.isEmpty, "notified a hidden version: \(macPosts(hidden))")
    }

    check("macOS notify: a check the user started counts as seen and starts the reminder clock") {
        let (rig, _, store) = macRig(.found(macOSStatus()), days: 1)
        rig.store.lastCheck = rig.clock.date        // the launch check is skipped, so the user's check is the first
        rig.scheduler.start(); await rig.settle()
        rig.controller.check(); await rig.settle()
        try expect(rig.notifier.postedMacOS.isEmpty && store.notifiedKey != nil, "the user's own check notified: \(macPosts(rig))")
        try await scheduledCheck(rig, after: UpdateCheckScheduler.interval)
        try expect(rig.notifier.postedMacOS.isEmpty, "reminded within a day")
        for _ in 0..<8 { try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1) }
        try expect(macPosts(rig) == ["reminder 27.2.1"], "posted: \(macPosts(rig))")
    }

    check("macOS notify: a check the user starts restarts the reminder clock for a known update") {
        let (rig, _, store) = macRig(.found(macOSStatus()), days: 1)
        rig.scheduler.start(); await rig.settle()
        try expect(macPosts(rig) == ["27.2.1"], "first: \(macPosts(rig))")
        rig.clock.advance(23 * 60 * 60)
        rig.controller.check(); await rig.settle()
        try expect(store.notifiedAt == rig.clock.date, "the user's check did not restart the clock")
        try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1)
        try expect(macPosts(rig) == ["27.2.1"], "reminded just after the user looked: \(macPosts(rig))")
        for _ in 0..<7 { try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1) }
        try expect(macPosts(rig) == ["27.2.1", "reminder 27.2.1"], "no reminder a day after the user looked: \(macPosts(rig))")
    }

    check("macOS notify: a stored time in the future, or a clock set back, restarts the clock instead of reminding") {
        let (rig, _, store) = macRig(.found(macOSStatus()), days: 1)
        rig.scheduler.start(); await rig.settle()
        store.notifiedAt = rig.clock.date.addingTimeInterval(10 * day)
        try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1)
        try expect(macPosts(rig) == ["27.2.1"] && store.notifiedAt == rig.clock.date, "future time: \(macPosts(rig)), \(String(describing: store.notifiedAt))")
        for _ in 0..<8 { try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1) }
        try expect(macPosts(rig) == ["27.2.1", "reminder 27.2.1"], "after the clamp: \(macPosts(rig))")
        // The clock goes back five days: no reminder at once, then one a day later.
        let (back, _, backStore) = macRig(.found(macOSStatus()), days: 1)
        back.scheduler.start(); await back.settle()
        back.clock.advance(-5 * day)
        try back.timer.fireActive(); await back.settle()
        try expect(macPosts(back) == ["27.2.1"] && backStore.notifiedAt == back.clock.date, "clock set back: \(macPosts(back))")
        for _ in 0..<8 { try await scheduledCheck(back, after: UpdateCheckScheduler.interval + 1) }
        try expect(macPosts(back) == ["27.2.1", "reminder 27.2.1"], "after the clock went back: \(macPosts(back))")
    }

    check("macOS notify: none while an install is running; the next check after it tells") {
        let a = app("Alpha")
        let installer = FakeInstaller()
        let installGate = Gate(), lookupGate = Gate()
        installer.updateHandler = { _, _ in
            await installGate.wait()
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let (rig, _, store) = macRig(.found(macOSStatus()), days: 1, outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer)
        // The lookup answers only once the install has started.
        rig.controller.macOSUpdateCheck = { await lookupGate.wait(); return .found(macOSStatus()) }
        rig.scheduler.start()
        for _ in 0..<200 where rig.controller.phase == .checking { try await Task.sleep(nanoseconds: 5_000_000) }
        rig.controller.update(id: a.path)
        try expect(rig.controller.isWorking, "fixture: the install did not start")
        lookupGate.open()
        for _ in 0..<200 where rig.controller.macOSLookupPending { try await Task.sleep(nanoseconds: 5_000_000) }
        try expect(rig.controller.macOSNotice != nil && rig.notifier.postedMacOS.isEmpty && store.notifiedKey == nil,
                   "notified during an install: \(macPosts(rig))")
        installGate.open(); await rig.settle()
        try await scheduledCheck(rig, after: UpdateCheckScheduler.interval + 1)
        try expect(macPosts(rig) == ["27.2.1"], "not told after the install: \(macPosts(rig))")
    }

    check("macOS notify: the notification opens Updates and carries no action; Settings offers the reminder") {
        try expect(SystemUpdateNotifier.route(requestIdentifier: SystemUpdateNotifier.macOSUpdateIdentifier,
                                              actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier") == .openUpdates, "body tap")
        try expect(SystemUpdateNotifier.route(requestIdentifier: SystemUpdateNotifier.macOSUpdateIdentifier,
                                              actionIdentifier: SystemUpdateNotifier.updateAllActionIdentifier) == nil, "Update All on the macOS notification")
        let notice = try MacOSUpdateNotice(macOSStatus()).unwrap()
        try expect(notice.notificationTitle(reminder: false) == "macOS 27.2.1 is available"
                   && notice.notificationTitle(reminder: true) == "Reminder: macOS 27.2.1 is available", "titles")
        try expect(MacOSUpdateNotice.notificationBody.contains("never installs macOS"), "body: \(MacOSUpdateNotice.notificationBody)")
        // The scheduler's file names no way to open Software Update or install macOS.
        let text = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/BackgroundUpdateChecks.swift", encoding: .utf8)
        for word in ["openSoftwareUpdate", "SoftwareUpdateLinks", "softwareupdate"] { try expect(!text.contains(word), "scheduler mentions \(word)") }
    }
}
