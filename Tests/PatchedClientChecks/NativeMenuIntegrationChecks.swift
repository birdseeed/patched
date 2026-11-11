import Foundation
import SwiftUI
import AppKit
import PatchedShell
@_spi(Testing) import PatchedClient

// Independent acceptance preparation. Sessions use the inert updates owner, so nothing
// is scanned or checked unless a check below asks for it explicitly.
@MainActor private func menuSession() -> NativeClientSession {
    let navigation = ShellNavigation(destination: .support)
    return NativeClientSession(navigation: navigation)
}

@MainActor private func menuHonesty(_ session: NativeClientSession) throws {
    let text = session.menuText
    try expect(text.backgroundStatus.lowercased().contains("unavailable"), "Unavailable background checks/notifications not explained")
    try expect(session.appUpdates.menuUpdates().header == "No update check yet" && session.appUpdates.availableUpdateCount == 0,
               "Menu invented update state before any check")
}

// Never shown or activated. Painting does not establish menu-bar, keyboard,
// VoiceOver, close/reopen or native lifecycle acceptance.
@MainActor private func menuPaint(_ session: NativeClientSession, openWindow: @escaping () -> Void,
    afterFirstPaint: (@MainActor () async throws -> Void)? = nil) async throws -> [Data] {
    let app = NSApplication.shared
    if app.activationPolicy() != .prohibited { _ = app.setActivationPolicy(.prohibited) }
    try expect(app.activationPolicy() == .prohibited && !app.isActive, "Menu capture must remain prohibited/inactive")
    let host = NSHostingView(rootView: NativeClientMenuView(session: session, openWindow: openWindow)
        .frame(width: 380, height: 440).environment(\.colorScheme, .light))
    host.frame = NSRect(x: 0, y: 0, width: 380, height: 440)
    host.appearance = NSAppearance(named: .aqua)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    func capture() throws -> Data {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let deadline = Date().addingTimeInterval(0.20)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CheckFailure(description: "Menu bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try expect(!window.isVisible && !app.isActive && app.activationPolicy() == .prohibited,
                   "Menu capture became visible/active")
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "Menu pixels unavailable")
        }
        return bytes
    }
    let first = try capture()
    if let afterFirstPaint {
        try await afterFirstPaint()
        return [first, try capture()]
    }
    return [first]
}

