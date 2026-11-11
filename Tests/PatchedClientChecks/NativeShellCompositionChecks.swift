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
    check("chrome follows the user's system accent: no custom tint or brand palette in any view") {
        var files: [(String, String)] = []
        for directory in ["Sources/PatchedShell", "Sources/PatchedClient", "Sources/PatchedApp"] {
            files += try swiftSources(directory).map { (directory + "/" + $0.0, code($0.1)) }
        }
        for (name, text) in files {
            // The one app accent lives in ShellBrand.swift; nothing else tints.
            if name == "Sources/PatchedShell/ShellBrand.swift" { continue }
            for forbidden in [".tint(", "ShellBrand.", "ShellColorRole", "ShellAppearance", "NSColor(srgbRed"] {
                try expect(!text.contains(forbidden), "\(name) overrides system colours with \(forbidden)")
            }
            // Only the brand mark itself (the logo, not chrome) may carry fixed colours.
            if name != "Sources/PatchedShell/ShellBrand.swift" {
                try expect(!text.contains("Color(.sRGB"), "\(name) paints chrome with a fixed colour")
            }
        }
    }
    check("brand: blue accent on every window whatever the system accent; logo above the sidebar") {
        let accent = NSColor(BrandAccent.color).usingColorSpace(.sRGB)
        try expect(accent.map { abs($0.blueComponent - 0xEB / 255.0) < 0.01 && abs($0.redComponent - 0x25 / 255.0) < 0.01 } ?? false,
                   "The app accent is not brand blue")
        let app = code(try source("Sources/PatchedApp/PatchedApp.swift"))
        try expect(app.components(separatedBy: ".brandAccent()").count == 3, "Main and Settings windows do not both carry the app accent")
        let shell = code(try source("Sources/PatchedShell/ShellView.swift"))
        try expect(shell.contains("VStack(alignment: .leading, spacing: 2) {\n            brandHeader") && shell.contains("BrandMarkView(size: 24)"),
                   "The sidebar lost its logo")
    }
    check("interface copy is localisable from the main bundle; only names and data stay verbatim") {
        var files: [(String, String)] = []
        for directory in ["Sources/PatchedShell", "Sources/PatchedClient", "Sources/PatchedApp"] {
            files += try swiftSources(directory).map { (directory + "/" + $0.0, code($0.1)) }
        }
        let verbatimLiteral = try NSRegularExpression(pattern: #"Text\(verbatim: "([^"]*)""#)
        for (name, text) in files {
            for match in verbatimLiteral.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = String(text[Range(match.range(at: 1), in: text)!])
                try expect(literal == "Patched", "\(name) shows fixed copy verbatim, so it cannot be localised: \(literal)")
            }
            // A hand-assembled .app has no SwiftPM resource bundle beside it; Bundle.module would look in the wrong place.
            try expect(!text.contains("Bundle.module"), "\(name) looks up text in Bundle.module")
        }
        try expect(!code(try source("Package.swift")).contains("resources:"), "Package.swift declares SwiftPM resources")
    }
    check("row status and result text in AppUpdatesController is built with String(localized:), not bare literals") {
        let text = code(try source("Sources/PatchedClient/AppUpdatesController.swift"))
        let literalResult = try NSRegularExpression(pattern: #"\btext:\s*""#)
        try expect(literalResult.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil,
                   "AppUpdatesController passes a bare string literal as result text; use String(localized:)")
        guard let start = text.range(of: "public var statusText: String {"),
              let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex) else {
            throw CheckFailure(description: "AppUpdateRow.statusText not found")
        }
        let body = String(text[start.upperBound..<end.lowerBound])
        let bareReturn = try NSRegularExpression(pattern: #"return\s*""#)
        try expect(bareReturn.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) == nil,
                   "AppUpdateRow.statusText returns a bare string literal; use String(localized:)")
    }
    check("actual root uses shared shell and real children, with no local disk image inspection") {
        let root = code(try source("Sources/PatchedClient/NativeClientSession.swift"))
        for required in ["ShellView(", "AppsListView(", "supportPanel", "session.navigation",
                         "case .applications", "case .updates", "case .support", "AppUpdatesView(controller: session.appUpdates)"] {
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
