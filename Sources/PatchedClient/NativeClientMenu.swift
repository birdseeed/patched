import SwiftUI
import AppKit
import PatchedShell

// Select the property-wrapper type explicitly when an SDK also declares a State macro.
private typealias MenuHoverState<Value> = State<Value>

public enum NativeClientMenuAction: CaseIterable, Sendable {
    /// `applications` is no longer in the menu; the window still reaches it.
    case updates, applications, settings
    /// The menu's Check Now: a read-only update check. It never opens the window.
    case checkNow
}

/// What the menu shows of the update state: one status line, then a short list of the apps waiting.
/// Pure words over the controller's rows; building it starts nothing.
public struct NativeClientMenuUpdates: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        /// "1.0 → 2.0"
        public let versions: String
        /// "App Store" or "Needs admin"; nil for an ordinary update.
        public let note: String?
        /// The installed app's path, for its icon.
        public var path: String { id }
    }
    public static let rowCap = 8
    public let header: String
    /// "10:42" when a check has finished; shown beside the header as "Checked 10:42".
    public let checkedAt: String?
    /// A second line when some apps could not be checked but updates are still listed.
    public let note: String?
    public let rows: [Row]
    /// Updates beyond the cap; the menu shows "and N more…" and opens Updates.
    public let moreCount: Int
    /// "Patched 0.2.0 is available" when a newer Patched release was announced; the menu adds a Download button,
    /// and an Update button when the release can be installed (`selfUpdateInstallable`).
    public var selfUpdateText: String? = nil
    public var selfUpdateInstallable = false
}

