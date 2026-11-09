import SwiftUI
import PatchedShell
import CoreGraphics

extension LocalInstalledIcon {
    /// Eager, fixed-size pixels only, exactly as the read-only inventory view draws them.
    var cgImage: CGImage? {
        guard rgba.count == 16_384, let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The Updates screen: check, per-app Update, Update All, Roll back and Recover.
public struct AppUpdatesView: View {
    @ObservedObject private var controller: AppUpdatesController

    public init(controller: AppUpdatesController) { self.controller = controller }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "Updates").font(.title2).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if controller.phase == .checking {
                    ProgressView().controlSize(.small)
                    button("Cancel", enabled: true, prominent: false) { controller.cancelCheck() }
                }
                button("Update All", enabled: controller.canUpdateAll, prominent: false) { controller.updateAll() }
                button(controller.phase == .checking ? "Checking…" : (controller.hasChecked ? "Check again" : "Check for Updates"),
                       enabled: controller.canCheck, prominent: true) { controller.check() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            Text(verbatim: controller.summary).font(.body.weight(.semibold))
            if let notice = controller.notice {
                Text(verbatim: notice).font(.callout).foregroundStyle(.secondary)
            }
            if let error = controller.catalogueError {
                CatalogueErrorBanner(message: error, retryEnabled: !controller.isWorking && controller.phase == .idle) {
                    Task { await controller.refreshInstallerState() }
                }
            }
            if let own = controller.selfUpdate {
                SelfUpdateLine(text: own.text) { controller.downloadSelfUpdate() }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ShellBrand.accent.opacity(0.12)))
            }
            if let failure = controller.ignoreEditFailure {
                IgnoreEditFailureBanner(message: failure) { controller.dismissIgnoreEditFailure() }
            }
            if !controller.unreadableJournals.isEmpty { unreadableBanner }
            if controller.unfinishedCount > 0 { recoverBanner }
            if let message = controller.recoveryMessage {
                Text(verbatim: message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.updatesRows) { row in
                            AppUpdateRowView(row: row, controller: controller,
                                             highlighted: controller.focusedRowID == row.id)
                                .id(row.id)
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A row picked in the menu: bring it into view and mark it. Nothing is started.
                .onChange(of: controller.focusRequest) { _ in
                    guard let id = controller.focusedRowID else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = controller.focusedRowID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await controller.refreshInstallerState() }
        .alert(Text(verbatim: "App is open"),
               isPresented: Binding(get: { controller.pendingQuit != nil }, set: { if !$0 { controller.cancelQuit() } }),
               presenting: controller.pendingQuit) { _ in
            Button("Cancel", role: .cancel) { controller.cancelQuit() }
            Button("Quit and Continue") { controller.confirmQuit() }
        } message: { pending in
            Text(verbatim: pending.message)
        }
        .sheet(isPresented: Binding(get: { controller.installerWait != nil }, set: { _ in })) {
            if let wait = controller.installerWait { InstallerWaitSheet(wait: wait) { controller.finishInstaller() } }
        }
    }

    private var unreadableBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Updates are paused: a transaction record cannot be read, and it could concern any app. Choose Recover, or inspect the listed file.")
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(controller.unreadableJournals, id: \.self) { path in
                    Text(verbatim: path).font(.footnote).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            button("Recover", enabled: !controller.isWorking && controller.phase == .idle, prominent: true) { controller.recover() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.16)))
    }

    private var recoverBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            Text(verbatim: "An earlier update did not finish (\(controller.unfinishedCount)). Recover to finish or undo it.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            button("Recover", enabled: !controller.isWorking && controller.phase == .idle, prominent: true) { controller.recover() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.18)))
    }

    private func button(_ title: String, enabled: Bool, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }
            .buttonStyle(ClientButtonStyle(enabled: enabled, prominent: prominent))
            .disabled(!enabled)
    }
}

