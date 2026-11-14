import Foundation
import UpdateSources
import UpdateInstaller
import PatchedShell
@_spi(Testing) import PatchedClient

// The pinned macOS row: what it shows, where it shows, and where it must never reach. A fake lookup stands in for
// Apple's feed and the Software Update plist; nothing is fetched, read or opened for real.

func macOSStatus(minor: String? = "27.2.1", major: String? = nil, running: String = "27.0.1",
                 source: MacOSUpdate.Source = .appleFeed) -> MacOSUpdateStatus {
    MacOSUpdateStatus(runningVersion: running,
                      minor: minor.map { MacOSUpdate(kind: .minor, version: $0, build: "26B131", postingDate: "2026-11-09", source: source) },
                      major: major.map { MacOSUpdate(kind: .major, version: $0, build: "27A100", postingDate: "2026-11-10", source: source) },
                      source: source)
}

/// A macOS lookup whose answer can change, counting its calls.
final class FakeMacOSLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: MacOSUpdateResult
    private var _calls = 0
    init(_ result: MacOSUpdateResult) { _result = result }
    var result: MacOSUpdateResult { get { lock.withLock { _result } } set { lock.withLock { _result = newValue } } }
    var calls: Int { lock.withLock { _calls } }
    var check: MacOSUpdateCheck { { [self] in lock.withLock { _calls += 1; return _result } } }
}

/// True when the opener was ever asked for Software Update or System Settings.
@MainActor func openedSoftwareUpdate(_ opener: RecordingOpener) -> Bool {
    opener.urls.contains(SoftwareUpdateLinks.settingsURL) || opener.apps.contains(SoftwareUpdateLinks.systemSettingsBundleID)
}

