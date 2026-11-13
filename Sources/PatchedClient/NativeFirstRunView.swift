import SwiftUI
import PatchedShell

/// Displays the setup steps. Only explicit controls request controller actions.
public struct NativeFirstRunView: View {
    @ObservedObject private var controller: NativeFirstRunController
    private let automaticUpdates: AutomaticUpdateSettings?
    /// `automaticUpdates` is the same object Settings uses, so the switch here is the Settings switch.
    public init(controller: NativeFirstRunController, automaticUpdates: AutomaticUpdateSettings? = nil) {
        self.controller = controller
        self.automaticUpdates = automaticUpdates
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                BrandMarkView(size: 24)
                Text(verbatim: "Patched").font(.headline)
                Spacer()
                Text(stepLabel)
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
        .frame(minWidth: 680, minHeight: 520)
    }

    private var stepLabel: LocalizedStringKey {
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
                point("Checking", "Patched checks for updates when it opens and every 3 hours. Checks never install anything unless you turn on automatic updates below.")
                point("Notifications", "Patched asks macOS for permission to show notifications the first time it has an update to tell you about.")
                point("Installing", "An app is updated only when you click Update or Update All, unless you turn on automatic updates below. If the app is open, Patched asks before quitting it.")
                point("Apps that need more help", "Apps from the App Store are updated in the App Store, and apps that need admin rights are updated with their own updater. Patched opens them for you.")
                if let automaticUpdates { FirstRunAutomaticUpdatesView(settings: automaticUpdates) }
            }
        case .findApps:
            heading("You are ready")
            detail("Open Updates to see what is new, or check again at any time. Nothing is downloaded or changed until you choose an update.")
        }
    }

    private func point(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            detail(text)
        }
    }

    private var actions: some View {
        HStack {
            if controller.step != .welcome {
                Button(action: { controller.back() }) { Text("Back") }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityLabel("Back")
            }
            Spacer()
            Button(action: { primaryAction() }) { Text(primaryTitle) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(primaryTitle)
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch controller.step {
        case .welcome, .review: return "Continue"
        case .findApps: return "Open Updates"
        }
    }

    private func primaryAction() {
        if controller.step == .findApps { controller.openUpdates() } else { controller.advance() }
    }

    private func heading(_ value: LocalizedStringKey) -> some View {
        Text(value).font(.largeTitle.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }

    private func detail(_ value: LocalizedStringKey) -> some View {
        Text(value).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The opt-in switch on the review step. It reads and writes through `AutomaticUpdateSettings`, exactly as Settings does,
/// so a managed value shows the same way: the effective value, disabled, with the organisation note.
@_spi(Testing) public struct FirstRunAutomaticUpdatesView: View {
    @ObservedObject var settings: AutomaticUpdateSettings
    public init(settings: AutomaticUpdateSettings) { self.settings = settings }

    /// What the switch shows and whether it can be changed: the effective value, as in Settings.
    public var switchIsOn: Bool { settings.isEnabled }
    public var switchIsLocked: Bool { settings.enabledLocked }
    /// A user flip of the switch. The same call Settings makes; ignored while an organisation manages the setting.
    public func setSwitch(_ on: Bool) { settings.setEnabled(on) }
    /// Says where to change the time only when it can be changed.
    public var captionText: String {
        settings.timeLocked
            ? String(localized: "Once a day at \(settings.time.string).")
            : String(localized: "Once a day at \(settings.time.string). You can change the time in Settings.")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { switchIsOn }, set: { setSwitch($0) })) {
                Text("Install updates automatically").font(.headline)
            }
            .disabled(switchIsLocked)
            .accessibilityLabel("Install updates automatically")
            .accessibilityHint(Text(verbatim: captionText))
            Text(verbatim: captionText).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.enabledLocked || settings.timeLocked {
                Text(verbatim: AutomaticUpdateSettings.lockedNote).font(.callout).foregroundStyle(.secondary)
            }
            if settings.managedValueIgnored {
                Text(verbatim: AutomaticUpdateSettings.invalidNote).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
