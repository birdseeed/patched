import AppKit
import SwiftUI
import PatchedShell
import PatchedClient

@MainActor private final class ReopenProbe {
    var calls = 0
    func opened() { calls += 1 }
}

@MainActor private func menuImage() throws -> NSImage {
    guard let image = NativeClientMenuLabel.image else {
        throw CheckFailure(description: "Production menu label has no eager canonical template image")
    }
    return image
}

@MainActor func registerNativeMenuReopenChecks() {
    check("reopen: unconfigured handler preserves framework fallback without work") {
        let route = NativeClientReopenCoordinator()
        try expect(route.handleReopen(hasVisibleWindows: false), "Unconfigured handler swallowed framework fallback")
        try expect(route.handleReopen(hasVisibleWindows: true), "Visible-window fallback was swallowed")
    }
    check("reopen: missing-window event reaches the retained opener exactly once per event") {
        let route = NativeClientReopenCoordinator()
        weak var retained: ReopenProbe?
        do {
            let probe = ReopenProbe(); retained = probe
            route.register(opener: { probe.opened() })
        }
        try expect(retained != nil, "Opener was not retained after its registering view disappeared")
        for count in 1...3 {
            try expect(!route.handleReopen(hasVisibleWindows: false), "Handled reopen permits duplicate framework creation")
            try expect(retained?.calls == count, "Real reopen handler dropped or duplicated the callback")
        }
    }
    check("reopen: visible-window event never requests another scene") {
        let route = NativeClientReopenCoordinator(); var calls = 0
        route.register(opener: { calls += 1 })
        for _ in 0..<3 {
            try expect(route.handleReopen(hasVisibleWindows: true), "Visible-window event disabled normal framework handling")
        }
        try expect(calls == 0, "Visible-window reopen created a duplicate scene")
    }
    check("reopen: repeated registration replaces callback and leaves shared session inert") {
        let route = NativeClientReopenCoordinator(), session = NativeClientSession()
        let updates = session.appUpdates, navigation = session.navigation
        navigation.select(.settings)
        let destination = navigation.destination
        var oldCalls = 0, latestCalls = 0
        weak var released: ReopenProbe?
        do {
            let probe = ReopenProbe(); released = probe
            route.register(opener: { probe.opened(); oldCalls += 1 })
        }
        route.register(opener: { latestCalls += 1 })
        try expect(released == nil, "Replaced opener retained a disappearing view's capture")
        try expect(oldCalls == 0 && latestCalls == 0, "Registering an opener performed work")
        _ = route.handleReopen(hasVisibleWindows: false)
        try expect(oldCalls == 0 && latestCalls == 1, "Registration stacked or discarded callbacks")
        try expect(session.appUpdates === updates && session.navigation === navigation,
                   "Reopen replaced a shared owner")
        try expect(navigation.destination == destination, "Reopen changed navigation")
        try expect(!updates.hasChecked && updates.phase != .checking, "Reopen started a check")
    }
    check("menu image: eager template has bounded native and pixel dimensions") {
        let image = try menuImage()
        try expect(image.isTemplate && image.size == NSSize(width: 18, height: 18), "Menu image lacks native template sizing")
        try expect(!image.representations.isEmpty, "Image has only a deferred drawing closure")
        try expect(image.representations.allSatisfy { $0.pixelsWide >= 18 && $0.pixelsWide <= 72
            && $0.pixelsHigh == $0.pixelsWide }, "Menu image representation is unbounded or malformed")
    }
    check("menu image: actual alpha matches canonical mark including transparent negative space") {
        let image = try menuImage()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CheckFailure(description: "Menu image has no eager pixels")
        }
        try expect(cg.width >= 18 && cg.width <= 72 && cg.height == cg.width, "Unbounded image raster")
        let pixels = NSBitmapImageRep(cgImage: cg)
        let path = ShellBrandMark().path(in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        var definite = 0, direct = 0, flipped = 0, covered = 0, empty = 0
        for y in 0..<cg.height { for x in 0..<cg.width {
            guard let color = pixels.colorAt(x: x, y: y) else { throw CheckFailure(description: "Missing raster sample") }
            let alpha = color.alphaComponent
            guard let rgb = color.usingColorSpace(.deviceRGB) else { throw CheckFailure(description: "Unconvertible image colour") }
            try expect(abs(rgb.redComponent - rgb.greenComponent) < 0.02
                && abs(rgb.greenComponent - rgb.blueComponent) < 0.02, "Menu image contains non-monochrome pixels")
            if alpha > 0.5 { covered += 1 } else { empty += 1 }
            // Exclude antialiasing boundary pixels by independently sampling four subpixel corners.
            let samples = [0.2, 0.8].flatMap { dx in [0.2, 0.8].map { dy in
                path.contains(CGPoint(x: Double(x) + dx, y: Double(y) + dy))
            }}
            guard samples.allSatisfy({ $0 == samples[0] }) else { continue }
            definite += 1
            if (alpha > 0.5) == samples[0] { direct += 1 }
            if (alpha > 0.5) == path.contains(CGPoint(x: Double(x) + 0.5, y: Double(cg.height - y) - 0.5)) { flipped += 1 }
        }}
        try expect(covered > cg.width && empty > cg.width, "Blank or solid menu raster lost canonical negative space")
        try expect(definite > cg.width && Double(max(direct, flipped)) / Double(definite) > 0.94,
                   "Actual alpha does not depict the canonical ShellBrandMark")
    }
    check("menu image: actual label paints offscreen without activation") {
        let app = NSApplication.shared
        if app.activationPolicy() != .prohibited { _ = app.setActivationPolicy(.prohibited) }
        try expect(app.activationPolicy() == .prohibited && !app.isActive, "Label capture must stay inactive")
        let host = NSHostingView(rootView: NativeClientMenuLabel().frame(width: 24, height: 24))
        host.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CheckFailure(description: "Label paint unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try expect(bitmap.pixelsWide >= 24 && bitmap.pixelsHigh >= 24, "Label paint was empty")
        try expect(!window.isVisible && !app.isActive && app.activationPolicy() == .prohibited, "Label paint activated UI")
    }
    check("integration: multi-scene insertion and delegate call actual tested seams") {
        let app = code(try source("Sources/PatchedApp/PatchedApp.swift"))
        try expect(app.contains("private typealias MenuInsertionState<Value> = SwiftUI.State<Value>")
            && app.contains("@MenuInsertionState private var menuInserted = true")
            && app.contains("MenuBarExtra(isInserted: $menuInserted"),
                   "Multiple scene app lacks mutable, initially inserted menu state")
        for binding in ["NativeClientReopenCoordinator", "applicationShouldHandleReopen", ".handleReopen(hasVisibleWindows:", ".register(opener:"] {
            try expect(app.contains(binding), "Native delegate/app does not bind tested route: \(binding)")
        }
        let menu = code(try source("Sources/PatchedClient/NativeClientMenu.swift"))
        try expect(menu.contains("Image(nsImage:") && menu.contains("Self.image") && menu.contains("accessibilityLabel(Text(verbatim: \"Patched\"))"),
                   "Actual accessible menu label does not consume the tested image")
        let route = code(try source("Sources/PatchedClient/NativeClientReopenCoordinator.swift"))
        try expect(!(route + menu).contains("NativeClientSession("), "Lifecycle/image constructs a competing session")
        try expect(app.components(separatedBy: "NativeClientSession(").count == 2
            && app.contains("@StateObject private var session = NativeClientSession()"),
                   "App must retain exactly its one baseline shared session")
        for forbidden in ["NSApp.windows", "URLSession", "contentsOf:", "contentsOfFile:", "Process(", "Timer", "LocalApplicationsController("] {
            try expect(!(route + menu + app).contains(forbidden), "Lifecycle/image adds IO, window search or competing owner: \(forbidden)")
        }
    }
}
