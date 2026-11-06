import SwiftUI
import AppKit
import PatchedShell

private typealias AppsListState<Value> = State<Value>

/// Reveals an installed app in Finder. The only thing the Applications list can do to an app.
@MainActor @_spi(Testing) public protocol FileRevealing: AnyObject {
    func reveal(path: String)
}

@MainActor final class WorkspaceFileRevealer: FileRevealing {
    func reveal(path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}

/// The segmented filter above the list.
@_spi(Testing) public enum AppsListFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", updates = "Updates", upToDate = "Up to date", noSource = "No source"
    public var id: String { rawValue }

    func matches(_ row: AppUpdateRow) -> Bool {
        switch self {
        case .all: return true
        case .updates: return row.hasUpdateToShow
        case .upToDate: return row.status == .upToDate
        case .noSource: return row.status == .noSource
        }
    }
}

extension AppUpdateRow {
    /// An update exists, whoever installs it (Patched, the App Store, or nobody yet).
    var hasUpdateToShow: Bool {
        switch status {
        case .updateAvailable, .notInstallable, .packageUnsupported, .appStoreUpdate: return true
        default: return false
        }
    }

    /// The badge text, or nil when the app has no source. "?" marks a low-confidence match.
    @_spi(Testing) public var sourceBadge: String? {
        let unconfirmed = source.hasSuffix("?")
        let kind = unconfirmed ? String(source.dropLast()) : source
        let name: String
        switch kind {
        case "sparkle": name = "Sparkle"
        case "electron": name = "Electron"
        case "homebrew": name = "Homebrew"
        case "App Store", "appstore": return "App Store"
        default: return nil
        }
        return unconfirmed ? name + " (unconfirmed)" : name
    }

    /// The status on the right of the list: short, with the target version for an update.
    @_spi(Testing) public var listStatus: String {
        if hasUpdateToShow, let latest = latestVersion { return "Update to " + latest }
        return statusText      // Patched's own row reads "Update to X" through this when a release was announced
    }
}

/// What the list shows for a search and a segment. Pure, so it can be checked without a view.
@_spi(Testing) public enum AppsListModel {
    public static func visibleRows(_ rows: [AppUpdateRow], query: String, filter: AppsListFilter) -> [AppUpdateRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows
            .filter { filter.matches($0) }
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.bundleID?.localizedCaseInsensitiveContains(needle) ?? false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Whether a path is safe to reveal: a real directory named `*.app`, not a symlink, with no symlinked parent.
@_spi(Testing) public enum AppRevealCheck {
    public static func isRevealable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".app") else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
    }
}

/// The two row actions. Neither installs, quits or opens an app.
@MainActor @_spi(Testing) public struct AppsListActions {
    let revealer: FileRevealing
    let showUpdate: (String) -> Void
    let currentRows: @MainActor () -> [AppUpdateRow]
    public init(revealer: FileRevealing, showUpdate: @escaping (String) -> Void,
                currentRows: @escaping @MainActor () -> [AppUpdateRow]) {
        self.revealer = revealer; self.showUpdate = showUpdate; self.currentRows = currentRows
    }
    /// Reveals only a row that is still listed and whose path is still a real app folder. False otherwise.
    @discardableResult public func showInFinder(_ row: AppUpdateRow) -> Bool {
        guard currentRows().contains(where: { $0.id == row.id }), AppRevealCheck.isRevealable(row.path) else { return false }
        revealer.reveal(path: row.path)
        return true
    }
    public func showInUpdates(_ row: AppUpdateRow) { if row.hasUpdateToShow { showUpdate(row.id) } }
}

/// The Applications screen: every installed app from the Updates controller's last check, read-only.
public struct AppsListView: View {
    @ObservedObject private var controller: AppUpdatesController
    private let actions: AppsListActions
    @AppsListState private var query = ""
    @AppsListState private var filter = AppsListFilter.all
    @AppsListState private var revealNotice: String?

    public init(controller: AppUpdatesController, showUpdate: @escaping (String) -> Void) {
        self.controller = controller
        self.actions = AppsListActions(revealer: WorkspaceFileRevealer(), showUpdate: showUpdate, currentRows: { controller.rows })
    }

