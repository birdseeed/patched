import AppKit
import SwiftUI

/// Hands its content an action that opens the app's standard Settings window (the one ⌘, opens),
/// so views outside the app menu, such as the sidebar's Settings row, can open it too.
public struct OpensSettings<Content: View>: View {
    private let content: (@escaping () -> Void) -> Content

    public init(@ViewBuilder content: @escaping (@escaping () -> Void) -> Content) {
        self.content = content
    }

    public var body: some View {
        if #available(macOS 14.0, *) {
            OpensSettingsModern(content: content)
        } else {
            content(openSettingsLegacy)
        }
    }
}

@available(macOS 14.0, *)
private struct OpensSettingsModern<Content: View>: View {
    let content: (@escaping () -> Void) -> Content
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        content {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}

/// macOS 13 has no openSettings action. Its Settings scene answers showPreferencesWindow:
/// (showSettingsWindow: only exists from macOS 14), so send whichever the app responds to.
/// The menu bar's Settings… in PatchedApp.swift does the same.
@MainActor func openSettingsLegacy() {
    NSApp.activate(ignoringOtherApps: true)
    let settings = Selector(("showSettingsWindow:")), preferences = Selector(("showPreferencesWindow:"))
    if !NSApp.sendAction(settings, to: nil, from: nil) {
        NSApp.sendAction(preferences, to: nil, from: nil)
    }
}
