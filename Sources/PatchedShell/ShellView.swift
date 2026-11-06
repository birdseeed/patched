import SwiftUI

/// Offscreen-capable seam only. No scene, controller, task or operational action.
/// Only the selected caller-owned content is constructed and displayed.
public struct ShellView: View {
    @Environment(\.colorScheme) private var colorScheme
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
    private var appearance: ShellAppearance { colorScheme == .dark ? .dark : .light }
    private func color(_ role: ShellColorRole) -> Color { ShellBrand.color(role, appearance: appearance) }
    private func destinationLabel(_ destination: ShellDestination) -> String {
        destinationLabels[destination] ?? navigation.label(for: destination)
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar.frame(width: geometry.size.width < 760 ? 180 : 208)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: destinationLabel(navigation.destination))
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .padding(20)
                    Divider()
                    selectedContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(color(.surface))
            }
        }
        .font(.body)
        .foregroundStyle(color(.text))
        .tint(color(.accent))
        .background(color(.surface))
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        BrandMarkView(size: 32)
                        Text(verbatim: "Patched").font(.title3.weight(.semibold))
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                    destinationGroup(navigation.mainDestinations)
                    Spacer(minLength: 24)
                    destinationGroup(navigation.lowerDestinations)
                }
                .padding(12)
                .frame(minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
        .background(color(.sidebar))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Navigation"))
    }

    private func destinationGroup(_ destinations: [ShellDestination]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(destinations, id: \.self) { destination in
                let selected = navigation.destination == destination
                Button(action: { navigation.select(destination) }) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(for: destination))
                            .frame(width: 18).accessibilityHidden(true)
                        Text(verbatim: destinationLabel(destination))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? color(.onAccent) : color(.text))
                    .padding(.horizontal, 10).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? color(.accent) : Color.clear))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: destinationLabel(destination)))
                .accessibilityIdentifier("destination:" + destination.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var selectedContent: some View {
        GeometryReader { geometry in
            // Existing children own a fixed 480pt width. Preserve them
            // unchanged and make excess width/height reachable in the shell viewport.
            let scroll = ScrollView([.horizontal, .vertical]) {
                destinationContent(navigation.destination)
                .frame(width: max(480, geometry.size.width - 32), alignment: .topLeading)
                .padding(16)
            }
            if #available(macOS 15.0, *) {
                scroll.defaultScrollAnchor(.topLeading, for: .initialOffset)
            } else {
                scroll
            }
        }
    }

    private func symbol(for destination: ShellDestination) -> String {
        switch destination {
        case .updates: return "arrow.down.circle"
        case .applications: return "square.grid.2x2"
        case .support: return "questionmark.circle"
        case .settings: return "gearshape"
        }
    }
}
