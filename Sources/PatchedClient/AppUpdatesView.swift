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
            // The window title already says "Updates", so the summary leads the screen.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: controller.summary).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if controller.phase == .checking {
                    ProgressView().controlSize(.small)
                    button("Cancel", enabled: true, prominent: false) { controller.cancelCheck() }
                }
                button("Update All", enabled: controller.canUpdateAll, prominent: false) { controller.updateAll() }
                button(controller.phase == .checking ? "Checking…" : (controller.hasChecked ? "Check again" : "Check for Updates"),
                       enabled: controller.canCheck, prominent: true) { controller.check() }
            }
            if let notice = controller.notice {
                Text(verbatim: notice).font(.callout).foregroundStyle(.secondary)
            }
            if let error = controller.catalogueError {
                CatalogueErrorBanner(message: error, retryEnabled: !controller.isWorking && controller.phase == .idle) {
                    Task { await controller.refreshInstallerState() }
                }
            }
            if let own = controller.selfUpdate {
                controller.selfUpdateLine(own)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BrandAccent.color.opacity(0.12)))
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
                        // Pinned at the top. It only opens Software Update; it is never part of Update All.
                        if let notice = controller.macOSNotice {
                            MacOSUpdateRowView(notice: notice, controller: controller,
                                               highlighted: controller.focusedRowID == MacOSUpdateNotice.rowID)
                                .id(MacOSUpdateNotice.rowID)
                            Divider()
                        }
                        ForEach(controller.updatesRows.updatesFirst) { row in
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
        .alert(Text("App is open"),
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
                Text("Updates are paused: a transaction record cannot be read, and it could concern any app. Choose Recover, or inspect the listed file.")
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
            Text("An earlier update did not finish (\(controller.unfinishedCount)). Recover to finish or undo it.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            button("Recover", enabled: !controller.isWorking && controller.phase == .idle, prominent: true) { controller.recover() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.18)))
    }

    private func button(_ title: LocalizedStringKey, enabled: Bool, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .borderedButton(prominent: prominent)
            .disabled(!enabled)
    }
}

private struct AppUpdateRowView: View {
    let row: AppUpdateRow
    @ObservedObject var controller: AppUpdatesController
    var highlighted = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.name).font(.headline)
                    Text(verbatim: row.versionChange).font(.callout).foregroundStyle(.secondary)
                    if let badge = row.sourceBadge {
                        Text(verbatim: badge).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .accessibilityLabel(Text("Source \(badge)"))
                    }
                }
                statusLine
                if let note = row.recheckNote {
                    Text(verbatim: note).font(.footnote).foregroundStyle(.secondary)
                }
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
            // The menu keeps its place while another update runs (Hide is then disabled, not removed), and rows
            // with no menu at all keep an invisible one, so every row's buttons line up.
            if controller.offersHide(row) || row.rollbackVersion != nil {
                Menu {
                    if let backup = row.rollbackVersion {
                        Button(action: { controller.rollBack(id: row.id) }) { Text("Roll back to \(backup)") }
                            .disabled(!controller.canRollBack(row))
                    }
                    if controller.offersHide(row) {
                        Button("Hide") { controller.ignore(id: row.id) }.disabled(!controller.canIgnore(row))
                    }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(Text("More actions for \(row.name)")) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else {
                Menu {} label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .hidden().disabled(true).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(highlighted ? BrandAccent.color.opacity(0.12) : Color.clear))
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        AppIconView(path: row.path, fallback: row.icon, provider: controller.iconProvider, size: 40, revision: row.installedVersion)
    }

    @ViewBuilder private var statusLine: some View {
        switch row.activity {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }.font(.callout)
        case .updating:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let fraction = row.downloadFraction, !row.cancelRequested {
                        ProgressView(value: fraction).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(verbatim: row.progressText ?? String(localized: "Updating…"))
                        .accessibilityLabel(Text(verbatim: row.name + ": " + (row.progressText ?? String(localized: "Updating"))))
                }
            }.font(.callout)
        case .rollingBack:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Rolling back…") }.font(.callout)
        case .idle:
            Text(verbatim: row.statusText).font(.callout)
                .foregroundStyle(row.status == .updateAvailable || row.status == .appStoreUpdate ? BrandAccent.color : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if row.needsManualAdmin && row.status == .updateAvailable {
                // Patched cannot update this app. The click opens it, so its own updater can.
                let enabled = controller.canOpenApp(row)
                Button(action: { controller.openApp(id: row.id) }) { Text(verbatim: row.openAppActionTitle) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!enabled)
                    .accessibilityLabel(Text(verbatim: row.openAppActionTitle))
            } else if row.status == .updateAvailable || row.status == .notInstallable || row.status == .packageUnsupported {
                let enabled = controller.canUpdate(row)
                Button(action: { controller.update(id: row.id) }) { Text(verbatim: row.updateActionTitle) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!enabled)
                    .accessibilityLabel(Text("Update \(row.name)"))
            }
            if controller.canCancelUpdate(row) {
                Button(action: { controller.cancelUpdate(id: row.id) }) { Text("Cancel") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text("Cancel updating \(row.name)"))
            }
            if row.isAppStoreUpdate || row.isAppStoreUnconfirmed {
                // The App Store installs these; Patched only opens it, on this click.
                Button(action: { controller.openInAppStore(id: row.id) }) { Text("Open in App Store") }
                    .borderedButton(prominent: row.isAppStoreUpdate)
                    .disabled(row.activity != .idle)
                    .accessibilityLabel(Text("Open \(row.name) in the App Store"))
            }
            // One visible action per row: while an update is offered, Roll back lives only in the … menu.
            if let backup = row.rollbackVersion, !row.offersUpdateAction {
                let enabled = controller.canRollBack(row)
                Button(action: { controller.rollBack(id: row.id) }) { Text("Roll back") }
                    .buttonStyle(.bordered)
                    .disabled(!enabled)
                    .accessibilityLabel(Text("Roll back \(row.name) to \(backup)"))
                    .help(Text("Puts version \(backup) of the app back. Its data is not rolled back, so anything the newer version changed stays changed."))
            }
        }
    }
}

