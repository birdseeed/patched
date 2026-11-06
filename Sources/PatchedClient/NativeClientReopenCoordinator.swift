import AppKit

/// Retains the current main-window route without performing work at registration.
@MainActor public final class NativeClientReopenCoordinator {
    private var opener: (@MainActor () -> Void)?

    public init() {}

    private var pendingOpen = false

    public func register(opener: @escaping @MainActor () -> Void) {
        self.opener = opener
        if pendingOpen { pendingOpen = false; opener() }
    }

    /// Opens the main window now, or as soon as a window route is registered.
    public func open() {
        if let opener { opener() } else { pendingOpen = true }
    }

    public func handleReopen(hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let opener else { return true }
        opener()
        return false
    }
}
