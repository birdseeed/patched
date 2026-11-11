import AppKit

/// Patched is a menu-bar app (`LSUIElement`): normally it has no Dock icon and no app menu. While one of its
/// windows (main, setup or Settings) is open it becomes a regular app, so the Dock icon, the app menu,
/// Command-Tab and Command-comma behave as people expect, and it goes back to the menu bar only when the
/// last of those windows closes. A minimised window still counts as open, so it can be restored from the Dock.
/// Display state only: it starts no check and performs no action.
@MainActor public final class NativeClientWindowPresence {
    public typealias PolicySetter = @MainActor (NSApplication.ActivationPolicy) -> Void
    public typealias OpenTest = @MainActor (NSWindow) -> Bool

    private final class Tracked {
        weak var window: NSWindow?
        var observers: [NSObjectProtocol] = []
        init(_ window: NSWindow) { self.window = window }
        // Dropped once its window is gone; take its observers with it so they do not pile up.
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    private let setPolicy: PolicySetter
    private let isOpen: OpenTest
    private let isHidden: @MainActor () -> Bool
    private var tracked: [Tracked] = []
    /// The policy last applied; nil until the first window is tracked.
    public private(set) var policy: NSApplication.ActivationPolicy?

    /// The app's own: switches the real activation policy, and activates when a window makes it regular,
    /// because the app menu only appears once a regular app is active.
    public convenience init() {
        self.init(setPolicy: { policy in
            _ = NSApplication.shared.setActivationPolicy(policy)
            if policy == .regular { NSApplication.shared.activate(ignoringOtherApps: true) }
        })
    }

    public init(setPolicy: @escaping PolicySetter,
                isOpen: @escaping OpenTest = { $0.isVisible || $0.isMiniaturized },
                isHidden: @escaping @MainActor () -> Bool = { NSApplication.shared.isHidden }) {
        self.setPolicy = setPolicy
        self.isOpen = isOpen
        self.isHidden = isHidden
    }

    /// Follows one of Patched's windows. Tracking the same window again only re-evaluates.
    public func track(_ window: NSWindow) {
        tracked.removeAll { $0.window == nil }
        if !tracked.contains(where: { $0.window === window }) {
            let entry = Tracked(window)
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                entry.observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            entry.observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.refresh(closing: window) }
            })
            tracked.append(entry)
        }
        refresh()
    }

    /// Regular while any tracked window other than `closing` is open, accessory otherwise.
    public func refresh(closing: NSWindow? = nil) {
        tracked.removeAll { $0.window == nil }
        // Hide (⌘H) orders every window out, so none looks open; keep the Dock icon so the app can be unhidden.
        // A window closed while hidden is still caught by its willClose.
        if isHidden() && closing == nil { return }
        let open = tracked.contains { entry in
            guard let window = entry.window, window !== closing else { return false }
            return isOpen(window)
        }
        apply(open ? .regular : .accessory)
    }

    private func apply(_ next: NSApplication.ActivationPolicy) {
        guard next != policy else { return }
        policy = next
        setPolicy(next)
    }
}
