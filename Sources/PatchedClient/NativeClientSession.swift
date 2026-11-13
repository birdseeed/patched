import SwiftUI
import Combine
import UpdateInstaller
import PatchedShell
import UpdateSources

/// Retains display selection and controllers for the shared client session.
/// Construction and presentation do no work; Check and Update remain explicit actions.
@MainActor public final class NativeClientSession: ObservableObject {
    public let navigation: ShellNavigation
    public let firstRun: NativeFirstRunController
    public let appUpdates: AppUpdatesController
    /// Self Service: the organisation's catalogue. It shares `appUpdates`' busy state. Nothing is read until `reload()`.
    public let selfService: SelfServiceController
    private var availableVisibility: AnyCancellable?
    public let openAtLogin: OpenAtLoginController
    public let notificationStatus: NotificationStatusController
    /// The Install updates automatically setting, with any organisation override.
    public let automaticUpdates: AutomaticUpdateSettings
    let backgroundChecks: UpdateCheckScheduler?
    let updateNotifier: SystemUpdateNotifier?
    /// The menu item and notification button for Update All; both end in `appUpdates.updateAll()`.
    public let updateAllEntry: UpdateAllEntryPoint
    /// Opens the Help & Support links and Notification Settings. The same opener the Updates screen uses for the App Store.
    @_spi(Testing) public let urlOpener: any ExternalURLOpening

    public init() {
        let resolvedNavigation = ShellNavigation(destination: .updates)
        navigation = resolvedNavigation
        // Reads only the setup-completed flag, so a finished setup is not shown again.
        firstRun = NativeFirstRunController(navigation: resolvedNavigation)
        let live = AppUpdatesController.live()
        appUpdates = live
        selfService = SelfServiceController.live(updates: live)
        urlOpener = live.urlOpener
        // Construction touches nothing else real: the login item, notification centre and stored check time
        // are only used once `startBackgroundChecks` runs (from the app) or Settings is shown.
        openAtLogin = OpenAtLoginController.system()
        notificationStatus = NotificationStatusController.system()
        let notifier = SystemUpdateNotifier.shared
        updateNotifier = notifier
        let automatic = AutomaticUpdateSettings.system()
        automaticUpdates = automatic
        backgroundChecks = UpdateCheckScheduler.system(controller: live, notifier: notifier, automatic: automatic)
        updateAllEntry = UpdateAllEntryPoint(controller: live, summaryNotifier: notifier)
        bindAvailableVisibility()
    }
    // Testing-only injection must retain the exact fixture owners. The nil
    // default suppresses setup to preserve every older fixture's paint contract.
    @_spi(Testing) public init(navigation: ShellNavigation, firstRun: NativeFirstRunController? = nil,
        appUpdates: AppUpdatesController? = nil, urlOpener: (any ExternalURLOpening)? = nil,
        notificationStatus: NotificationStatusController? = nil, selfService: SelfServiceController? = nil,
        automaticUpdates: AutomaticUpdateSettings? = nil) {
        let setup = firstRun ?? NativeFirstRunController(navigation: navigation, completion: MemorySetupCompletion(completed: true))
        precondition(setup.navigation === navigation, "Testing first-run owners must match the session")
        self.navigation = navigation
        self.firstRun = setup
        self.appUpdates = appUpdates ?? AppUpdatesController.inert()
        // Unless a fixture gives one, Self Service sees no catalogue and installs nothing.
        self.selfService = selfService ?? SelfServiceController(
            updates: self.appUpdates, catalogue: { .notManaged }, scan: { [] }, teamID: { _ in nil },
            installer: UnavailableSelfServiceInstaller())
        // A given opener serves the support links, Notification Settings and the App Store; otherwise nothing is ever opened.
        let opener = urlOpener ?? InertURLOpener()
        if urlOpener != nil { self.appUpdates.urlOpener = opener }
        self.urlOpener = opener
        self.openAtLogin = OpenAtLoginController(item: UnavailableLoginItem())
        self.notificationStatus = notificationStatus ?? NotificationStatusController(reader: { $0(.unknown) })
        self.automaticUpdates = automaticUpdates ?? AutomaticUpdateSettings(store: MemoryAutomaticUpdateStore(), managed: ManagedPreferences(reader: NoManagedPreferences()))
        self.backgroundChecks = nil
        self.updateNotifier = nil
        self.updateAllEntry = UpdateAllEntryPoint(controller: self.appUpdates, summaryNotifier: nil)
        bindAvailableVisibility()
    }
    /// Available is listed in the sidebar only while a catalogue is managed on this Mac (valid or not).
    private func bindAvailableVisibility() {
        let navigation = navigation, controller = selfService
        navigation.setAvailableShown(controller.isManaged || controller.catalogueProblem != nil)
        availableVisibility = Publishers.CombineLatest(controller.$isManaged, controller.$catalogueProblem)
            .map { managed, problem in managed || problem != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { navigation.setAvailableShown($0) }
    }
    /// Reads the managed catalogue and the installed apps again (no network). The window calls this when it opens.
    public func reloadSelfService() async { await selfService.reload() }
    /// What the Help & Support screen shows.
    public var supportContent: SupportContent { SupportContent.make() }
    /// A click on a Help & Support link. Returns whether it opened.
    @discardableResult public func openSupportLink(_ link: SupportContent.Link) -> Bool { urlOpener.open(link.url) }
    /// The Settings button. Returns whether System Settings opened.
    @discardableResult public func openNotificationSettings() -> Bool { urlOpener.open(NotificationStatusController.settingsURL) }
    static var appVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
}

/// Composes existing read-only views over the session's stable owners.
public struct NativeClientRootView: View {
    @ObservedObject private var session: NativeClientSession
    @ObservedObject private var firstRun: NativeFirstRunController

