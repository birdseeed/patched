import SwiftUI

public enum ShellDestination: String, CaseIterable, Hashable, Sendable {
    case updates, applications, support, settings
}

/// Main-actor display selection only. Callbacks convey no operational authority.
@MainActor public final class ShellNavigation: ObservableObject {
    @Published public private(set) var destination: ShellDestination
    private let onSelection: (ShellDestination) -> Void

    public init(destination: ShellDestination, onSelection: @escaping (ShellDestination) -> Void = { _ in }) {
        self.destination = destination
        self.onSelection = onSelection
    }
    public var mainDestinations: [ShellDestination] { [.updates, .applications] }
    public var lowerDestinations: [ShellDestination] { [.support, .settings] }
    /// Declared traversal, not evidence of native focus or VoiceOver routing.
    public var focusOrder: [String] {
        (mainDestinations + lowerDestinations).map { "destination:" + $0.rawValue }
    }
    public func label(for destination: ShellDestination) -> String {
        switch destination {
        case .updates: return "Updates"
        case .applications: return "Applications"
        case .support: return "Help & Support"
        case .settings: return "Settings"
        }
    }
    @discardableResult public func select(_ destination: ShellDestination) -> Bool {
        guard self.destination != destination else { return false }
        self.destination = destination
        onSelection(destination)
        return true
    }
    @discardableResult public func selectRaw(_ value: String) -> Bool {
        guard let destination = ShellDestination(rawValue: value) else { return false }
        return select(destination)
    }
}
