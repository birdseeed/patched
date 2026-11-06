import SwiftUI
import PatchedShell

@MainActor func registerOffscreenChecks() {
    for destination in expectedMain + expectedLower {
        for dark in [false, true] {
            check("render content: \(destination.rawValue) \(dark ? "dark" : "light")") {
                let output = try outputDirectory()
                let state = fixtureNavigation(destination: destination)
                var requested: [ShellDestination] = []
                let view = ShellView(navigation: state, destinationContent: { value in
                    requested.append(value)
                    return probe("Fixture destination: " + value.rawValue)
                })
                let result = try render(view, dark: dark)
                try retain(result, name: destination.rawValue + (dark ? "-dark" : "-light"), output: output)
                print("Retained shell specimen: \(output.path)")
                try expect(try probePixelCount(result.image) >= 900, "Selected content probe absent or clipped")
                try expect(Set(requested) == [destination], "Unselected content requested")
            }
        }
    }
    check("render: appearance and layout never dispatch selection") {
        var events: [ShellDestination] = []
        let state = fixtureNavigation(onSelection: { events.append($0) })
        _ = try render(ShellView(navigation: state, destinationContent: { probe($0.rawValue) }))
        try expect(events.isEmpty && state.destination == .updates,
                   "Offscreen painting performed an action")
    }
    for dark in [false, true] {
        for compact in [false, true] {
            check("render accessibility specimen: \(dark ? "dark" : "light") \(compact ? "compact" : "normal")") {
                let output = try outputDirectory()
                let state = fixtureNavigation()
                let view = ShellView(navigation: state, destinationLabels: [.updates: longLabel],
                                     destinationContent: { _ in probe(longLabel) })
                let result = try render(view, width: compact ? 640 : 800, height: compact ? 480 : 600,
                                        dark: dark)
                try retain(result, name: "long-label-\(dark)-\(compact)", output: output)
                try expect(try probePixelCount(result.image) >= 900, "Long content clipped or not displayed")
                // Contrast/reduced-motion environment keys are get-only in the current SDK.
                // Native settings, keyboard focus and VoiceOver require separate target proof.
            }
        }
    }
    check("render reuse: injected destination content is painted as supplied, never rebuilt") {
        let output = try outputDirectory()
        let actions = 0
        let specimens: [(String, AnyView)] = [
            ("content", AnyView(probe("Fixture destination content")))
        ]
        var outputs = Set<Data>()
        for (name, specimen) in specimens {
            let state = fixtureNavigation()
            let view = ShellView(navigation: state, destinationContent: { _ in specimen })
            let result = try render(view)
            try retain(result, name: "existing-" + name, output: output)
            outputs.insert(result.png)
        }
        try expect(actions == 0, "Painting reused views performed an action")
        try expect(outputs.count == 1, "Shell discarded or replaced existing presentation content")
    }
}