    public init(session: NativeClientSession) {
        self.session = session
        self.firstRun = session.firstRun
    }

    public var body: some View {
        Group {
            if firstRun.isPresented {
                NativeFirstRunView(controller: session.firstRun, automaticUpdates: session.automaticUpdates)
            } else {
                shell
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .reloadsSelfServiceWhenShown(session)
    }

    private var shell: some View {
        OpensSettings { openSettings in
            ShellView(navigation: session.navigation, openSettings: openSettings,
                destinationContent: { destination in AnyView(destinationView(destination)) })
        }
            .frame(minWidth: 680, minHeight: 520)
    }

    @ViewBuilder private func destinationView(_ destination: ShellDestination) -> some View {
        switch destination {
        case .applications:
            AppsListView(controller: session.appUpdates, showUpdate: { session.showUpdate(id: $0) })
                .frame(minHeight: 440)
        case .updates:
            AppUpdatesView(controller: session.appUpdates)
                .frame(minHeight: 440)
        case .available:
            AvailableView(controller: session.selfService)
                .frame(minHeight: 440)
        case .support:
            ScrollView { supportPanel }
        }
    }

    private var supportPanel: some View {
        let content = session.supportContent
        let version = NativeClientSession.appVersion
        return VStack(alignment: .leading, spacing: 18) {
            GroupBox(label: Text("About").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        BrandMarkView(size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "Patched").font(.title2.weight(.semibold))
                            if let version { Text("Version \(version)").foregroundStyle(.secondary) }
                        }
                    }
                    Text(verbatim: content.about).font(.body).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            GroupBox(label: Text("Support Patched").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Patched is free. Donations help pay for the Apple Developer membership that signs and notarises each release.")
                        .font(.body).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    // One prominent action per group: the donation. The other links are ordinary buttons in a row,
                    // with their descriptions as the tooltip and VoiceOver hint.
                    ForEach(content.links.filter { $0.url == PublicLinks.coffee }, id: \.url) { link in
                        Button(action: { session.openSupportLink(link) }) {
                            Label { Text(verbatim: link.title) } icon: { Image(systemName: "cup.and.saucer") }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Divider().padding(.vertical, 4)
                    // In a row when they fit, otherwise stacked (longer translations, larger text).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { secondaryLinks }
                        VStack(alignment: .leading, spacing: 8) { secondaryLinks }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            Text("Patched sends no messages, analytics or diagnostic reports.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(22)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Help & Support's ordinary link buttons: everything but the donation.
    private var secondaryLinks: some View {
        ForEach(session.supportContent.links.filter { $0.url != PublicLinks.coffee }, id: \.url) { link in
            Button(action: { session.openSupportLink(link) }) {
                Label { Text(verbatim: link.title) } icon: { Image(systemName: Self.symbol(for: link)) }
            }
            .buttonStyle(.bordered).controlSize(.large)
            .help(Text(verbatim: link.detail))
            .accessibilityHint(Text(verbatim: link.detail))
        }
    }

    /// A symbol for each link button in Help & Support.
    private static func symbol(for link: SupportContent.Link) -> String {
        if link.url == PublicLinks.repository { return "chevron.left.forwardslash.chevron.right" }
        if link.url == PublicLinks.contact { return "envelope" }
        return "exclamationmark.bubble"
    }
}

/// For a session built without a real catalogue: nothing can be installed.
private struct UnavailableSelfServiceInstaller: SelfServiceInstalling {
    func install(_ entry: SelfServiceEntry, progress: UpdateProgressHandler?) async throws -> FreshInstallReport {
        throw InstallRefusal.needsAdmin("Self Service is not set up in this session.")
    }
}