private struct AppUpdateRowView: View {
    let row: AppUpdateRow
    @ObservedObject var controller: AppUpdatesController
    var highlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.name).font(.headline)
                    Text(verbatim: row.versionChange).font(.callout).foregroundStyle(.secondary)
                    if let badge = row.sourceBadge {
                        Text(verbatim: badge).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .accessibilityLabel(Text(verbatim: "Source " + badge))
                    }
                }
                statusLine
                if row.rollbackUnsupported {
                    Text(verbatim: AppUpdateRow.rollbackUnsupportedCaption).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if row.needsManualAdmin {
                    Text(verbatim: AppUpdateRow.needsAdminCaption).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The caption above already says why; only a failure to open the app adds to it.
                if let result = row.result, !(row.needsManualAdmin && result.kind == .info) {
                    Text(verbatim: result.text).font(.footnote)
                        .foregroundStyle(result.kind == .failure ? Color.red : (result.kind == .success ? Color.green : Color.secondary))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
            if controller.canIgnore(row) {
                Menu {
                    Button("Ignore") { controller.ignore(id: row.id) }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(Text(verbatim: "More actions for " + row.name)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(highlighted ? ShellBrand.accent.opacity(0.12) : Color.clear))
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        AppIconView(path: row.path, fallback: row.icon, provider: controller.iconProvider, size: 32, revision: row.installedVersion)
    }

    @ViewBuilder private var statusLine: some View {
        switch row.activity {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(verbatim: "Checking…") }.font(.callout)
        case .updating:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(verbatim: "Updating…") }.font(.callout)
        case .rollingBack:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(verbatim: "Rolling back…") }.font(.callout)
        case .idle:
            Text(verbatim: row.statusText).font(.callout)
                .foregroundStyle(row.status == .updateAvailable || row.status == .appStoreUpdate ? ShellBrand.accent : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if row.needsManualAdmin && row.status == .updateAvailable {
                // Patched cannot update this app. The click opens it, so its own updater can.
                let enabled = controller.canOpenApp(row)
                Button(action: { controller.openApp(id: row.id) }) { Text(verbatim: row.openAppActionTitle) }
                    .buttonStyle(ClientButtonStyle(enabled: enabled, prominent: true))
                    .disabled(!enabled)
                    .accessibilityLabel(Text(verbatim: row.openAppActionTitle))
            } else if row.status == .updateAvailable || row.status == .notInstallable || row.status == .packageUnsupported {
                let enabled = controller.canUpdate(row)
                Button(action: { controller.update(id: row.id) }) { Text(verbatim: row.updateActionTitle) }
                    .buttonStyle(ClientButtonStyle(enabled: enabled, prominent: true))
                    .disabled(!enabled)
                    .accessibilityLabel(Text(verbatim: "Update " + row.name))
            }
            if row.isAppStoreUpdate || row.isAppStoreUnconfirmed {
                // The App Store installs these; Patched only opens it, on this click.
                Button(action: { controller.openInAppStore(id: row.id) }) { Text(verbatim: "Open in App Store") }
                    .buttonStyle(ClientButtonStyle(enabled: row.activity == .idle, prominent: row.isAppStoreUpdate))
                    .disabled(row.activity != .idle)
                    .accessibilityLabel(Text(verbatim: "Open " + row.name + " in the App Store"))
            }
            if let backup = row.rollbackVersion {
                let enabled = controller.canRollBack(row)
                Button(action: { controller.rollBack(id: row.id) }) { Text(verbatim: "Roll back") }
                    .buttonStyle(ClientButtonStyle(enabled: enabled, prominent: false))
                    .disabled(!enabled)
                    .accessibilityLabel(Text(verbatim: "Roll back " + row.name + " to " + backup))
                    .help(Text(verbatim: "Restores version " + backup))
            }
        }
    }
}

/// Experimental admin path: Apple's Installer is open for a `.pkg`. Done tells Patched to check what was
/// installed; Patched also notices by itself when the app changes.
private struct InstallerWaitSheet: View {
    let wait: AppUpdateInstallerWait
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Finish in Apple's Installer").font(.headline).accessibilityAddTraits(.isHeader)
            Text(verbatim: "Finish the installation of \(wait.name) in Apple's Installer, then press Done.")
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: wait.message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: done) { Text(verbatim: "Done") }
                    .buttonStyle(ClientButtonStyle(enabled: true, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Why checking and updating are paused (the catalogue cannot be used), with a Try again. Shared by the
/// Updates and Applications screens.
struct IgnoreEditFailureBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            Text(verbatim: message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: dismiss) { Text(verbatim: "Dismiss") }
                .buttonStyle(ClientButtonStyle(enabled: true, prominent: false))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.16)))
    }
}

struct CatalogueErrorBanner: View {
    let message: String
    let retryEnabled: Bool
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon").accessibilityHidden(true)
            Text(verbatim: message + ". Checking and updating are paused.").fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: retry) { Text(verbatim: "Try again") }
                .buttonStyle(ClientButtonStyle(enabled: retryEnabled, prominent: false))
                .disabled(!retryEnabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.16)))
    }
}