/// The pinned macOS row: the version on offer, when Apple posted it, Open Software Update and Not now. A new major
/// is shown in a quieter style, for information. Nothing here installs anything.
private struct MacOSUpdateRowView: View {
    let notice: MacOSUpdateNotice
    @ObservedObject var controller: AppUpdatesController
    var highlighted = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "laptopcomputer").font(.system(size: 26)).frame(width: 40, height: 40)
                .foregroundStyle(notice.isMajor ? Color.secondary : BrandAccent.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if notice.isMajor {
                        Text(verbatim: notice.title).font(.body).foregroundStyle(.secondary)
                    } else {
                        Text("macOS").font(.headline)
                        Text(verbatim: notice.versionChange).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: notice.statusText).font(.callout)
                    .foregroundStyle(notice.isMajor ? Color.secondary : BrandAccent.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let posted = notice.postedText() {
                    Text(verbatim: posted).font(.footnote).foregroundStyle(.secondary)
                }
                if let major = notice.alsoMajorText {
                    Text(verbatim: major).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Button(action: { Task { await controller.openSoftwareUpdate() } }) { Text("Open Software Update") }
                    .borderedButton(prominent: !notice.isMajor)
                    .accessibilityLabel(Text("Open Software Update in System Settings"))
                Button(action: { controller.hideMacOSUpdate() }) { Text("Not now") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Hide the macOS update until the next version"))
            }
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(highlighted ? BrandAccent.color.opacity(0.12) : Color.clear))
        .accessibilityElement(children: .contain)
    }
}

/// Experimental admin path: Apple's Installer is open for a `.pkg`. Done tells Patched to check what was
/// installed; Patched also notices by itself when the app changes.
private struct InstallerWaitSheet: View {
    let wait: AppUpdateInstallerWait
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish in Apple's Installer").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Finish the installation of \(wait.name) in Apple's Installer, then press Done.")
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: wait.message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: done) { Text("Done") }
                    .buttonStyle(.borderedProminent)
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
            Button(action: dismiss) { Text("Dismiss") }
                .buttonStyle(.bordered)
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
            Text("\(message). Checking and updating are paused.").fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: retry) { Text("Try again") }
                .buttonStyle(.bordered)
                .disabled(!retryEnabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.16)))
    }
}

extension View {
    /// The native bordered button style; prominent (filled with the accent colour) for the one primary action.
    @ViewBuilder func borderedButton(prominent: Bool) -> some View {
        if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}

/// The app menu's Updates menu: Check Now (⌘R) and Update All, with the same actions and enabled rules as the
/// Updates screen's buttons. Choosing one is the explicit click; showing the menu starts nothing.
public struct NativeClientUpdatesCommands: View {
    @ObservedObject private var controller: AppUpdatesController

    public init(session: NativeClientSession) { controller = session.appUpdates }

    public var body: some View {
        Button("Check Now") { controller.check() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!controller.canCheck)
        Button("Update All") { controller.updateAll() }
            .disabled(!controller.canUpdateAll)
    }
}
