import SwiftUI
import AppKit
import PatchedShell

public enum NativeClientMenuAction: CaseIterable, Sendable {
    /// `applications` is no longer in the menu; the window still reaches it. Settings is its own window,
    /// opened by the app (`NativeClientMenuView.openSettings`), not a route in the main window.
    case updates, applications
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
    /// "10:42" (or "Yesterday 10:42", or a short date and time) once a check has finished; shown as "Checked 10:42".
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
                            timeFormatter: (Date) -> String = { AppUpdatesController.shortTime($0) }) -> NativeClientMenuUpdates {
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
        let keptOffline = source.filter { $0.recheckNote != nil }.count
        let stale = source.filter { $0.status == .needsRecheck || $0.status == .pending }.count
        let checkedTime = lastCheckedAt.map(timeFormatter)
        let header: String
        var note: String?
        if phase == .checking { header = String(localized: "Checking…") }
        else if !waiting.isEmpty {
            header = NativeClientMenuLabel.badgeDescription(waiting.count)
            if failed > 0 {
                note = failed == 1 ? String(localized: "Couldn't check \(failed) app") : String(localized: "Couldn't check \(failed) apps")
            } else if keptOffline > 0 {
                note = keptOffline == 1 ? String(localized: "Couldn't re-check \(keptOffline) app (offline)")
                                        : String(localized: "Couldn't re-check \(keptOffline) apps (offline)")
            }
        }
        else if failed > 0 {
            header = failed == 1 ? String(localized: "Couldn't check \(failed) app") : String(localized: "Couldn't check \(failed) apps")
        }
        else if catalogueError != nil { header = String(localized: "Couldn't check for updates") }
        else if keptOffline > 0 { header = String(localized: "Couldn't re-check (offline)") }
        else if stale > 0 { header = String(localized: "Check again to confirm") }
        else if hasChecked { header = String(localized: "Up to date") }
        else { header = String(localized: "No update check yet") }
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

    /// "10:42" today, "Yesterday 10:42" the day before, otherwise a short date and the time. All formats come
    /// from the user's locale; `now`, `calendar` and `locale` are parameters so tests can fix them.
    nonisolated public static func shortTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                             locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale; time.calendar = calendar; time.timeZone = calendar.timeZone
        time.dateStyle = .none; time.timeStyle = .short
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            let word = RelativeDateTimeFormatter()
            word.locale = locale; word.calendar = calendar
            word.dateTimeStyle = .named; word.unitsStyle = .full
            let day = word.localizedString(from: DateComponents(day: -1))
            return day.prefix(1).uppercased() + day.dropFirst() + " " + clock
        }
        let day = DateFormatter()
        day.locale = locale; day.calendar = calendar; day.timeZone = calendar.timeZone
        day.dateStyle = .short; day.timeStyle = .short
        return day.string(from: date)
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
                ? String(localized: "Checks on open and every 3 hours. Never installs on its own.")
                : String(localized: "Background checks and notifications unavailable."))
    }

    /// Routes request the main window even when the destination is already selected.
    /// Window handling stays with the caller.
    @discardableResult public func performMenuAction(_ action: NativeClientMenuAction) -> Bool {
        switch action {
        case .updates:
            navigation.select(.updates)
        case .applications:
            navigation.select(.applications)
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

    /// A click on the menu's macOS item: open the Updates window at the macOS row. It opens nothing else; Open
    /// Software Update stays a separate click in the window.
    @discardableResult public func showMacOSUpdate() -> Bool {
        navigation.select(.updates)
        appUpdates.focus(rowID: MacOSUpdateNotice.rowID)
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
        count == 0 ? String(localized: "No updates available")
            : (count == 1 ? String(localized: "1 update available") : String(localized: "\(count) updates available"))
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

/// One item of the menu-bar menu: a disabled line of text, a command, or a separator. Pure data built from
/// the session's state; building it starts nothing.
public struct NativeClientMenuItem: Equatable, Identifiable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Open Updates focused on this app. Installs nothing.
        case showUpdate(id: String)
        /// Open Updates at the macOS row. Installs nothing and opens nothing else.
        case showMacOSUpdate
        /// Open Patched, and "and N more…": the Updates screen.
        case openUpdates
        case updateAll, stopUpdating, cancelQueuedUpdateAll
        case checkNow, settings, quit
        /// "Uninstall Patched…": asks in an alert, then removes Patched's files and the app.
        case uninstall
        /// "Update Patched to X…": asks first, in an alert, and installs only once that is confirmed.
        case updatePatched
        case downloadPatched
        case dismissPatchedFailure
    }
    public enum Kind: Equatable, Sendable { case text, command(Action), separator }

    public let id: String
    public let kind: Kind
    public let title: String
    public var enabled = true
    /// Command-key equivalent, shown in the menu.
    public var shortcut: Character?
    /// The installed app whose icon the item shows.
    public var iconPath: String?

    public var action: Action? { if case .command(let action) = kind { return action }; return nil }
}

extension NativeClientSession {
    /// Everything the menu-bar menu lists, in order.
    public var menuItems: [NativeClientMenuItem] {
        let updates = appUpdates
        let list = updates.menuUpdates()
        var items: [NativeClientMenuItem] = []
        func text(_ id: String, _ title: String) { items.append(NativeClientMenuItem(id: id, kind: .text, title: title)) }
        func command(_ id: String, _ title: String, _ action: NativeClientMenuItem.Action, enabled: Bool = true,
                     shortcut: Character? = nil, iconPath: String? = nil) {
            items.append(NativeClientMenuItem(id: id, kind: .command(action), title: title, enabled: enabled,
                                              shortcut: shortcut, iconPath: iconPath))
        }
        func separator(_ id: String) { items.append(NativeClientMenuItem(id: id, kind: .separator, title: "")) }

        text("header", list.header)
        if let checked = list.checkedAt { text("checked", String(localized: "Checked \(checked)")) }
        if let note = list.note { text("note", note) }
        if let available = list.selfUpdateText, let own = updates.selfUpdate {
            let state = updates.selfInstall
            separator("self-separator")
            text("self", available)
            if updates.canInstallSelfUpdate { command("self-update", String(localized: "Update Patched to \(own.version)…"), .updatePatched) }
            command("self-download", String(localized: "Download Patched \(own.version)"), .downloadPatched, enabled: !state.isBusy)
            // The question itself is asked in an alert; progress and failures are shown here.
            if let status = state.text, !state.isConfirming { text("self-status", status) }
            if state.isFailed { command("self-dismiss", String(localized: "Dismiss"), .dismissPatchedFailure) }
        }
        let all = updates.updateAllMenu
        let macOS = updates.macOSNotice
        if !list.rows.isEmpty || all.visible || macOS != nil { separator("updates-separator") }
        // Listed like an update, first, but it never counts towards Update All.
        if let macOS { command("row:" + MacOSUpdateNotice.rowID, macOS.menuTitle, .showMacOSUpdate) }
        for row in list.rows {
            command("row:" + row.id, row.name + "  " + row.versions + (row.note.map { " — " + $0 } ?? ""),
                    .showUpdate(id: row.id), iconPath: row.path)
        }
        if list.moreCount > 0 { command("more", String(localized: "and \(list.moreCount) more…"), .openUpdates) }
        if all.visible {
            if let progress = all.progressText { text("update-all-progress", progress) }
            if all.showsCancelQueued {
                command("update-all-cancel", String(localized: "Cancel"), .cancelQueuedUpdateAll)
            } else if all.showsStop {
                command("update-all-stop", String(localized: "Stop Updating"), .stopUpdating, enabled: all.stopEnabled)
            } else {
                command("update-all", all.title, .updateAll, enabled: all.enabled)
                if let detail = all.detail { text("update-all-detail", detail) }
                if let reason = all.reason { text("update-all-reason", reason) }
            }
        }
        separator("actions-separator")
        command("open", String(localized: "Open Patched"), .openUpdates)
        command("check", String(localized: "Check Now"), .checkNow, enabled: updates.canCheck, shortcut: "r")
        command("settings", String(localized: "Settings…"), .settings, shortcut: ",")
        command("uninstall", String(localized: "Uninstall Patched…"), .uninstall, enabled: runsFromAppBundle)
        separator("quit-separator")
        command("quit", String(localized: "Quit Patched"), .quit, shortcut: "q")
        text("background", menuText.backgroundStatus)
        return items
    }

    /// "Update Patched to X…" in the menu: asks with `confirm` (an alert in the app) and installs only when the
    /// answer is yes; any other answer cancels. Returns whether the update was confirmed.
    @discardableResult public func requestSelfUpdateFromMenu(confirm: (String) -> Bool) -> Bool {
        appUpdates.requestSelfUpdate()
        guard appUpdates.selfInstall.isConfirming, let question = appUpdates.selfInstall.text else { return false }
        guard confirm(question) else { appUpdates.cancelSelfUpdate(); return false }
        appUpdates.confirmSelfUpdate()
        return true
    }
}

/// The menu-bar menu's items, shown as a native menu (`.menuBarExtraStyle(.menu)`): text lines become
/// disabled items, buttons become commands and dividers become separators.
/// Presentation observes the retained child directly: session observation alone
/// does not forward its update owner's publications.
public struct NativeClientMenuView: View {
    @ObservedObject private var session: NativeClientSession
    @ObservedObject private var updates: AppUpdatesController
    private let openWindow: () -> Void
    private let openSettings: () -> Void
    private let confirmSelfUpdate: @MainActor (String) -> Bool
    private let startUninstall: @MainActor () -> Void

    /// `openSettings` shows the standard Settings window; the app supplies it from its scene environment.
    /// `confirmSelfUpdate` asks before Patched updates itself; by default an alert whose default button is Cancel.
    public init(session: NativeClientSession, openWindow: @escaping () -> Void, openSettings: @escaping () -> Void = {},
                confirmSelfUpdate: @escaping @MainActor (String) -> Bool = NativeClientMenuView.askInAlert,
                startUninstall: @escaping @MainActor () -> Void = { Task { await UninstallFlow.system().run() } }) {
        self.session = session
        self.updates = session.appUpdates
        self.openWindow = openWindow
        self.openSettings = openSettings
        self.confirmSelfUpdate = confirmSelfUpdate
        self.startUninstall = startUninstall
    }

    public var body: some View {
        ForEach(session.menuItems) { item in
            switch item.kind {
            case .separator:
                Divider()
            case .text:
                Text(verbatim: item.title)
            case .command(let action):
                Button(action: { perform(action) }) { label(item) }
                    .disabled(!item.enabled)
                    .keyboardShortcut(item.shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
            }
        }
    }

    @ViewBuilder private func label(_ item: NativeClientMenuItem) -> some View {
        if let path = item.iconPath {
            Label { Text(verbatim: item.title) } icon: { Image(nsImage: menuIcon(path)) }
        } else {
            Text(verbatim: item.title)
        }
    }

    /// The app's icon at menu size: the provider's cached icon, else the inventory's own pixels, else a plain
    /// app symbol. Memory only, so opening the menu reads no files.
    private func menuIcon(_ path: String) -> NSImage {
        let source: NSImage?
        if let cached = updates.iconProvider.cachedIcon(forPath: path) {
            source = cached
        } else if let pixels = updates.row(id: path)?.icon?.cgImage {
            source = NSImage(cgImage: pixels, size: NSSize(width: 32, height: 32))
        } else {
            source = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }
        let icon = (source?.copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// One menu command. Only explicit choices reach here; nothing installs without its own confirmation.
    public func perform(_ action: NativeClientMenuItem.Action) {
        switch action {
        case .showUpdate(let id): if session.showUpdate(id: id) { openWindow() }
        case .showMacOSUpdate: if session.showMacOSUpdate() { openWindow() }
        case .openUpdates: if session.performMenuAction(.updates) { openWindow() }
        case .updateAll: session.updateAllEntry.requestUpdateAll()
        case .stopUpdating, .cancelQueuedUpdateAll: session.updateAllEntry.requestStop()
        case .checkNow: session.performMenuAction(.checkNow)
        case .settings: openSettings()
        case .quit: NSApplication.shared.terminate(nil)
        case .uninstall: startUninstall()
        case .updatePatched: session.requestSelfUpdateFromMenu(confirm: confirmSelfUpdate)
        case .downloadPatched: updates.downloadSelfUpdate()
        case .dismissPatchedFailure: updates.cancelSelfUpdate()
        }
    }

    /// "Update Patched to X?" with "Patched will quit and reopen." below. Cancel is the default button, so
    /// Return never installs; only a click on Update and Reopen does.
    @MainActor public static func askInAlert(_ question: String) -> Bool {
        let alert = NSAlert()
        if let mark = question.range(of: "? ") {
            alert.messageText = String(question[..<mark.lowerBound]) + "?"
            alert.informativeText = String(question[mark.upperBound...])
        } else {
            alert.messageText = question
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Update and Reopen"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Update All's one question about the apps it skipped because they were open. True only for "Quit and Update".
    @MainActor public static func askToQuitOpenApps(_ question: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Apps are open")
        alert.informativeText = question
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit and Update"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// "Patched 0.2.0 is available" with a Download button, which opens the release page on a click only. For a
/// release with a signed zip, in an installed Patched.app, there is also Update: it asks "Update Patched to X?
/// Patched will quit and reopen." and installs only once that is confirmed. Progress and failures show below.
struct SelfUpdateLine: View {
    let text: String
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
            HStack(spacing: 8) { label; Spacer(minLength: 8); buttons }
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
                        Button(action: cancel) { Text("Cancel") }
                            .buttonStyle(.bordered)
                        Button(action: confirm) { Text("Update and Reopen") }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel(Text("Update Patched to \(version) and reopen it"))
                    }
                } else if state.isFailed {
                    HStack { Spacer(minLength: 0)
                        Button(action: cancel) { Text("Dismiss") }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(BrandAccent.color).accessibilityHidden(true)
            Text(verbatim: text).font(.body).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder private var buttons: some View {
        if showsUpdate {
            Button(action: update) { Text("Update") }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Text("Update to Patched \(version)"))
        }
        Button(action: download) { Text("Download") }
            .buttonStyle(.bordered)
            .disabled(state.isBusy)
            .accessibilityLabel(Text("Download Patched \(version)"))
    }
}

extension AppUpdatesController {
    /// The self-update line for this controller's current state.
    func selfUpdateLine(_ own: SelfUpdate) -> SelfUpdateLine {
        SelfUpdateLine(text: own.text, state: selfInstall, canInstall: canInstallSelfUpdate,
                       download: { [weak self] in self?.downloadSelfUpdate() },
                       update: { [weak self] in self?.requestSelfUpdate() },
                       confirm: { [weak self] in self?.confirmSelfUpdate() },
                       cancel: { [weak self] in self?.cancelSelfUpdate() })
    }
}