@MainActor func registerNativeMenuIntegrationChecks() {
    check("ordinary idle menu claims no update or background readiness") {
        let session = NativeClientSession()
        try expect(!session.appUpdates.hasChecked && session.appUpdates.phase != .checking, "Default menu construction checked")
        try expect(session.menuText.backgroundStatus.lowercased().contains("unavailable"),
                   "Background checks reported running before they were started")
    }
    check("all menu route actions retain the exact injected owners") {
        let session = menuSession()
        let navigation = session.navigation, updates = session.appUpdates
        let routes: [(NativeClientMenuAction, ShellDestination)] = [(.updates, .updates), (.applications, .applications)]
        for (action, destination) in routes {
            navigation.select(.support)
            try expect(session.performMenuAction(action), "Route did not request main-window reopening")
            try expect(navigation.destination == destination, "Menu selected the wrong destination")
            try expect(session.navigation === navigation && session.appUpdates === updates, "Menu route replaced a shared owner")
        }
        try expect(!updates.hasChecked, "Menu route checked without an explicit Check Now")
        try menuHonesty(session)
    }
    check("repeated selected menu routes still request stable-window reopening without selection callbacks") {
        var selections = 0
        let navigation = ShellNavigation(destination: .updates, onSelection: { _ in selections += 1 })
        let session = NativeClientSession(navigation: navigation)
        for _ in 0..<4 { try expect(session.performMenuAction(.updates), "Already-selected Updates cannot reopen the window") }
        try expect(selections == 0, "Reopening retriggered selection side effects")
    }
    check("menu Check Now is a read-only check that never requests the window") {
        let session = menuSession()
        try expect(!session.performMenuAction(.checkNow), "Check Now requested a route/window change")
        await session.appUpdates.waitUntilIdle()
        try expect(session.appUpdates.hasChecked && session.navigation.destination == .support, "Check Now did not check, or navigated")
    }
    check("reading and painting every menu route is inert and never reopens a window") {
        let session = menuSession(); var reopenings = 0
        for destination in ShellDestination.allCases {
            session.navigation.select(destination)
            for _ in 0..<5 { _ = session.menuText }
            _ = try await menuPaint(session, openWindow: { reopenings += 1 })
        }
        try expect(reopenings == 0 && !session.appUpdates.hasChecked, "Presentation checked or reopened a window")
        try menuHonesty(session)
    }
    check("rendering menu after an update check paints the new status") {
        let session = menuSession(); var reopenings = 0
        let pixels = try await menuPaint(session, openWindow: { reopenings += 1 }, afterFirstPaint: {
            try expect(session.appUpdates.menuUpdates().header == "No update check yet", "Menu header before a check")
            session.appUpdates.check(); await session.appUpdates.waitUntilIdle()
            try expect(session.appUpdates.menuUpdates().header.hasPrefix("Up to date"), "Menu header after a check")
        })
        try expect(pixels.count == 2 && pixels[0] != pixels[1],
                   "Same mounted menu view did not observe its retained updates owner")
        try expect(reopenings == 0, "Menu paint reopened a window")
    }
    check("app composes actual MenuBarExtra and shared view over its sole stable session/window") {
        let app = code(try source("Sources/PatchedApp/PatchedApp.swift"))
        for binding in ["MenuBarExtra(", "NativeClientMenuView(session: session", "NativeClientRootView(session: session)",
                        "id: NativeClientMenuWindow.id", "openWindow(id: NativeClientMenuWindow.id)",
                        "Settings {", "NativeClientSettingsView(session: session)", "@Environment(\\.openSettings)",
                        "openSettings()", "Selector((\"showSettingsWindow:\"))", "openSettings: {"] {
            try expect(app.contains(binding), "App lacks the real native scene binding: \(binding)")
        }
        try expect(app.components(separatedBy: "NativeClientSession()").count == 2,
                   "App must construct exactly one session for both scenes")
        try expect(!app.contains("@_spi"), "App imports fixture injection")
    }
    check("shared menu view exposes only the five explicit shared-owner actions") {
        let menu = code(try source("Sources/PatchedClient/NativeClientMenu.swift"))
        try expect(menu.contains("Button(") && menu.contains("session.performMenuAction("), "Menu has no real explicit action wiring")
        for action in [".checkNow", ".updates", "openSettings()"] {
            try expect(menu.contains(action), "Menu lacks explicit action \(action)")
        }
        try expect(!menu.contains("navigation.select(.settings)"), "Settings is still a route in the main window")
        try expect(menu.contains("openWindow()"), "Route buttons cannot reopen the stable window")
    }
    check("user-session close-window policy is explicit and adopted by the native app delegate") {
        try expect(NativeClientLifecyclePolicy.continuesSessionAfterLastWindowCloses,
                   "Closed-window menu session policy is not implemented")
        let app = try swiftSources("Sources/PatchedApp").map { code($0.1) }.joined(separator: "\n")
        for binding in ["@NSApplicationDelegateAdaptor", "applicationShouldTerminateAfterLastWindowClosed",
                        "NativeClientLifecyclePolicy.continuesSessionAfterLastWindowCloses"] {
            try expect(app.contains(binding), "Native app does not adopt lifecycle policy: \(binding)")
        }
    }
    check("native menu composition adds no automatic work, notifications or productive update route") {
        let app = try swiftSources("Sources/PatchedApp").map { code($0.1) }.joined(separator: "\n")
        let menu = code(try source("Sources/PatchedClient/NativeClientMenu.swift"))
        for forbidden in [".task", ".onAppear", "Timer", "URLSession", "UNUserNotificationCenter", "requestAuthorization",
                          "SMAppService", "LaunchAgent", "Process(", "ArtifactInspector", "installationAuthorized: true",
                          "LocalApplicationInventory(", "LocalApplicationsController(", "ClientController(", ".scan("] {
            try expect(!(app + menu).contains(forbidden), "Menu/app adds forbidden operation or competing owner: \(forbidden)")
        }
    }
}
