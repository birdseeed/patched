import Foundation
import SwiftUI
import AppKit
import PatchedShell
@_spi(Testing) import PatchedClient

// Independent Phase A checks. No inventory is read and no update check runs.
@MainActor private func compositionNavigation() -> ShellNavigation {
    ShellNavigation(destination: .applications)
}
// Never shown or activated; this exercises SwiftUI layout/appearance without
// granting a native application launch or accessibility acceptance claim.
@MainActor private func compositionPaint(_ session: NativeClientSession) throws -> Data {
    let app = NSApplication.shared
    if app.activationPolicy() != .prohibited { _ = app.setActivationPolicy(.prohibited) }
    try expect(app.activationPolicy() == .prohibited && !app.isActive, "Composition capture must remain prohibited/inactive")
    let host = NSHostingView(rootView: NativeClientRootView(session: session)
        .frame(width: 1000, height: 800).environment(\.colorScheme, .light))
    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
    host.appearance = NSAppearance(named: .aqua)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let deadline = Date().addingTimeInterval(0.20)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
    }
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw CheckFailure(description: "Composition bitmap unavailable")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try expect(!window.isVisible && !app.isActive && app.activationPolicy() == .prohibited, "Composition capture became visible/active")
    guard let bytes = bitmap.representation(using: .png, properties: [:]) else {
        throw CheckFailure(description: "Composition pixels unavailable")
    }
    return bytes
}

@MainActor func registerNativeShellCompositionChecks() {
    check("ordinary default session retains safe idle owners through every route") {
        let session = NativeClientSession()
        let navigation = session.navigation, updates = session.appUpdates, setup = session.firstRun
        for destination in ShellDestination.allCases {
            navigation.select(destination)
            try expect(session.navigation === navigation && session.appUpdates === updates && session.firstRun === setup,
                       "Default session replaced a retained owner")
            try expect(!updates.hasChecked && updates.phase != .checking,
                       "Default session performed work without an explicit action")
        }
    }
    check("one injected owner survives every destination") {
        let navigation = compositionNavigation()
        let session = NativeClientSession(navigation: navigation)
        let updates = session.appUpdates
        for destination in ShellDestination.allCases {
            try expect(session.navigation === navigation && session.appUpdates === updates, "Session replaced an injected owner")
            session.navigation.select(destination)
        }
        try expect(session.navigation === navigation && session.appUpdates === updates, "Final owners changed")
    }
    check("construction, navigation and offscreen root rendering never check") {
        let navigation = compositionNavigation()
        let session = NativeClientSession(navigation: navigation)
        for destination in ShellDestination.allCases {
            navigation.select(destination); _ = try compositionPaint(session)
        }
        try expect(!session.appUpdates.hasChecked && session.appUpdates.phase != .checking, "A lifecycle event checked")
    }
    check("actual root uses shared shell and real children, with no local disk image inspection") {
        let root = code(try source("Sources/PatchedClient/NativeClientSession.swift"))
        for required in ["ShellView(", "AppsListView(", "SettingsView(", "supportPanel", "session.navigation",
                         "case .applications", "case .updates", "case .support", "case .settings", "AppUpdatesView(controller: session.appUpdates)"] {
            try expect(root.contains(required), "Root lacks real composition binding: \(required)")
        }
        for forbidden in [".onAppear", ".task", "Timer", "URLSession", "ArtifactInspector", "UpdateView(", "onUpdate", "Fixture", "Task {",
                          "ClientView(", "Check a local disk image", ".sheet(", "ActivityView(", "helpSelection"] {
            try expect(!root.contains(forbidden), "Root contains forbidden operation: \(forbidden)")
        }
        let navigation = compositionNavigation()
        let session = NativeClientSession(navigation: navigation)
        let applications = try compositionPaint(session)
        navigation.select(.updates)
        let updates = try compositionPaint(session)
        try expect(applications != updates, "Applications and Updates render the same child")
        navigation.select(.applications)
        try expect(try compositionPaint(session) == applications, "Returning to Applications changed retained child rendering")
    }
}