    @_spi(Testing) public init(controller: AppUpdatesController, revealer: FileRevealing, showUpdate: @escaping (String) -> Void) {
        self.controller = controller
        self.actions = AppsListActions(revealer: revealer, showUpdate: showUpdate, currentRows: { controller.rows })
    }

    private var visible: [AppUpdateRow] { AppsListModel.visibleRows(controller.rows, query: query, filter: filter) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = controller.catalogueError {
                CatalogueErrorBanner(message: error, retryEnabled: !controller.isWorking && controller.phase == .idle) {
                    Task { await controller.refreshInstallerState() }
                }
            }
            if let failure = controller.ignoreEditFailure {
                IgnoreEditFailureBanner(message: failure) { controller.dismissIgnoreEditFailure() }
            }
            if let notice = revealNotice {
                Text(verbatim: notice).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                TextField("Search by name or bundle ID", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("Show", selection: $filter) {
                    ForEach(AppsListFilter.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
            }
            Divider()
            if visible.isEmpty { emptyState } else { list }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: subtitle).font(.body).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if controller.phase == .checking { ProgressView().controlSize(.small) }
            let canCheck = Self.checkNowEnabled(controller)
            Button(action: { controller.check() }) { Text(verbatim: "Check Now") }
                .buttonStyle(ClientButtonStyle(enabled: canCheck, prominent: !controller.hasChecked))
                .disabled(!canCheck)
        }
        .frame(minHeight: 28)
    }

    @_spi(Testing) public static func checkNowEnabled(_ controller: AppUpdatesController) -> Bool {
        controller.canCheck && controller.phase == .idle && !controller.isWorking
    }

    private var subtitle: String {
        if controller.phase == .checking { return "Checking…" }
        guard controller.hasChecked else { return "Not checked yet" }
        let count = controller.rows.count
        let noun = count == 1 ? "1 app" : "\(count) apps"
        guard let at = controller.lastCheckedAt else { return noun }
        return noun + " · checked " + at.formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 6) {
            Text(verbatim: emptyTitle).font(.headline)
            Text(verbatim: emptyDetail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private var emptyTitle: String {
        if controller.rows.isEmpty { return controller.hasChecked ? "No applications found" : "No apps to show yet" }
        return "No matching apps"
    }

    private var emptyDetail: String {
        if controller.rows.isEmpty {
            return controller.phase == .checking ? "Patched is looking through your applications."
                : (controller.hasChecked ? "Nothing was found in the application folders." : "Choose Check Now to list your applications.")
        }
        return "Try a different search or filter."
    }

    private func reveal(_ row: AppUpdateRow) {
        revealNotice = actions.showInFinder(row) ? nil : "Couldn't find \(row.name). Check again."
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { row in
                    AppsListRowView(row: row, controller: controller, actions: actions, reveal: reveal)
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AppsListRowView: View {
    let row: AppUpdateRow
    @ObservedObject var controller: AppUpdatesController
    let actions: AppsListActions
    let reveal: (AppUpdateRow) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AppIconView(path: row.path, fallback: row.icon, provider: controller.iconProvider, size: 32, revision: row.installedVersion)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name).font(.headline).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 8) {
                    Text(verbatim: row.installedVersion).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if let badge = row.sourceBadge {
                        Text(verbatim: badge).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .accessibilityLabel(Text(verbatim: "Source " + badge))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: row.listStatus).font(.callout)
                .foregroundStyle(row.hasUpdateToShow || row.selfUpdateVersion != nil ? ShellBrand.accent : Color.secondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .trailing)
            Menu { menuItems } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(Text(verbatim: "Actions for " + row.name)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var menuItems: some View {
        Button("Show in Finder") { reveal(row) }
        if row.hasUpdateToShow { Button("Show in Updates") { actions.showInUpdates(row) } }
        if row.canOpenInAppStore {
            Button("Open in App Store") { controller.openInAppStore(id: row.id) }.disabled(row.activity != .idle)
        }
        if controller.canIgnore(row) { Button("Ignore") { controller.ignore(id: row.id) } }
        if controller.canStopIgnoring(row) { Button("Stop ignoring") { controller.stopIgnoring(id: row.id) } }
    }
}
