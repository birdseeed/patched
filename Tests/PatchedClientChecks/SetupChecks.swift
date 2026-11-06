import Foundation
import Darwin
import SwiftUI
import AppKit
import PatchedShell
import UpdateSources
@_spi(Testing) import PatchedClient

// First-run setup and the one flag that records its completion. The store is always the in-memory
// fake or the tripwire-guarded defaults store; legacy records are read only from .build folders.
@MainActor private func setupPaint(_ session: NativeClientSession, dark: Bool = false) throws -> Data {
    let app = NSApplication.shared
    if app.activationPolicy() != .prohibited { _ = app.setActivationPolicy(.prohibited) }
    try expect(app.activationPolicy() == .prohibited && !app.isActive, "Setup capture must stay prohibited/inactive")
    let host = NSHostingView(rootView: NativeClientRootView(session: session)
        .frame(width: 680, height: 520).environment(\.colorScheme, dark ? .dark : .light))
    host.frame = NSRect(x: 0, y: 0, width: 680, height: 520)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let deadline = Date().addingTimeInterval(0.15)
    while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01))) }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure(description: "Setup bitmap unavailable") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try expect(!window.isVisible && !app.isActive, "Setup capture became visible/active")
    guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(description: "Setup pixels unavailable") }
    return bytes
}
@MainActor private struct SetupFixture {
    let navigation = ShellNavigation(destination: .applications)
    let store: MemorySetupCompletion
    let controller: NativeFirstRunController
    let session: NativeClientSession
    init(completed: Bool = false) {
        store = MemorySetupCompletion(completed: completed)
        controller = NativeFirstRunController(navigation: navigation, completion: store)
        session = NativeClientSession(navigation: navigation, firstRun: controller)
    }
}
private func legacyRecord(completed: Any?, networkDraft: Bool = true) throws -> Data {
    var setup: [String: Any] = ["failureReports": false]
    if let completed { setup["completed"] = completed }
    if networkDraft { setup["networkDraft"] = ["mode": "manualHTTP", "host": "proxy.invalid", "port": "8080"] }
    let record: [String: Any] = ["schema": 3, "scheduled": "{\"schema\":2}", "setup": setup,
                                 "setupMutations": [["id": "m1", "completed": true]]]
    return try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
}