extension AppUpdatesController {
    /// Ordinary updates first, then those that need admin, then App Store ones; each group by name.
    public func menuUpdates(cap: Int = NativeClientMenuUpdates.rowCap,
                            timeFormatter: (Date) -> String = AppUpdatesController.shortTime) -> NativeClientMenuUpdates {
        let source = displayedRows
        func group(_ row: AppUpdateRow) -> Int {
            if row.isAppStoreUpdate { return 3 }
            if row.status == .packageUnsupported || row.status == .notInstallable { return 2 }
            return row.kindNote != nil ? 1 : 0
        }
        // Every update on offer is listed, including ones Patched cannot install itself.
        let waiting = source.filter {
            $0.status == .updateAvailable || $0.status == .appStoreUpdate || $0.status == .packageUnsupported || $0.status == .notInstallable
        }
        let ordered = waiting.enumerated().sorted {
            let (a, b) = (group($0.element), group($1.element))
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        // "Up to date" only when every checked app is confirmed so (or has no source to check).
        let failed = source.filter { if case .refused = $0.status { return true }; return false }.count
        let stale = source.filter { $0.status == .needsRecheck || $0.status == .pending }.count
        let checkedTime = lastCheckedAt.map(timeFormatter)
        let header: String
        var note: String?
        if phase == .checking { header = "Checking…" }
        else if !waiting.isEmpty {
            header = NativeClientMenuLabel.badgeDescription(waiting.count)
            if failed > 0 { note = "Couldn't check \(failed) \(failed == 1 ? "app" : "apps")" }
        }
        else if failed > 0 { header = "Couldn't check \(failed) \(failed == 1 ? "app" : "apps")" }
        else if catalogueError != nil { header = "Couldn't check for updates" }
        else if stale > 0 { header = "Check again to confirm" }
        else if hasChecked { header = "Up to date" }
        else { header = "No update check yet" }
        let shown = ordered.prefix(max(0, cap)).map {
            NativeClientMenuUpdates.Row(id: $0.id, name: $0.name, versions: Self.menuVersions($0), note: $0.kindNote)
        }
        return NativeClientMenuUpdates(header: header, checkedAt: checkedTime, note: note, rows: Array(shown),
                                       moreCount: max(0, ordered.count - shown.count), selfUpdateText: selfUpdate?.text,
                                       selfUpdateInstallable: canInstallSelfUpdate)
    }

    /// Display versions only, from the row's structured fields: "139.0 → 139.0.6053.38" rather than
    /// "139.0 (139.0.6053.22) → 139.0.6053.38". Offered versions are shown exactly as published.
    nonisolated static func menuVersions(_ row: AppUpdateRow) -> String {
        let installed = row.installedDisplayVersion ?? row.installedVersion
        guard let latest = row.latestVersion, latest != installed, latest != row.installedVersion else { return installed }
        return installed + " → " + latest
    }

    nonisolated public static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

public enum NativeClientMenuWindow {
    public static let id = "patched-main"
}

public enum NativeClientLifecyclePolicy {
    /// Keep the user session's menu available after its last window closes.
    /// This does not schedule work or change explicit Quit behaviour.
    public static let continuesSessionAfterLastWindowCloses = true
}

public struct NativeClientMenuText: Equatable, Sendable {
    public let backgroundStatus: String
}

extension NativeClientSession {
    public var menuText: NativeClientMenuText {
        NativeClientMenuText(backgroundStatus: backgroundChecksRunning
                ? "Checks on open and every 3 hours. Never installs on its own."
                : "Background checks and notifications unavailable.")
    }

    /// Routes request the main window even when the destination is already selected.
    /// Window handling stays with the caller.
    @discardableResult public func performMenuAction(_ action: NativeClientMenuAction) -> Bool {
        switch action {
        case .updates:
            navigation.select(.updates)
        case .applications:
            navigation.select(.applications)
        case .settings:
            navigation.select(.settings)
        case .checkNow:
            appUpdates.check()
            return false
        }
        return true
    }

    /// A click on one of the menu's update rows: open the Updates window focused on that app.
    /// It starts no check and installs nothing; Update stays a separate click in the window.
    @discardableResult public func showUpdate(id: String) -> Bool {
        navigation.select(.updates)
        appUpdates.focus(rowID: id)
        return true
    }
}

/// Uses the same canonical mark as the shell, in the menu bar's native colour.
public struct NativeClientMenuLabel: View {
    private let updates: AppUpdatesController?
    public init() { updates = nil }
    /// The same mark with a count of waiting updates beside it.
    public init(updates: AppUpdatesController) { self.updates = updates }

    public static func badgeDescription(_ count: Int) -> String {
        count == 0 ? "No updates available" : (count == 1 ? "1 update available" : "\(count) updates available")
    }

    /// Eager, bounded canonical pixels; template tint comes from the menu bar.
    @MainActor public static var image: NSImage? {
        let renderer = ImageRenderer(content: ShellBrandMark()
            .fill(.black).frame(width: 18, height: 18))
        renderer.scale = 2
        guard let pixels = renderer.cgImage else { return nil }
        let representation = NSBitmapImageRep(cgImage: pixels)
        representation.size = NSSize(width: 18, height: 18)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        image.isTemplate = true
        return image
    }

    public var body: some View {
        Group {
            if let updates {
                NativeClientMenuBadgedLabel(updates: updates)
            } else if let image = Self.image {
                Image(nsImage: image)
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityLabel(Text(verbatim: "Patched"))
    }
}

/// The mark plus the number of apps with an update waiting; nothing extra when there are none.
struct NativeClientMenuBadgedLabel: View {
    @ObservedObject var updates: AppUpdatesController
    var body: some View {
        HStack(spacing: 3) {
            if let image = NativeClientMenuLabel.image {
                Image(nsImage: image).frame(width: 18, height: 18)
            }
            if updates.availableUpdateCount > 0 {
                Text(verbatim: String(updates.availableUpdateCount)).monospacedDigit()
            }
        }
        .accessibilityValue(Text(verbatim: NativeClientMenuLabel.badgeDescription(updates.availableUpdateCount)))
    }
}

/// Presentation observes the retained child directly: session observation alone
/// does not forward its update owner's publications.
public struct NativeClientMenuView: View {
    @ObservedObject private var session: NativeClientSession
    @ObservedObject private var updates: AppUpdatesController
    private let openWindow: () -> Void

    public init(session: NativeClientSession, openWindow: @escaping () -> Void) {
        self.session = session
        self.updates = session.appUpdates
        self.openWindow = openWindow
    }

    public var body: some View {
        let list = updates.menuUpdates()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: list.header).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                if let checked = list.checkedAt {
                    Text(verbatim: "Checked " + checked).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            if let note = list.note {
                Text(verbatim: note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if list.selfUpdateText != nil, let own = updates.selfUpdate {
                updates.selfUpdateLine(own, compact: true)
                    .padding(.horizontal, 8)
            }
            if !list.rows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list.rows) { row in
                        MenuHoverButton(action: { if session.showUpdate(id: row.id) { openWindow() } }) {
                            HStack(spacing: 8) {
                                AppIconView(path: row.path, fallback: nil, provider: updates.iconProvider, size: 20, revision: row.versions)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: row.name).lineLimit(1).truncationMode(.tail)
                                    Text(verbatim: row.versions).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.tail)
                                }
                                Spacer(minLength: 4)
                                if let note = row.note {
                                    Text(verbatim: note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                        .fixedSize()
                                }
                            }
                        }
                        .accessibilityLabel(Text(verbatim: row.name + ", " + row.versions + (row.note.map { ", " + $0 } ?? "")))
                        .accessibilityHint(Text(verbatim: "Shows this app in Updates"))
                    }
                    if list.moreCount > 0 {
                        MenuHoverButton(action: { route(.updates) }) {
                            Text(verbatim: "and \(list.moreCount) more…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            updateAllSection
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 0) {
                MenuHoverButton(action: { route(.updates) }) {
                    MenuItemLabel(title: "Open Patched", symbol: "macwindow")
                }
                MenuHoverButton(action: { session.performMenuAction(.checkNow) }) {
                    MenuItemLabel(title: "Check Now", symbol: "arrow.clockwise", shortcut: "⌘R")
                }
                .disabled(!updates.canCheck)
                .keyboardShortcut("r", modifiers: .command)
                MenuHoverButton(action: { route(.settings) }) {
                    MenuItemLabel(title: "Settings…", symbol: "gear", shortcut: "⌘,")
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider().padding(.vertical, 4)
                MenuHoverButton(action: { NSApplication.shared.terminate(nil) }) {
                    MenuItemLabel(title: "Quit Patched", symbol: "power", shortcut: "⌘Q")
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            Text(verbatim: session.menuText.backgroundStatus)
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.top, 2)
        }
        .font(.body)
        .tint(ShellBrand.accent)
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder private var updateAllSection: some View {
        let state = updates.updateAllMenu
        if state.visible {
            VStack(spacing: 6) {
                if let progress = state.progressText {
                    Text(verbatim: progress).font(.caption).foregroundStyle(.secondary)
                }
                if state.showsCancelQueued {
                    Button(action: { session.updateAllEntry.requestStop() }) {
                        Text(verbatim: "Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                } else if state.showsStop {
                    Button(action: { session.updateAllEntry.requestStop() }) {
                        Text(verbatim: "Stop Updating").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!state.stopEnabled)
                } else {
                    Button(action: { session.updateAllEntry.requestUpdateAll() }) {
                        Text(verbatim: state.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(ShellBrand.accent)
                    .disabled(!state.enabled)
                    if let detail = state.detail {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = state.reason {
                        Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
        }
    }

    private func route(_ action: NativeClientMenuAction) {
        if session.performMenuAction(action) { openWindow() }
    }
}

/// A full-width plain button that highlights under the pointer, like a native menu item.
struct MenuHoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @MenuHoverState private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && enabled ? Color.primary.opacity(0.1) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Icon, label and an optional right-aligned shortcut, as in a native menu.
struct MenuItemLabel: View {
    let title: String
    let symbol: String
    var shortcut: String?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 20).accessibilityHidden(true)
            Text(verbatim: title)
            Spacer(minLength: 8)
            if let shortcut { Text(verbatim: shortcut).foregroundStyle(.secondary).accessibilityHidden(true) }
        }
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.6))
    }
}

/// "Patched 0.2.0 is available" with a Download button, which opens the release page on a click only. For a
/// release with a signed zip, in an installed Patched.app, there is also Update: it asks "Update Patched to X?
/// Patched will quit and reopen." and installs only once that is confirmed. Progress and failures show below.
struct SelfUpdateLine: View {
    let text: String
    var compact = false
    var state: SelfInstallState = .idle
    var canInstall = false
    let download: () -> Void
    var update: () -> Void = {}
    var confirm: () -> Void = {}
    var cancel: () -> Void = {}

    private var version: String { text.replacingOccurrences(of: "Patched ", with: "").replacingOccurrences(of: " is available", with: "") }
    private var showsUpdate: Bool { canInstall && !state.isConfirming && !state.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact && showsUpdate {
                HStack(spacing: 8) { label; Spacer(minLength: 0) }
                HStack(spacing: 8) { Spacer(minLength: 0); buttons }
            } else {
                HStack(spacing: 8) { label; Spacer(minLength: 8); buttons }
            }
            if let status = state.text {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if state.isBusy { ProgressView().controlSize(.small) }
                    Text(verbatim: status).font(.caption)
                        .foregroundStyle(state.isFailed ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if state.isConfirming {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(action: cancel) { Text(verbatim: "Cancel") }
                            .buttonStyle(ClientButtonStyle(enabled: true, prominent: false))
                        Button(action: confirm) { Text(verbatim: "Update and Reopen") }
                            .buttonStyle(ClientButtonStyle(enabled: true, prominent: true))
                            .accessibilityLabel(Text(verbatim: "Update Patched to \(version) and reopen it"))
                    }
                } else if state.isFailed {
                    HStack { Spacer(minLength: 0)
                        Button(action: cancel) { Text(verbatim: "Dismiss") }
                            .buttonStyle(ClientButtonStyle(enabled: true, prominent: false))
                    }
                }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(ShellBrand.accent).accessibilityHidden(true)
            Text(verbatim: text).font(compact ? .callout : .body).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder private var buttons: some View {
        if showsUpdate {
            Button(action: update) { Text(verbatim: "Update") }
                .buttonStyle(ClientButtonStyle(enabled: true, prominent: true))
                .accessibilityLabel(Text(verbatim: "Update to Patched " + version))
        }
        Button(action: download) { Text(verbatim: "Download") }
            .buttonStyle(ClientButtonStyle(enabled: !state.isBusy, prominent: false))
            .disabled(state.isBusy)
            .accessibilityLabel(Text(verbatim: "Download " + text.replacingOccurrences(of: " is available", with: "")))
    }
}

extension AppUpdatesController {
    /// The self-update line for this controller's current state.
    func selfUpdateLine(_ own: SelfUpdate, compact: Bool = false) -> SelfUpdateLine {
        SelfUpdateLine(text: own.text, compact: compact, state: selfInstall, canInstall: canInstallSelfUpdate,
                       download: { [weak self] in self?.downloadSelfUpdate() },
                       update: { [weak self] in self?.requestSelfUpdate() },
                       confirm: { [weak self] in self?.confirmSelfUpdate() },
                       cancel: { [weak self] in self?.cancelSelfUpdate() })
    }
}
