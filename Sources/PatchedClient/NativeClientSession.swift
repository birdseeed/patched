import SwiftUI
import PatchedShell

/// Retains display selection and controllers for the shared client session.
/// Construction and presentation do no work; Check and Update remain explicit actions.
@MainActor public final class NativeClientSession: ObservableObject {
    public let navigation: ShellNavigation
    public let firstRun: NativeFirstRunController
    public let appUpdates: AppUpdatesController
    public let openAtLogin: OpenAtLoginController
    public let notificationStatus: NotificationStatusController
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
        urlOpener = live.urlOpener
        // Construction touches nothing else real: the login item, notification centre and stored check time
        // are only used once `startBackgroundChecks` runs (from the app) or Settings is shown.
        openAtLogin = OpenAtLoginController.system()
        notificationStatus = NotificationStatusController.system()
        let notifier = SystemUpdateNotifier.shared
        updateNotifier = notifier
        backgroundChecks = UpdateCheckScheduler.system(controller: live, notifier: notifier)
        updateAllEntry = UpdateAllEntryPoint(controller: live, summaryNotifier: notifier)
    }
    // Testing-only injection must retain the exact fixture owners. The nil
    // default suppresses setup to preserve every older fixture's paint contract.
    @_spi(Testing) public init(navigation: ShellNavigation, firstRun: NativeFirstRunController? = nil,
        appUpdates: AppUpdatesController? = nil, urlOpener: (any ExternalURLOpening)? = nil,
        notificationStatus: NotificationStatusController? = nil) {
        let setup = firstRun ?? NativeFirstRunController(navigation: navigation, completion: MemorySetupCompletion(completed: true))
        precondition(setup.navigation === navigation, "Testing first-run owners must match the session")
        self.navigation = navigation
        self.firstRun = setup
        self.appUpdates = appUpdates ?? AppUpdatesController.inert()
        // A given opener serves the support links, Notification Settings and the App Store; otherwise nothing is ever opened.
        let opener = urlOpener ?? InertURLOpener()
        if urlOpener != nil { self.appUpdates.urlOpener = opener }
        self.urlOpener = opener
        self.openAtLogin = OpenAtLoginController(item: UnavailableLoginItem())
        self.notificationStatus = notificationStatus ?? NotificationStatusController(reader: { $0(.unknown) })
        self.backgroundChecks = nil
        self.updateNotifier = nil
        self.updateAllEntry = UpdateAllEntryPoint(controller: self.appUpdates, summaryNotifier: nil)
    }
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
                NativeFirstRunView(controller: session.firstRun)
            } else {
                shell
            }
        }
        .tint(ShellBrand.accent)
        .frame(minWidth: 680, minHeight: 520)
    }

    private var shell: some View {
        ShellView(navigation: session.navigation,
            destinationContent: { destination in AnyView(destinationView(destination)) })
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
        case .support:
            supportPanel
        case .settings:
            SettingsView(openAtLogin: session.openAtLogin, notifications: session.notificationStatus,
                version: NativeClientSession.appVersion, openNotificationSettings: { session.openNotificationSettings() })
        }
    }

    private var supportPanel: some View {
        let content = session.supportContent
        let version = NativeClientSession.appVersion
        return VStack(alignment: .leading, spacing: 18) {
            GroupBox(label: Text(verbatim: "About").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        BrandMarkView(size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "Patched").font(.title2.weight(.semibold))
                            if let version { Text(verbatim: "Version " + version).foregroundStyle(.secondary) }
                        }
                    }
                    Text(verbatim: content.about).font(.body).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            GroupBox(label: Text(verbatim: "Support Patched").font(.headline)) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: "Patched is free. Donations go towards an Apple Developer ID so releases can be signed.")
                        .font(.body).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    ForEach(content.links, id: \.url) { link in
                        let isCoffee = link.url == PublicLinks.coffee
                        VStack(alignment: .leading, spacing: 4) {
                            Button(action: { session.openSupportLink(link) }) {
                                if isCoffee {
                                    Label { Text(verbatim: link.title) } icon: { Image(systemName: "cup.and.saucer") }
                                } else {
                                    Text(verbatim: link.title)
                                }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(ShellBrand.accent)
                            if !isCoffee {
                                Text(verbatim: link.detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            Text(verbatim: "Patched sends no messages, analytics or diagnostic reports.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(22)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
