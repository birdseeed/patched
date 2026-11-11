import SwiftUI

/// The main window: a native sidebar list beside the selected destination. `ShellNavigation` stays the one
/// source of truth for the selection; the list only reads and writes it.
/// Offscreen-capable seam only. No scene, controller, task or operational action.
/// Only the selected caller-owned content is constructed and displayed.
public struct ShellView: View {
    @ObservedObject private var navigation: ShellNavigation
    private let destinationLabels: [ShellDestination: String]
    private let destinationContent: (ShellDestination) -> AnyView

    public init(navigation: ShellNavigation,
                destinationLabels: [ShellDestination: String] = [:],
                destinationContent: @escaping (ShellDestination) -> AnyView) {
        self.navigation = navigation
        self.destinationLabels = destinationLabels
        self.destinationContent = destinationContent
    }
    private func destinationLabel(_ destination: ShellDestination) -> String {
        destinationLabels[destination] ?? navigation.label(for: destination)
    }

    /// The list's selection, read from and written to `ShellNavigation`. Deselecting is ignored, so a
    /// destination is always shown.
    private var selection: Binding<ShellDestination?> {
        Binding(get: { navigation.destination },
                set: { if let destination = $0 { navigation.select(destination) } })
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section { rows(navigation.mainDestinations) }
                Section { rows(navigation.lowerDestinations) }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) { brandHeader }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
            .accessibilityLabel(Text("Navigation"))
        } detail: {
            destinationContent(navigation.destination)
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(destinationLabel(navigation.destination))
        }
    }

    /// The logo and name above the sidebar list, as many Mac apps show theirs.
    private var brandHeader: some View {
        HStack(spacing: 8) {
            BrandMarkView(size: 24)
            Text(verbatim: "Patched").font(.title3.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private func rows(_ destinations: [ShellDestination]) -> some View {
        ForEach(destinations, id: \.self) { destination in
            Label(destinationLabel(destination), systemImage: symbol(for: destination))
                .tag(destination)
                .accessibilityIdentifier("destination:" + destination.rawValue)
        }
    }

    private func symbol(for destination: ShellDestination) -> String {
        switch destination {
        case .updates: return "arrow.down.circle"
        case .applications: return "square.grid.2x2"
        case .support: return "questionmark.circle"
        }
    }
}
