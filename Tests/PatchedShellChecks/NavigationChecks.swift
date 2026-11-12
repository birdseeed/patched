import Foundation
import SwiftUI
import PatchedShell

@MainActor func registerNavigationChecks() {
    check("navigation: approved primary and lower groups have exact order") {
        let state = fixtureNavigation()
        try expect(state.mainDestinations == expectedMain, "Primary destination group/order missing")
        try expect(state.lowerDestinations == expectedLower, "Lower destination group/order missing")
    }
    for (destination, label) in destinationLabels {
        check("navigation label: \(destination.rawValue)") {
            try expect(fixtureNavigation().label(for: destination) == label, "Approved literal destination label missing")
        }
    }
    check("navigation: Available is absent without a catalogue and present, between Updates and Applications, with one") {
        let state = fixtureNavigation()
        try expect(!state.availableShown && state.mainDestinations == expectedMain && state.mainDestinations.count == 2,
                   "Available is listed with no catalogue: \(state.mainDestinations)")
        try expect(state.focusOrder == ["destination:updates", "destination:applications", "destination:support"], "focus order changed")
        state.setAvailableShown(true)
        try expect(state.mainDestinations == [.updates, .available, .applications] && state.lowerDestinations == expectedLower,
                   "Available missing or misplaced: \(state.mainDestinations)")
        try expect(state.label(for: .available) == "Available", "Available label")
        state.setAvailableShown(false)
        try expect(state.mainDestinations == expectedMain, "Available not removed again")
    }
    check("navigation: Available cannot be selected while hidden, and hiding it returns to Updates") {
        var events: [ShellDestination] = []
        let state = fixtureNavigation(onSelection: { events.append($0) })
        try expect(!state.select(.available) && !state.selectRaw("available") && state.destination == .updates && events.isEmpty,
                   "Hidden Available was selectable")
        state.setAvailableShown(true)
        try expect(state.select(.available) && state.destination == .available, "Shown Available refused")
        state.setAvailableShown(false)
        try expect(state.destination == .updates && events == [.available, .updates], "Hiding Available left it selected: \(events)")
    }
    check("navigation: a new navigation never starts on a hidden Available") {
        let state = fixtureNavigation(destination: .available)
        try expect(state.destination == .updates && !state.availableShown, "started on hidden Available")
    }
    check("navigation: construction is inert and keeps explicitly supplied selection") {
        var events: [ShellDestination] = []
        let state = fixtureNavigation(destination: .support, onSelection: { events.append($0) })
        try expect(events.isEmpty && state.destination == .support,
                   "Constructing display state triggered a callback or changed selection")
    }
    for destination in expectedMain + expectedLower where destination != .updates {
        check("navigation transition: explicit \(destination.rawValue) once") {
            var events: [ShellDestination] = []
            let state = fixtureNavigation(onSelection: { events.append($0) })
            try expect(state.select(destination), "Explicit destination selection refused")
            try expect(state.destination == destination && events == [destination], "Wrong destination or callback delivery")
            try expect(!state.select(destination) && events == [destination], "Duplicate selection dispatched again")
        }
    }
    check("input: exact valid raw selections accepted") {
        let state = fixtureNavigation()
        try expect(state.selectRaw("support") && state.destination == .support, "Valid destination raw input refused")
    }
    check("input: unknown and nonexact values leave state and callbacks unchanged") {
        var events: [ShellDestination] = []
        let state = fixtureNavigation(onSelection: { events.append($0) })
        for invalid in ["", "unknown", "settings", "Settings", " support", "activity", "network\n", "<script>"] {
            try expect(!state.selectRaw(invalid), "Invalid destination accepted")
        }
        try expect(state.destination == .updates && events.isEmpty, "Invalid input mutated state or callbacks")
    }
    check("focus declaration: ordered destinations, the same on every destination; Settings is its own window") {
        let expected = ["destination:updates", "destination:applications", "destination:support"]
        try expect(fixtureNavigation().focusOrder == expected && fixtureNavigation(destination: .support).focusOrder == expected,
                   "Declared destination traversal missing")
    }
    check("brand mark: approved open P geometry occupies the master grid") {
        let path = ShellBrandMark().path(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        try expect(!path.isEmpty, "Geometric P is absent")
        let bounds = path.boundingRect
        try expect(abs(bounds.minX - 2) < 0.1 && abs(bounds.minY - 2) < 0.1 && abs(bounds.maxX - 62) < 0.1,
                   "Canonical circle bounds changed")
        try expect(path.contains(CGPoint(x: 32, y: 5), eoFill: true), "Coverage disk missing")
        try expect(!path.contains(CGPoint(x: 32, y: 32), eoFill: true), "Open centre filled")
        try expect(!path.contains(CGPoint(x: 19, y: 52), eoFill: true), "Negative-space stem closed")
        try expect(path.contains(CGPoint(x: 48, y: 48), eoFill: true), "Lower bowl missing")
    }
}

@MainActor func registerNativeSidebarChecks() {
    check("sidebar: split view whose selection is drawn in the brand accent, driven by ShellNavigation, titled by the selected destination") {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PatchedShell/ShellView.swift").path
        let shell = try String(contentsOfFile: path, encoding: .utf8)
        for required in ["NavigationSplitView", "Label {", "BrandAccent.color", "Color.primary.opacity(0.06)", "cornerRadius: 6",
                         ".buttonStyle(.plain)", ".focusable()", ".onMoveCommand", "navigation.select(destination)",
                         "navigation.select(order[index - 1])", "navigation.select(order[index + 1])",
                         "navigation.destination == destination", ".accessibilityAddTraits(isSelected ? .isSelected : [])",
                         "Color(nsColor: .textBackgroundColor)", ".navigationTitle(",
                         ".accessibilityIdentifier(\"destination:\" + destination.rawValue)"] {
            try expect(shell.contains(required), "Shell sidebar is missing \(required)")
        }
        for system in ["List(selection", ".listStyle(", "GeometryReader"] {
            try expect(!shell.contains(system), "Shell sidebar uses the system-accent selection or hand-builds layout: \(system)")
        }
    }
    check("render sidebar: the brand-blue selection sits on the selected row only") {
        var centres: [ShellDestination: Double] = [:]
        for destination in [ShellDestination.updates, .applications, .support] {
            let state = fixtureNavigation(destination: destination)
            let result = try render(ShellView(navigation: state, destinationContent: { probe($0.rawValue) }))
            let (count, centreY) = try brandBluePixels(result.image, maxX: 190)
            try expect(count > 1500, "No brand-blue selected row for \(destination.rawValue) (\(count) px)")
            centres[destination] = centreY
        }
        let u = centres[.updates] ?? 0, a = centres[.applications] ?? 0, h = centres[.support] ?? 0
        try expect(u < a && a < h && a - u > 10, "Selection did not move with the destination: \(u) \(a) \(h)")
    }
}

@MainActor func registerAvailableSidebarChecks() {
    check("render sidebar: with a catalogue the Available row is listed and selectable, without one the sidebar is unchanged") {
        var centres: [ShellDestination: Double] = [:]
        for destination in [ShellDestination.updates, .available, .applications, .support] {
            let state = fixtureNavigation(destination: .updates)
            state.setAvailableShown(true)
            state.select(destination)
            let result = try render(ShellView(navigation: state, destinationContent: { probe($0.rawValue) }))
            let (count, centreY) = try brandBluePixels(result.image, maxX: 190)
            try expect(count > 1500, "No brand-blue selected row for \(destination.rawValue) (\(count) px)")
            centres[destination] = centreY
        }
        let u = centres[.updates] ?? 0, v = centres[.available] ?? 0, a = centres[.applications] ?? 0, h = centres[.support] ?? 0
        try expect(u < v && v < a && a < h && v - u > 10 && a - v > 10, "Available is not between Updates and Applications: \(u) \(v) \(a) \(h)")
        // Without a catalogue: Applications sits exactly where it did before Available existed (one row below Updates).
        let plain = fixtureNavigation(destination: .applications)
        let base = try brandBluePixels(try render(ShellView(navigation: plain, destinationContent: { probe($0.rawValue) })).image, maxX: 190).1
        try expect(abs(base - v) < 2, "Without a catalogue, Applications is not directly below Updates: \(base) vs Available \(v)")
    }
}

@MainActor func registerSidebarSettingsChecks() {
    check("sidebar Settings row: shown only with an opener, never a destination, wired to the standard Settings window") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/PatchedShell/ShellView.swift"), encoding: .utf8)
        for required in ["if let openSettings {", "symbol: \"gearshape\", isSelected: false, action: openSettings",
                         ".accessibilityIdentifier(\"action:settings\")"] {
            try expect(shell.contains(required), "Shell sidebar Settings row is missing \(required)")
        }
        let session = try String(contentsOf: root.appendingPathComponent("Sources/PatchedClient/NativeClientSession.swift"), encoding: .utf8)
        try expect(session.contains("OpensSettings { openSettings in") && session.contains("ShellView(navigation: session.navigation, openSettings: openSettings,"),
                   "The app's sidebar is not given the Settings opener")
        let opener = try String(contentsOf: root.appendingPathComponent("Sources/PatchedClient/OpensSettings.swift"), encoding: .utf8)
        try expect(opener.contains("@Environment(\\.openSettings)") && opener.contains("Selector((\"showPreferencesWindow:\"))"),
                   "Settings opener does not use openSettings (macOS 14) and showPreferencesWindow: (macOS 13)")
    }
    check("render sidebar: the Settings row is drawn, but never as a selected row") {
        let without = try render(ShellView(navigation: fixtureNavigation(destination: .updates),
            destinationContent: { probe($0.rawValue) }))
        let with = try render(ShellView(navigation: fixtureNavigation(destination: .updates), openSettings: {},
            destinationContent: { probe($0.rawValue) }))
        try expect(with.png != without.png, "Giving an opener drew no Settings row")
        let added = try brandBluePixels(with.image, maxX: 190).0 - brandBluePixels(without.image, maxX: 190).0
        try expect(added < 1000, "Settings row added \(added) brand-blue px: drawn as selected")
    }
}