@MainActor func registerSetupChecks() {
    check("setup: a fresh install presents welcome; a completed setup is not presented again") {
        let fresh = SetupFixture()
        try expect(fresh.controller.isPresented && fresh.controller.step == .welcome && !fresh.controller.setupCompleted, "Fresh install skipped setup")
        let done = SetupFixture(completed: true)
        try expect(!done.controller.isPresented && done.store.marks == 0, "Completed setup reappeared")
    }
    check("setup: Continue walks the three steps and Back returns without recording anything") {
        let f = SetupFixture()
        f.controller.advance(); try expect(f.controller.step == .review && f.controller.isPresented, "Welcome did not continue")
        f.controller.advance(); try expect(f.controller.step == .findApps && f.controller.isPresented, "Review did not continue")
        f.controller.back(); try expect(f.controller.step == .review, "Back from the last step")
        f.controller.back(); f.controller.back(); try expect(f.controller.step == .welcome, "Back from review")
        try expect(f.store.marks == 0 && !f.store.completed, "Navigating setup recorded completion")
    }
    check("setup: the last step records completion exactly once and opens Updates") {
        let f = SetupFixture()
        f.controller.advance(); f.controller.advance(); f.controller.advance()
        try expect(!f.controller.isPresented && f.navigation.destination == .updates && f.store.marks == 1 && f.store.completed,
                   "Last step did not complete setup and open Updates")
        f.controller.openUpdates(); f.controller.advance()
        try expect(f.store.marks == 1, "Completion recorded again after setup closed")
        let next = NativeFirstRunController(navigation: ShellNavigation(destination: .updates), completion: f.store)
        try expect(!next.isPresented, "A later launch with the same store shows setup again")
    }
    check("setup: dismiss and present change only presentation") {
        let f = SetupFixture()
        f.controller.dismiss(); try expect(!f.controller.isPresented && f.store.marks == 0, "Dismiss recorded completion")
        f.controller.present(); try expect(f.controller.isPresented && f.controller.step == .welcome, "Present lost setup state")
    }
    check("setup: the ordinary defaults store stays in memory under the tripwire") {
        try expect(RealStateTripwire.isActive, "Checks must run with PATCHED_FORBID_REAL_STATE=1")
        var touched = 0
        let store = DefaultsSetupCompletion(defaults: { touched += 1; return UserDefaults(suiteName: "patched-checks-never-used")! })
        try expect(!store.completed, "Tripwire store started completed")
        store.markCompleted()
        try expect(store.completed && touched == 0, "Tripwire store reached a defaults domain (\(touched) times)")
        let s = NativeClientSession()
        try expect(s.firstRun.isPresented && s.firstRun.step == .welcome, "Ordinary session suppressed welcome")
    }
    check("setup: root paints distinct welcome, review and last steps, then the shell after completion") {
        let f = SetupFixture()
        let welcome = try setupPaint(f.session); f.controller.advance()
        let review = try setupPaint(f.session); f.controller.advance()
        let last = try setupPaint(f.session); _ = try setupPaint(f.session, dark: true)
        try expect(Set([welcome, review, last]).count == 3, "Setup steps paint identically")
        f.controller.openUpdates()
        let shell = try setupPaint(f.session)
        try expect(shell != last && !f.session.appUpdates.hasChecked, "Shell not restored, or painting checked")
    }
    check("setup: copy is plain English with no stale preference, network or failure controls") {
        let text = code(try source("Sources/PatchedClient/NativeFirstRunView.swift"))
        for token in ["Keep your Mac apps up to date", "How Patched works", "when it opens and every 3 hours",
                      "Checks never install anything", "Open Updates", "BrandMarkView(", ".keyboardShortcut(", ".accessibilityLabel("] {
            try expect(text.contains(token), "Required setup copy absent: \(token)")
        }
        for stale in ["Open app without saving", "Try again", "saveFailed", "networkPresented", "NativeNetworkSettingsView",
                      "Find apps", "Check daily", "failed-update reports", ".onAppear", ".task", "Timer", "URLSession"] {
            try expect(!text.contains(stale), "Stale setup content remains: \(stale)")
        }
    }
    check("legacy record: a completed record written by earlier builds still loads, network draft and all") {
        try expect(LegacySetupRecord.completed(record: try legacyRecord(completed: true)), "Completed legacy record with a network draft refused")
        try expect(LegacySetupRecord.completed(record: try legacyRecord(completed: true, networkDraft: false)), "Completed legacy record refused")
        try expect(!LegacySetupRecord.completed(record: try legacyRecord(completed: false)), "Unfinished legacy record counted")
        for odd: Any? in [nil, 1, "true", ["yes"]] {
            try expect(!LegacySetupRecord.completed(record: try legacyRecord(completed: odd)), "Non-boolean completed counted: \(String(describing: odd))")
        }
        for junk in [Data(), Data("not json".utf8), Data("[true]".utf8), Data("{\"setup\":true}".utf8)] {
            try expect(!LegacySetupRecord.completed(record: junk), "Malformed record counted")
        }
    }
    check("legacy record: both earlier locations are read; symlinks, folders and oversized files are not") {
        let made = try newDirectory("legacy-setup"); defer { try? FileManager.default.removeItem(at: made) }
        // The temporary folder sits under /var, itself a symlink to /private/var; use the real path.
        let root = made.resolvingSymlinksInPath()
        let folder = root.path
        try expect(!LegacySetupRecord.completed(inPatchedFolder: folder), "Empty folder counted")
        try legacyRecord(completed: true).write(to: root.appendingPathComponent("record.json"))
        try expect(LegacySetupRecord.completed(inPatchedFolder: folder), "Older top-level record not read")
        try FileManager.default.removeItem(at: root.appendingPathComponent("record.json"))
        let preferences = root.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("elsewhere.json")
        try legacyRecord(completed: true).write(to: target)
        try FileManager.default.createSymbolicLink(at: preferences.appendingPathComponent("record.json"), withDestinationURL: target)
        try expect(!LegacySetupRecord.completed(inPatchedFolder: folder), "Symlinked record followed")
        try FileManager.default.removeItem(at: preferences.appendingPathComponent("record.json"))
        try FileManager.default.createDirectory(at: preferences.appendingPathComponent("record.json"), withIntermediateDirectories: false)
        try expect(!LegacySetupRecord.completed(inPatchedFolder: folder), "Directory read as a record")
        try FileManager.default.removeItem(at: preferences.appendingPathComponent("record.json"))
        var big = try legacyRecord(completed: true); big.append(Data(repeating: 0x20, count: LegacySetupRecord.maximumBytes))
        try big.write(to: preferences.appendingPathComponent("record.json"))
        try expect(!LegacySetupRecord.completed(inPatchedFolder: folder), "Oversized record read")
        try legacyRecord(completed: true).write(to: preferences.appendingPathComponent("record.json"))
        try expect(LegacySetupRecord.completed(inPatchedFolder: folder), "Preferences record not read")
        let bytes = try Data(contentsOf: preferences.appendingPathComponent("record.json"))
        _ = LegacySetupRecord.completed(inPatchedFolder: folder)
        try expect(try Data(contentsOf: preferences.appendingPathComponent("record.json")) == bytes, "Legacy record was changed")
        // A symlinked ancestor folder is not followed: the same record through a linked Patched folder reads as absent.
        let linked = made.appendingPathComponent("linked-patched")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        // root is made's real path, so root/linked-patched is a real path whose last folder is the symlink.
        try expect(LegacySetupRecord.completed(inPatchedFolder: root.path), "fixture: record readable directly")
        try expect(!LegacySetupRecord.completed(inPatchedFolder: root.path + "/linked-patched"), "Symlinked ancestor followed")
    }
}
