import SwiftUI
import PatchedShell

/// Displays the setup steps. Only explicit controls request controller actions.
public struct NativeFirstRunView: View {
    @ObservedObject private var controller: NativeFirstRunController
    public init(controller: NativeFirstRunController) { self.controller = controller }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                BrandMarkView(size: 24)
                Text(verbatim: "Patched").font(.headline)
                Spacer()
                Text(verbatim: stepLabel)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stepContent
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            Divider()
            actions
                .padding(20)
        }
        .font(.body)
        .tint(ShellBrand.accent)
        .frame(minWidth: 680, minHeight: 520)
    }

    private var stepLabel: String {
        switch controller.step {
        case .welcome: return "1 of 3"
        case .review: return "2 of 3"
        case .findApps: return "3 of 3"
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch controller.step {
        case .welcome:
            BrandMarkView(size: 64)
            heading("Keep your Mac apps up to date")
            detail("Patched checks the apps in your Applications folder for updates, verifies each download is signed by the same developer and notarised by Apple, and only installs when you ask.")
        case .review:
            heading("How Patched works")
            VStack(alignment: .leading, spacing: 16) {
                point("Checking", "Patched checks for updates when it opens and every 3 hours. Checks never install anything.")
                point("Notifications", "Patched asks macOS for permission to show notifications the first time it has an update to tell you about.")
                point("Installing", "An app is updated only when you click Update or Update All. If the app is open, Patched asks before quitting it.")
                point("Apps that need more help", "Apps from the App Store are updated in the App Store, and apps that need admin rights are updated with their own updater. Patched opens them for you.")
            }
        case .findApps:
            heading("You are ready")
            detail("Open Updates to see what is new, or check again at any time. Nothing is downloaded or changed until you choose an update.")
        }
    }

    private func point(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.headline)
            detail(text)
        }
    }

    private var actions: some View {
        HStack {
            if controller.step != .welcome {
                Button(action: { controller.back() }) { Text(verbatim: "Back") }
                    .buttonStyle(ClientButtonStyle(enabled: true, prominent: false))
                    .accessibilityLabel("Back")
            }
            Spacer()
            Button(action: { primaryAction() }) { Text(verbatim: primaryTitle) }
                .buttonStyle(ClientButtonStyle(enabled: true, prominent: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(primaryTitle)
        }
    }

    private var primaryTitle: String {
        switch controller.step {
        case .welcome, .review: return "Continue"
        case .findApps: return "Open Updates"
        }
    }

    private func primaryAction() {
        if controller.step == .findApps { controller.openUpdates() } else { controller.advance() }
    }

    private func heading(_ value: String) -> some View {
        Text(verbatim: value).font(.largeTitle.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }

    private func detail(_ value: String) -> some View {
        Text(verbatim: value).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
