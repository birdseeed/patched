import SwiftUI

/// The main window: a sidebar beside the selected destination. `ShellNavigation` stays the one
/// source of truth for the selection; the sidebar only reads and writes it.
/// Offscreen-capable seam only. No scene, controller, task or operational action.
/// Only the selected caller-owned content is constructed and displayed.
public struct ShellView: View {
    @ObservedObject private var navigation: ShellNavigation
    private let destinationLabels: [ShellDestination: String]
    private let destinationContent: (ShellDestination) -> AnyView
    private let openSettings: (() -> Void)?

    /// `openSettings`, when given, adds a Settings row under the lower destinations. It opens the app's
    /// standard Settings window (the same one ⌘, opens); it is never a destination and is never selected.
    public init(navigation: ShellNavigation,
                destinationLabels: [ShellDestination: String] = [:],
                openSettings: (() -> Void)? = nil,
                destinationContent: @escaping (ShellDestination) -> AnyView) {
        self.navigation = navigation
        self.destinationLabels = destinationLabels
        self.openSettings = openSettings
        self.destinationContent = destinationContent
    }
    private func destinationLabel(_ destination: ShellDestination) -> String {
        destinationLabels[destination] ?? navigation.label(for: destination)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
                .accessibilityLabel(Text("Navigation"))
        } detail: {
            destinationContent(navigation.destination)
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea(.container, edges: .top))
                .navigationTitle(destinationLabel(navigation.destination))
        }
    }

    /// The sidebar draws its own selection so it stays brand blue whatever the system accent: macOS paints a
    /// `List` selection in the system accent colour, which an app cannot override.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brandHeader
            rows(navigation.mainDestinations)
            Spacer().frame(height: 14)
            rows(navigation.lowerDestinations)
            if let openSettings {
                ShellSidebarRow(title: String(localized: "Settings"), symbol: "gearshape", isSelected: false, action: openSettings)
                    .accessibilityIdentifier("action:settings")
                    .accessibilityHint(Text("Opens the Settings window"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .onMoveCommand { direction in
            let order = navigation.mainDestinations + navigation.lowerDestinations
            guard let index = order.firstIndex(of: navigation.destination) else { return }
            switch direction {
            case .up where index > order.startIndex: navigation.select(order[index - 1])
            case .down where index < order.endIndex - 1: navigation.select(order[index + 1])
            default: break
            }
        }
    }

    /// The logo and name above the sidebar list, as many Mac apps show theirs.
    private var brandHeader: some View {
        HStack(spacing: 8) {
            BrandMarkView(size: 24)
            Text(verbatim: "Patched").font(.title3.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private func rows(_ destinations: [ShellDestination]) -> some View {
        ForEach(destinations, id: \.self) { destination in
            ShellSidebarRow(title: destinationLabel(destination), symbol: symbol(for: destination),
                            isSelected: navigation.destination == destination) {
                navigation.select(destination)
            }
            .accessibilityIdentifier("destination:" + destination.rawValue)
        }
    }

    private func symbol(for destination: ShellDestination) -> String {
        switch destination {
        case .updates: return "arrow.down.circle"
        case .available: return "plus.app"
        case .applications: return "square.grid.2x2"
        case .support: return "questionmark.circle"
        }
    }
}

/// One sidebar row: the standard Mac sidebar metrics, selected in brand blue with white content.
private struct ShellSidebarRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title).foregroundColor(isSelected ? .white : .primary)
            } icon: {
                Image(systemName: symbol).foregroundColor(isSelected ? .white : BrandAccent.color)
            }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        isSelected ? BrandAccent.color : (hovering ? Color.primary.opacity(0.06) : Color.clear)
    }
}
