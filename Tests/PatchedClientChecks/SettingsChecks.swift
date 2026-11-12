import Foundation
import SwiftUI
import AppKit
import PatchedShell
@_spi(Testing) import PatchedClient

@MainActor private final class SettingsOpener: ExternalURLOpening {
    var opened: [URL] = []
    func open(_ url: URL) -> Bool { opened.append(url); return true }
    func openApplication(bundleID: String) async -> Bool { false }
    func openApplication(atPath path: String, expectedBundleID: String, expectedTeamID: String?) async -> AppOpenResult { .failed }
}
@MainActor private final class PermissionAnswer { var value: NotificationPermission; var reads = 0
    init(_ value: NotificationPermission) { self.value = value } }
@MainActor private func settingsPaint(_ session: NativeClientSession) throws -> Data {
    let app = NSApplication.shared
    if app.activationPolicy() != .prohibited { _ = app.setActivationPolicy(.prohibited) }
    let host = NSHostingView(rootView: NativeClientSettingsView(session: session).frame(width: 900, height: 700))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let deadline = Date().addingTimeInterval(0.15)
    while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01))) }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure(description: "Settings bitmap unavailable") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try expect(!window.isVisible && !app.isActive, "Settings capture became visible/active")
    guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(description: "Settings pixels unavailable") }
    return bytes
}

@MainActor func registerSettingsChecks() {
    check("settings: notification status text covers every permission and never claims an unknown state") {
        let answer = PermissionAnswer(.unknown)
        let status = NotificationStatusController(reader: { deliver in answer.reads += 1; deliver(answer.value) })
        try expect(status.permission == .unknown && answer.reads == 0, "Construction read notification permission")
        var texts: [NotificationPermission: String] = [:]
        for permission in [NotificationPermission.allowed, .denied, .notDetermined, .unknown] {
            answer.value = permission; status.refresh()
            try expect(status.permission == permission, "Refresh did not publish \(permission)")
            texts[permission] = status.statusText
        }
        try expect(answer.reads == 4 && Set(texts.values).count == 4, "Permission states share wording")
        try expect(texts[.unknown] == "Notification status is unavailable." && texts[.allowed]!.contains("on")
                   && texts[.denied]!.contains("off"), "Notification wording is misleading")
    }
    check("settings: Open Notification Settings opens exactly the macOS Notifications pane") {
        let opener = SettingsOpener()
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), urlOpener: opener)
        try expect(session.openNotificationSettings(), "Notification Settings did not open")
        try expect(opener.opened == [URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!],
                   "Opened the wrong place: \(opener.opened)")
        let inert = NativeClientSession(navigation: ShellNavigation(destination: .updates))
        try expect(!inert.openNotificationSettings(), "The inert opener opened something")
    }
    check("settings: the screen paints with each notification state and starts no check") {
        let answer = PermissionAnswer(.allowed)
        let status = NotificationStatusController(reader: { $0(answer.value) })
        let session = NativeClientSession(navigation: ShellNavigation(destination: .updates), notificationStatus: status)
        let allowed = try settingsPaint(session)
        answer.value = .denied; status.refresh()
        let denied = try settingsPaint(session)
        try expect(allowed != denied, "Notification state does not change the Settings screen")
        try expect(!session.appUpdates.hasChecked && session.appUpdates.phase != .checking, "Settings started a check")
    }
    check("settings: the screen holds only Open at login, the schedule line, automatic updates, notifications and the version") {
        let view = code(try source("Sources/PatchedClient/SettingsView.swift"))
        for token in ["OpenAtLoginView(controller: openAtLogin)", "Self.scheduleText", "notifications.statusText",
                      "Open Notification Settings", "Text(\"Version\")", "Install updates automatically",
                      ".disabled(automaticUpdates.enabledLocked)", ".disabled(automaticUpdates.timeLocked || !automaticUpdates.isEnabled)",
                      "AutomaticUpdateSettings.lockedNote", "AutomaticUpdateSettings.invalidNote", "Form {", ".formStyle(.grouped)", "Section("] {
            try expect(view.contains(token), "Settings lacks \(token)")
        }
        try expect(SettingsView.scheduleText == "Patched checks for updates when it opens and every 3 hours. It only installs updates on its own if you turn on automatic updates below.",
                   "Schedule line changed")
        for stale in ["Toggle(\"Automatic", "Pause", "Network", "Diagnostics", "Save schedule", "Reload saved", "requestAuthorization"] {
            try expect(!view.contains(stale), "Settings still has \(stale)")
        }
        let root = code(try source("Sources/PatchedClient/NativeClientSession.swift"))
        try expect(!root.contains("case .settings") && !root.contains("SettingsView(") && !root.contains("NativeScheduleSettingsView")
                   && !root.contains("NativeNetworkSettingsView") && !root.contains("unavailable in this preview"), "Root still routes settings inside the main window")
        let app = code(try source("Sources/PatchedApp/PatchedApp.swift"))
        try expect(app.contains("Settings {") && app.contains("NativeClientSettingsView(session: session)"), "No standard Settings scene")
    }
}
