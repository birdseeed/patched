import SwiftUI

public enum ShellDestination: String, CaseIterable, Hashable, Sendable {
    case updates, available, applications, support
}

/// Main-actor display selection only. Callbacks convey no operational authority.
@MainActor public final class ShellNavigation: ObservableObject {
    @Published public private(set) var destination: ShellDestination
    /// Whether the Available (Self Service) destination is listed. Display only: the owner sets it from whether an
    /// organisation catalogue is managed on this Mac; with none, the sidebar is exactly Updates and Applications.
    @Published public private(set) var availableShown = false
    private let onSelection: (ShellDestination) -> Void

    public init(destination: ShellDestination, onSelection: @escaping (ShellDestination) -> Void = { _ in }) {
        // Available is listed only once the owner says so, so a new navigation never starts on it.
        self.destination = destination == .available ? .updates : destination
        self.onSelection = onSelection
    }
    public var mainDestinations: [ShellDestination] {
        availableShown ? [.updates, .available, .applications] : [.updates, .applications]
    }
    /// Lists or hides Available. Hiding it while it is selected returns to Updates.
    public func setAvailableShown(_ shown: Bool) {
        guard availableShown != shown else { return }
        availableShown = shown
        if !shown && destination == .available { select(.updates) }
    }
    public var lowerDestinations: [ShellDestination] { [.support] }
    /// Declared traversal, not evidence of native focus or VoiceOver routing.
    public var focusOrder: [String] {
        (mainDestinations + lowerDestinations).map { "destination:" + $0.rawValue }
    }
    public func label(for destination: ShellDestination) -> String {
        switch destination {
        case .updates: return String(localized: "Updates")
        case .available: return String(localized: "Available")
        case .applications: return String(localized: "Applications")
        case .support: return String(localized: "Help & Support")
        }
    }
    @discardableResult public func select(_ destination: ShellDestination) -> Bool {
        guard self.destination != destination else { return false }
        // Available exists only while it is listed; a stray route cannot reach it otherwise.
        guard destination != .available || availableShown else { return false }
        self.destination = destination
        onSelection(destination)
        return true
    }
    @discardableResult public func selectRaw(_ value: String) -> Bool {
        guard let destination = ShellDestination(rawValue: value) else { return false }
        return select(destination)
    }
}
