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
    check("sidebar: native split view whose list selection is ShellNavigation, titled by the selected destination") {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PatchedShell/ShellView.swift").path
        let shell = try String(contentsOfFile: path, encoding: .utf8)
        for required in ["NavigationSplitView", "List(selection: selection)", ".listStyle(.sidebar)", "Label(",
                         "navigation.select(destination)", "get: { navigation.destination }",
                         ".navigationTitle(", ".accessibilityIdentifier(\"destination:\" + destination.rawValue)"] {
            try expect(shell.contains(required), "Shell sidebar is not the native list: missing \(required)")
        }
        for custom in ["ScrollView([.horizontal, .vertical])", "GeometryReader", "RoundedRectangle", ".buttonStyle(.plain)"] {
            try expect(!shell.contains(custom), "Shell still hand-builds its sidebar or viewport: \(custom)")
        }
    }
}
