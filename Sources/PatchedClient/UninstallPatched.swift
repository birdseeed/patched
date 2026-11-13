import Foundation
import AppKit
import UpdateInstaller

/// "Uninstall Patched…": asks, switches off the login item, removes Patched's files with the shared
/// `Uninstall` core, moves the app to the Bin last, then quits. Everything outside the process is injected so
/// checks never show an alert, touch the real Library or quit anything.
@MainActor public final class UninstallFlow {
    public enum Choice: Equatable, Sendable { case keepBackups, deleteBackups, cancel }
    public enum Outcome: Equatable, Sendable { case blocked, cancelled, failed, done, busy }

    /// What the confirmation alert shows.
    public struct Prompt: Equatable, Sendable {
        public let title: String
        public let detail: String
        /// False when there are no backups, so the alert has no backup choice.
        public let hasBackups: Bool
    }

    private let roots: () throws -> Uninstall.Roots
    private let services: Uninstall.Services
    private let loginItem: any LoginItemControlling
    private let ask: @MainActor (Prompt) -> Choice
    private let tell: @MainActor (_ title: String, _ detail: String) -> Void
    private let quit: @MainActor () -> Void
    /// Shown while the files are measured and removed, which can take a while with gigabytes of backups.
    private let working: @MainActor (_ isWorking: Bool) -> Void
    /// One uninstall at a time, however many times the menu item is chosen.
    private static var inProgress = false

    public init(roots: @escaping () throws -> Uninstall.Roots, services: Uninstall.Services, loginItem: any LoginItemControlling,
                ask: @escaping @MainActor (Prompt) -> Choice, tell: @escaping @MainActor (String, String) -> Void,
                quit: @escaping @MainActor () -> Void, working: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.roots = roots; self.services = services; self.loginItem = loginItem
        self.ask = ask; self.tell = tell; self.quit = quit; self.working = working
    }

    /// The real flow for the running Patched.app.
    public static func system() -> UninstallFlow {
        let bundle: String? = runsFromAppBundle ? Bundle.main.bundlePath : nil
        return UninstallFlow(
            roots: { try Uninstall.Roots.standard(appBundle: bundle) },
            services: .system(excludingPID: ProcessInfo.processInfo.processIdentifier, deleteIfTrashFails: false),
            loginItem: SystemLoginItem(), ask: UninstallFlow.askInAlert,
            tell: { title, detail in UninstallFlow.show(title, detail) },
            quit: { NSApplication.shared.terminate(nil) },
            working: { UninstallProgressPanel.shared.show($0) })
    }

    /// Measuring and removing files runs off the main actor, so the menu bar and windows stay responsive while
    /// gigabytes of backups are sized or deleted; only the alerts, the login item and quitting use the main actor.
    @discardableResult public func run() async -> Outcome {
        guard !Self.inProgress else { return .busy }
        Self.inProgress = true
        defer { Self.inProgress = false; working(false) }
        let resolved: Uninstall.Roots
        do { resolved = try roots() }
        catch {
            tell(String(localized: "Patched could not be uninstalled"), String(localized: "Patched could not find its own folders: \(String(describing: error))"))
            return .failed
        }
        let services = self.services
        working(true)
        let first = await Task.detached { Uninstall.plan(roots: resolved, options: Uninstall.Options(), services: services) }.value
        working(false)
        if first.isBlocked {
            let reasons = first.blockers.map(\.message).joined(separator: "\n\n")
            tell(String(localized: "Patched cannot be uninstalled yet"), reasons)
            return .blocked
        }
        let choice = ask(Self.prompt(for: first))
        guard choice != .cancel else { return .cancelled }
        let options = Uninstall.Options(deleteBackups: choice == .deleteBackups, keepLogs: false, keepApp: false)
        // Login item first: only the app can unregister it. A failure is not a reason to stop.
        // If the uninstall then refuses or fails, Patched stays installed, so it is switched back on.
        let wasEnabled = loginItem.status == .enabled
        try? loginItem.unregister()
        working(true)
        let result = await Task.detached { Uninstall.execute(roots: resolved, options: options, services: services) }.value
        working(false)
        if wasEnabled && (result.refused != nil || !result.isSuccess) {
            try? loginItem.register()
        }
        if let refused = result.refused {
            tell(String(localized: "Patched cannot be uninstalled yet"), refused.blockers.map(\.message).joined(separator: "\n\n"))
            return .blocked
        }
        guard result.isSuccess else {
            tell(String(localized: "Patched could not remove everything"),
                 result.failures.joined(separator: "\n") + "\n\n" + String(localized: "Patched has been left in place. Try again, or remove the items above by hand."))
            return .failed
        }
        if let advice = result.homebrewAdvice {
            tell(String(localized: "Finish with Homebrew"), advice)
        }
        quit()
        return .done
    }

    /// The words of the confirmation alert. Pure, so checks can read them.
    nonisolated static func prompt(for plan: Uninstall.Plan) -> Prompt {
        var lines = [String(localized: "Patched will remove its settings, caches and logs, switch off its login item and the optional check schedule, then move itself to the Bin. Your other apps are not changed.")]
        if plan.backupLocations.isEmpty {
            lines.append(String(localized: "Patched has no backups of other apps."))
        } else {
            let size = Uninstall.size(plan.backupBytes), places = plan.backupLocations.joined(separator: ", ")
            lines.append(String(localized: "Backups of apps Patched has updated take up \(size) in \(places). Keep them to roll back after a reinstall, or delete them too."))
        }
        if plan.homebrewManaged {
            lines.append(String(localized: "Patched was installed with Homebrew, so the app itself stays until you run these two commands in Terminal: \(Uninstall.brewCommands[0]) then \(Uninstall.brewCommands[1])."))
        }
        return Prompt(title: String(localized: "Uninstall Patched?"), detail: lines.joined(separator: "\n\n"),
                      hasBackups: !plan.backupLocations.isEmpty)
    }

    @MainActor static func askInAlert(_ prompt: Prompt) -> Choice {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        alert.alertStyle = .warning
        if prompt.hasBackups {
            alert.addButton(withTitle: String(localized: "Keep Backups"))
            alert.addButton(withTitle: String(localized: "Delete Backups"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        } else {
            alert.addButton(withTitle: String(localized: "Uninstall"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBackups
        case .alertSecondButtonReturn: return prompt.hasBackups ? .deleteBackups : .cancel
        default: return .cancel
        }
    }

    @MainActor static func show(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}


/// A small floating "Uninstalling Patched…" panel with a spinner, shown while files are measured or removed.
@MainActor final class UninstallProgressPanel {
    static let shared = UninstallProgressPanel()
    private var panel: NSPanel?

    func show(_ visible: Bool) {
        guard visible else { panel?.orderOut(nil); panel = nil; return }
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 64), styleMask: [.titled, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = String(localized: "Uninstall Patched")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: String(localized: "Working… this can take a moment with large backups."))
        label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = 2
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        panel.contentView = stack
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