@MainActor func registerMacOSUpdateChecks() {
    func controller(_ result: MacOSUpdateResult, outcomes: [AppCheckOutcome] = [outcome(app("Alpha"), .upToDate)],
                    installer: FakeInstaller = FakeInstaller(), hiding: MemoryMacOSUpdateHiding = MemoryMacOSUpdateHiding())
        -> (AppUpdatesController, FakeMacOSLookup, RecordingOpener) {
        let lookup = FakeMacOSLookup(result)
        let c = makeController(outcomes: outcomes, installer: installer)
        c.macOSUpdateCheck = lookup.check
        c.macOSHiding = hiding
        let opener = RecordingOpener()
        c.urlOpener = opener
        return (c, lookup, opener)
    }

    check("macOS row: a minor update shows version, posting date and Open Software Update") {
        let (c, lookup, opener) = controller(.found(macOSStatus()))
        try expect(c.macOSNotice == nil, "shown before any check")
        await runCheck(c)
        let notice = try c.macOSNotice.unwrap()
        try expect(lookup.calls == 1 && !c.macOSLookupPending, "lookups: \(lookup.calls)")
        try expect(!notice.isMajor && notice.title == "macOS 27.2.1" && notice.versionChange == "27.0.1 → 27.2.1", "notice: \(notice)")
        try expect(notice.statusText == "Update available. Install it in Software Update.", "status: \(notice.statusText)")
        try expect(notice.postedText(locale: Locale(identifier: "en_GB")) == "Released 9 Nov 2026", "posted: \(String(describing: notice.postedText(locale: Locale(identifier: "en_GB"))))")
        try expect(opener.nothingOpened, "a check opened something: \(opener.urls)")
        try expect(await c.openSoftwareUpdate() && opener.urls == [SoftwareUpdateLinks.settingsURL] && opener.apps.isEmpty, "opened: \(opener.urls) \(opener.apps)")
        try expect(SoftwareUpdateLinks.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.Software-Update-Settings.extension", "settings URL")
        // When the pane's URL does not open, System Settings itself is opened instead.
        opener.failURLs = true
        try expect(await c.openSoftwareUpdate() && opener.apps == [SoftwareUpdateLinks.systemSettingsBundleID], "fallback: \(opener.apps)")
    }

    check("macOS row: a major alone is quiet and informational; a major beside a minor is a note") {
        let (c, _, _) = controller(.found(macOSStatus(minor: nil, major: "28.0")))
        await runCheck(c)
        let major = try c.macOSNotice.unwrap()
        try expect(major.isMajor && major.title == "macOS 28 is available" && major.menuTitle == "macOS 28 is available", "major: \(major)")
        try expect(major.statusText.contains("won't remind"), "major status: \(major.statusText)")
        let (both, _, _) = controller(.found(macOSStatus(minor: "27.2.1", major: "28.0")))
        await runCheck(both)
        let notice = try both.macOSNotice.unwrap()
        try expect(!notice.isMajor && notice.alsoMajorText == "macOS 28 is also available.", "both: \(notice)")
        let (none, _, _) = controller(.found(macOSStatus(minor: nil, major: nil)))
        await runCheck(none)
        try expect(none.macOSNotice == nil, "up to date shows a row")
    }

    check("macOS row: a lookup that could not tell keeps what was known; a newer check replaces it") {
        let (c, lookup, _) = controller(.found(macOSStatus()))
        await runCheck(c)
        lookup.result = .unavailable
        await runCheck(c)
        try expect(c.macOSNotice?.update.version == "27.2.1", "unavailable cleared the row")
        lookup.result = .found(macOSStatus(minor: nil, running: "27.2.1"))
        await runCheck(c)
        try expect(c.macOSNotice == nil && c.macOSStatus?.runningVersion == "27.2.1", "up to date still shows: \(String(describing: c.macOSNotice))")
    }

    check("macOS row: Not now hides it per user until the next version") {
        let hiding = MemoryMacOSUpdateHiding()
        let (c, lookup, opener) = controller(.found(macOSStatus()), hiding: hiding)
        await runCheck(c)
        c.hideMacOSUpdate()
        try expect(c.macOSNotice == nil && hiding.hiddenKeys == ["im.patched.macos\u{1F}minor\u{1F}27.2.1"], "hidden: \(hiding.hiddenKeys)")
        try expect(opener.nothingOpened, "Not now opened something")
        await runCheck(c)
        try expect(c.macOSNotice == nil, "the same version came back")
        // Remembered: another controller over the same store keeps it hidden.
        let (again, _, _) = controller(.found(macOSStatus()), hiding: hiding)
        await runCheck(again)
        try expect(again.macOSNotice == nil, "not remembered")
        lookup.result = .found(macOSStatus(minor: "27.2.2"))
        await runCheck(c)
        try expect(c.macOSNotice?.update.version == "27.2.2", "the next version stayed hidden")
    }

    check("macOS row: hiding the minor update falls back to the major, in its quieter style") {
        let hiding = MemoryMacOSUpdateHiding()
        let (c, _, _) = controller(.found(macOSStatus(minor: "27.2.1", major: "28.0")), hiding: hiding)
        await runCheck(c)
        try expect(c.macOSNotice?.isMajor == false, "fixture: the minor is not shown first")
        c.hideMacOSUpdate()
        let major = try c.macOSNotice.unwrap()
        try expect(major.isMajor && major.title == "macOS 28 is available" && major.alsoMajorText == nil, "after Not now: \(major)")
        c.hideMacOSUpdate()
        try expect(c.macOSNotice == nil && hiding.hiddenKeys == ["im.patched.macos\u{1F}minor\u{1F}27.2.1", "im.patched.macos\u{1F}major\u{1F}28"],
                   "hiding the major too: \(hiding.hiddenKeys)")
    }

    check("macOS keys: 27.2 and 27.2.0 are one version for Not now and notifications") {
        let short = try MacOSUpdateNotice(macOSStatus(minor: "27.2")).unwrap()
        let long = try MacOSUpdateNotice(macOSStatus(minor: "27.2.0")).unwrap()
        try expect(short.key == long.key && short.key == "im.patched.macos\u{1F}minor\u{1F}27.2", "keys: \(short.key) \(long.key)")
        let hiding = MemoryMacOSUpdateHiding()
        let (c, lookup, _) = controller(.found(macOSStatus(minor: "27.2")), hiding: hiding)
        await runCheck(c)
        c.hideMacOSUpdate()
        lookup.result = .found(macOSStatus(minor: "27.2.0"))
        await runCheck(c)
        try expect(c.macOSNotice == nil, "27.2.0 came back after hiding 27.2")
    }

    check("macOS menu: listed like an update, opening Updates at the macOS row only") {
        let (c, _, opener) = controller(.found(macOSStatus()))
        await runCheck(c)
        let session = NativeClientSession(navigation: ShellNavigation(destination: .applications), appUpdates: c, urlOpener: opener)
        let items = session.menuItems
        let item = try items.first { $0.id == "row:" + MacOSUpdateNotice.rowID }.unwrap()
        try expect(item.title == "macOS  27.0.1 → 27.2.1 — Software Update" && item.action == .showMacOSUpdate, "item: \(item)")
        try expect(items.contains { $0.id == "updates-separator" }, "no separator before the macOS item")
        var windows = 0
        let menu = NativeClientMenuView(session: session, openWindow: { windows += 1 })
        menu.perform(.showMacOSUpdate)
        try expect(windows == 1 && session.navigation.destination == .updates && c.focusedRowID == MacOSUpdateNotice.rowID, "focus: \(String(describing: c.focusedRowID))")
        try expect(opener.nothingOpened, "the menu item opened Software Update by itself")
        try expect(!items.contains { $0.action == .updateAll }, "Update All offered for macOS alone")
    }

    // Exclusions. macOS is never a row or an outcome, so Update All, automatic updates and the command line's
    // `update` have nothing of it to act on. Each check below fails if that ever changes.

    check("macOS exclusion: Update All neither counts nor opens the macOS update") {
        let a = app("Alpha")
        let installer = FakeInstaller()
        let (alone, _, aloneOpener) = controller(.found(macOSStatus()))
        await runCheck(alone)
        try expect(alone.macOSNotice != nil, "fixture has no macOS row")
        try expect(alone.updateAllCount == 0 && !alone.canUpdateAll && !alone.updateAllMenu.visible, "macOS counted: \(alone.updateAllCount) \(alone.updateAllMenu)")
        try expect(alone.availableUpdateCount == 0 && alone.appStoreRows.isEmpty && alone.updatableRows.isEmpty, "macOS in the app counts")
        try expect(!alone.updateAll(), "Update All started for macOS alone")
        await alone.waitUntilIdle()
        try expect(aloneOpener.nothingOpened, "Update All opened \(aloneOpener.urls) \(aloneOpener.apps)")
        // Beside an app update: only the app counts and only the app is installed.
        let (c, _, opener) = controller(.found(macOSStatus()), outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer)
        await runCheck(c)
        try expect(c.updateAllCount == 1 && c.updateAllMenu.title == "Update All (1)", "count: \(c.updateAllCount) \(c.updateAllMenu.title)")
        await runOperation(c) { c.updateAll() }
        try expect(updateEvents(installer) == ["update Alpha quit=false"], "installs: \(updateEvents(installer))")
        try expect(!openedSoftwareUpdate(opener), "Update All opened Software Update")
        try expect(c.macOSNotice != nil, "Update All dismissed the macOS row")
        // The menu and notification entry points end in the same place.
        let entry = UpdateAllEntryPoint(controller: alone, summaryNotifier: nil)
        entry.requestUpdateAll(); entry.requestUpdateAll(only: [MacOSUpdateNotice.rowID, try alone.macOSNotice.unwrap().key])
        await alone.waitUntilIdle()
        try expect(aloneOpener.nothingOpened, "an Update All entry point opened Software Update")
    }

    check("macOS exclusion: automatic updates leave the macOS update alone") {
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = TimeZone(identifier: "GMT")!
        let store = MemoryAutomaticUpdateStore()
        store.enabled = true; store.time = TimeOfDay(string: "02:00")!
        let automatic = AutomaticUpdateSettings(store: store, managed: ManagedPreferences(reader: NoManagedPreferences()))
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], automatic: automatic, calendar: gmt)
        rig.clock.date = gmt.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 2, minute: 5))!
        let lookup = FakeMacOSLookup(.found(macOSStatus()))
        rig.controller.macOSUpdateCheck = lookup.check
        rig.scheduler.start(); await rig.settle(); await rig.settle()
        try expect(rig.controller.macOSNotice != nil && store.lastRunDay != nil, "fixture: no macOS row or no automatic run")
        try expect(!rig.notifier.posted.joined().contains { $0.name.contains("macOS") }, "macOS in the app-updates notification")
        try expect(updateEvents(rig.installer) == ["update Alpha quit=false"], "installs: \(updateEvents(rig.installer))")
        try expect(rig.opener.nothingOpened, "the automatic run opened \(rig.opener.urls) \(rig.opener.apps)")
    }

    check("macOS exclusion: source guard, only a click reaches Open Software Update; the CLI's update never looks at macOS") {
        let root = sourcesRoot()
        for file in ["PatchedClient/UpdateAllEntryPoints.swift", "PatchedClient/AutomaticUpdates.swift"] {
            let text = try String(contentsOfFile: root + "/" + file, encoding: .utf8)
            for word in ["openSoftwareUpdate", "SoftwareUpdateLinks", "macOSNotice", "macOSStatus", "MacOSUpdate"] {
                try expect(!text.contains(word), "\(file) mentions \(word)")
            }
        }
        // The scheduler reads the macOS notice to announce it, but has no way to open Software Update.
        let scheduler = try String(contentsOfFile: root + "/PatchedClient/BackgroundUpdateChecks.swift", encoding: .utf8)
        for word in ["openSoftwareUpdate", "SoftwareUpdateLinks", "hideMacOSUpdate"] {
            try expect(!scheduler.contains(word), "BackgroundUpdateChecks.swift mentions \(word)")
        }
        // Inside the controller, Update All's body never names macOS.
        let controller = try String(contentsOfFile: root + "/PatchedClient/AppUpdatesController.swift", encoding: .utf8)
        let start = try controller.range(of: "func updateAll(only keys: Set<String>?").unwrap()
        let end = try controller.range(of: "func stopUpdateAll()", range: start.upperBound..<controller.endIndex).unwrap()
        let body = String(controller[start.lowerBound..<end.lowerBound])
        for word in ["macOS", "MacOS", "SoftwareUpdate"] { try expect(!body.contains(word), "Update All mentions \(word)") }
        // The command line: the macOS line is printed only after the read-only check, never in `update`.
        let cli = try String(contentsOfFile: root + "/PatchedCLI/main.swift", encoding: .utf8)
        let update = try cli.range(of: "case \"update\":").unwrap()
        let rollback = try cli.range(of: "case \"rollback\":").unwrap()
        let updateBlock = String(cli[update.lowerBound..<rollback.lowerBound])
        for word in ["MacOS", "macOS", "SoftwareUpdate"] { try expect(!updateBlock.contains(word), "CLI update mentions \(word)") }
        let checkSection = try cli.range(of: "// MARK: check").unwrap()
        let uses = cli.ranges(of: "MacOSUpdateChecker.check")
        try expect(uses.count == 1 && uses[0].lowerBound > checkSection.lowerBound, "CLI macOS lookup outside check")
    }

    check("macOS CLI line: update, up to date, major, plist fallback and unavailable") {
        try expect(MacOSUpdateNotice.commandLineLine(.found(macOSStatus())) ==
                   "macOS 27.0.1: UPDATE AVAILABLE 27.2.1 (26B131), released 2026-11-09. Install it in System Settings > General > Software Update.",
                   MacOSUpdateNotice.commandLineLine(.found(macOSStatus())))
        try expect(MacOSUpdateNotice.commandLineLine(.found(macOSStatus(minor: nil))) == "macOS 27.0.1: up to date.", "up to date")
        try expect(MacOSUpdateNotice.commandLineLine(.found(macOSStatus(minor: nil, major: "28.0"))) == "macOS 27.0.1: up to date. macOS 28 is available (28.0).", "major")
        let plist = MacOSUpdateStatus(runningVersion: "27.0.1", minor: MacOSUpdate(kind: .minor, version: "27.2.1", build: "26B131", source: .softwareUpdate),
                                      major: nil, source: .softwareUpdate)
        try expect(MacOSUpdateNotice.commandLineLine(.found(plist)) ==
                   "macOS 27.0.1: UPDATE AVAILABLE 27.2.1 (26B131) (from Software Update). Install it in System Settings > General > Software Update.",
                   MacOSUpdateNotice.commandLineLine(.found(plist)))
        try expect(MacOSUpdateNotice.commandLineLine(.unavailable).hasPrefix("macOS: couldn't check"), "unavailable")
    }
}
