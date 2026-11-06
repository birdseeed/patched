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
        try expect(state.selectRaw("settings") && state.destination == .settings, "Valid destination raw input refused")
    }
    check("input: unknown and nonexact values leave state and callbacks unchanged") {
        var events: [ShellDestination] = []
        let state = fixtureNavigation(onSelection: { events.append($0) })
        for invalid in ["", "unknown", "Settings", " settings", "activity", "network\n", "<script>"] {
            try expect(!state.selectRaw(invalid), "Invalid destination accepted")
        }
        try expect(state.destination == .updates && events.isEmpty, "Invalid input mutated state or callbacks")
    }
    check("focus declaration: ordered destinations, the same inside Settings") {
        let expected = ["destination:updates", "destination:applications", "destination:support", "destination:settings"]
        try expect(fixtureNavigation().focusOrder == expected && fixtureNavigation(destination: .settings).focusOrder == expected,
                   "Declared destination traversal missing")
    }
    for (role, light, dark) in expectedPalette {
        check("brand palette: \(role) exact light/dark values") {
            try expect(ShellBrand.hex(role, appearance: .light) == light, "Canonical light token missing")
            try expect(ShellBrand.hex(role, appearance: .dark) == dark, "Canonical dark token missing")
        }
    }
    check("brand contrast: canonical body/accent pairings meet text contrast") {
        func luminance(_ hex: String) throws -> Double {
            guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else {
                throw Failure(description: "Missing or invalid semantic colour")
            }
            let channels = [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)].map { value -> Double in
                let normalized = value / 255
                return normalized <= 0.04045 ? normalized / 12.92 : pow((normalized + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        for appearance in ShellAppearance.allCases {
            for (foreground, background) in [(ShellColorRole.text, ShellColorRole.surface), (.muted, .surface), (.onAccent, .accent)] {
                guard let front = ShellBrand.hex(foreground, appearance: appearance), let back = ShellBrand.hex(background, appearance: appearance) else {
                    throw Failure(description: "Semantic palette not implemented")
                }
                let a = try luminance(front), b = try luminance(back)
                try expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5, "Text pairing below 4.5:1")
            }
        }
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
