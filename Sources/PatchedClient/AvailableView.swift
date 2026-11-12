import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PatchedShell

/// The Available screen: the apps an organisation approved, which a standard user can install into ~/Applications.
/// Looks and behaves like the Updates list. Once an app is installed it appears in Updates as normal.
public struct AvailableView: View {
    @ObservedObject private var controller: SelfServiceController
    @State private var search = ""
    @State private var category: String?

    public init(controller: SelfServiceController) { self.controller = controller }

    public var body: some View {
        let shown = controller.visibleRows(search: search, category: category)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: controller.summaryText).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            if let problem = controller.catalogueProblem {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon").accessibilityHidden(true)
                    Text(verbatim: problem).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer(minLength: 8)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.16)))
            }
            if !controller.rows.isEmpty { filters }
            Divider()
            if shown.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { row in
                            AvailableRowView(row: row, controller: controller)
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await controller.reload() }
        // A reload can remove the chosen category; go back to All rather than show an empty list.
        .onChange(of: controller.categories) { categories in
            if let chosen = category, !categories.contains(chosen) { category = nil }
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            TextField(text: $search, prompt: Text("Search")) { Text("Search apps") }
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 260)
                .accessibilityLabel(Text("Search apps"))
            if !controller.categories.isEmpty {
                Picker(selection: $category) {
                    Text("All categories").tag(String?.none)
                    ForEach(controller.categories, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                } label: { Text("Category") }
                    .frame(maxWidth: 190)
                    .accessibilityLabel(Text("Category"))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if let message = controller.emptyStateText(search: search, category: category) {
            Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        Spacer(minLength: 0)
    }
}

private struct AvailableRowView: View {
    let row: SelfServiceRow
    @ObservedObject var controller: SelfServiceController

    /// The system's own generic application icon: there is no icon URL to fetch before install.
    private static let genericAppIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    private var unavailable: Bool {
        switch row.state { case .needsAdmin, .invalid: return true; default: return false }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.name).font(.headline)
                    if let category = row.category {
                        Text(verbatim: category).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .accessibilityLabel(Text("Category \(category)"))
                    }
                }
                if let description = row.description {
                    Text(verbatim: description).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                statusLine
                if let result = row.result {
                    Text(verbatim: result.text).font(.footnote)
                        .foregroundStyle(result.kind == .failure ? Color.red : (result.kind == .success ? Color.green : Color.secondary))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(unavailable ? 0.6 : 1)
            actions
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    /// Before install there is no icon URL to use, so a generic app icon stands in; an app installed just now shows its own.
    @ViewBuilder private var icon: some View {
        if let path = row.installedPath {
            AppIconView(path: path, fallback: nil, provider: WorkspaceAppIconProvider.shared, size: 40, revision: "")
        } else {
            Image(nsImage: Self.genericAppIcon).resizable().interpolation(.high)
                .frame(width: 40, height: 40).opacity(unavailable ? 0.6 : 1)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch row.state {
        case .available:
            EmptyView()
        case .installed, .done:
            Text(verbatim: SelfServiceController.installedHereText).font(.callout).foregroundStyle(.secondary)
        case .needsAdmin, .invalid:
            Text(verbatim: row.statusText).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .installing:
            HStack(spacing: 6) {
                if let fraction = row.downloadFraction, !row.cancelRequested {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: row.statusText)
                    .accessibilityLabel(Text(verbatim: row.name + ": " + row.statusText))
            }.font(.callout)
        case .failed:
            // The result line below already says what went wrong.
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch controller.action(for: row) {
            case .install:
                Button(action: { controller.install(id: row.id) }) { Text("Install") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canInstall(row))
                    .accessibilityLabel(Text("Install \(row.name)"))
            case .cancel:
                Button(action: { controller.cancel() }) { Text("Cancel") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text("Cancel installing \(row.name)"))
            case .none:
                EmptyView()
            }
        }
    }
}

extension View {
    /// The managed preferences may have changed since the window was last open: read the catalogue again when it opens.
    /// The sidebar follows the result. No network.
    func reloadsSelfServiceWhenShown(_ session: NativeClientSession) -> some View {
        task { await session.reloadSelfService() }
    }
}
