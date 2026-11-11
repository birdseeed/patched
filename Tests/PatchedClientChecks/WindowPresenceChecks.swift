import Foundation
import AppKit
import PatchedClient

// Windows here are never ordered on screen: "open" is decided by the test, and window notifications are posted
// by hand, so no real activation policy changes.
@MainActor private final class PresenceProbe {
    var policies: [NSApplication.ActivationPolicy] = []
    var open: Set<ObjectIdentifier> = []
    var hidden = false
    lazy var presence = NativeClientWindowPresence(setPolicy: { [unowned self] in self.policies.append($0) },
                                                   isOpen: { [unowned self] in self.open.contains(ObjectIdentifier($0)) },
                                                   isHidden: { [unowned self] in self.hidden })
    func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
    func show(_ window: NSWindow) {
        open.insert(ObjectIdentifier(window))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }
    func close(_ window: NSWindow) {
        // willClose arrives while the window is still visible; the presence must not count it.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        open.remove(ObjectIdentifier(window))
    }
}

@MainActor func registerWindowPresenceChecks() {
    check("window presence: constructing it changes nothing") {
        let probe = PresenceProbe()
        _ = probe.presence
        try expect(probe.policies.isEmpty && probe.presence.policy == nil, "Construction changed the activation policy")
    }
    check("window presence: regular while a Patched window is open, menu-bar only after the last one closes") {
        let probe = PresenceProbe()
        let main = probe.window(), settings = probe.window()
        probe.presence.track(main)
        try expect(probe.policies == [.accessory], "A tracked but unshown window made the app regular: \(probe.policies.map(\.rawValue))")
        probe.show(main)
        try expect(probe.policies == [.accessory, .regular], "Opening the main window did not show the Dock icon and app menu: \(probe.policies.map(\.rawValue))")
        probe.presence.track(settings); probe.show(settings)
        try expect(probe.policies == [.accessory, .regular], "A second window re-applied the policy: \(probe.policies.map(\.rawValue))")
        probe.close(main)
        try expect(probe.policies == [.accessory, .regular], "Closing one of two windows hid the app: \(probe.policies.map(\.rawValue))")
        probe.close(settings)
        try expect(probe.policies == [.accessory, .regular, .accessory], "Closing the last window kept the Dock icon: \(probe.policies.map(\.rawValue))")
        // Settings is reused by SwiftUI: showing it again makes the app regular again.
        probe.show(settings)
        try expect(probe.policies == [.accessory, .regular, .accessory, .regular], "Reopened Settings stayed menu-bar only: \(probe.policies.map(\.rawValue))")
        probe.presence.track(settings)
        try expect(probe.policies.count == 4, "Tracking a window twice re-applied the policy")
    }
    check("window presence: hiding the app (⌘H) keeps the Dock icon; closing while hidden still drops it") {
        let probe = PresenceProbe()
        let main = probe.window()
        probe.presence.track(main); probe.show(main)
        // Hide orders the window out, then AppKit reports an occlusion change.
        probe.hidden = true
        probe.open.remove(ObjectIdentifier(main))
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: main)
        try expect(probe.policies == [.accessory, .regular], "Hiding the app dropped the Dock icon: \(probe.policies.map(\.rawValue))")
        probe.close(main)
        try expect(probe.policies == [.accessory, .regular, .accessory], "Closing the last window while hidden kept the Dock icon: \(probe.policies.map(\.rawValue))")
    }
    check("launch: the delegate starts background checks after launching, not only the menu-bar label's task") {
        let app = code(try source("Sources/PatchedApp/PatchedApp.swift"))
        for binding in ["func applicationDidFinishLaunching(", "appDelegate.attach(session,", "session.startBackgroundChecks(showMainWindow: showMainWindow)"] {
            try expect(app.contains(binding), "Launch does not start background checks: \(binding)")
        }
    }
    check("settings on macOS 13: falls back to showPreferencesWindow:") {
        let app = code(try source("Sources/PatchedApp/PatchedApp.swift"))
        try expect(app.contains("Selector((\"showPreferencesWindow:\"))"), "No macOS 13 Settings selector")
    }
    check("window presence: the app adopts it for the main and Settings windows, as a menu-bar app") {
        let app = code(try source("Sources/PatchedApp/PatchedApp.swift"))
        for binding in ["NativeClientWindowPresence()", "windowPresence.track(", "PatchedWindowPresenceMarker(presence: appDelegate.windowPresence)"] {
            try expect(app.contains(binding), "App does not track its windows: \(binding)")
        }
        try expect(app.components(separatedBy: "PatchedWindowPresenceMarker(presence:").count == 3, "Main and Settings windows are not both tracked")
        let plist = try source("packaging/Info.plist.template")
        try expect(plist.contains("<key>LSUIElement</key><true/>"), "Patched is not a menu-bar (LSUIElement) app")
    }
    check("commands: no File > New Window; an Updates menu with Check Now (⌘R) and Update All, enabled like the window's buttons") {
        let app = code(try source("Sources/PatchedApp/PatchedApp.swift"))
        for binding in ["CommandGroup(replacing: .newItem) {}", "CommandMenu(\"Updates\")", "NativeClientUpdatesCommands(session: session)"] {
            try expect(app.contains(binding), "App commands lack \(binding)")
        }
        let view = code(try source("Sources/PatchedClient/AppUpdatesView.swift"))
        guard let start = view.range(of: "public struct NativeClientUpdatesCommands") else { throw CheckFailure(description: "No Updates commands") }
        let commands = String(view[start.lowerBound...])
        let window = String(view[..<start.lowerBound])
        for binding in ["Button(\"Check Now\") { controller.check() }", ".keyboardShortcut(\"r\", modifiers: .command)", ".disabled(!controller.canCheck)",
                        "Button(\"Update All\") { controller.updateAll() }", ".disabled(!controller.canUpdateAll)"] {
            try expect(commands.contains(binding), "Updates commands lack \(binding)")
        }
        // The window's buttons use the same rules, and ⌘R now belongs to the menu command only.
        try expect(window.contains("enabled: controller.canUpdateAll, prominent: false) { controller.updateAll() }")
                   && window.contains("enabled: controller.canCheck, prominent: true) { controller.check() }"), "Window buttons changed rules")
        try expect(!window.contains(".keyboardShortcut(\"r\""), "⌘R is bound twice")
    }
}
