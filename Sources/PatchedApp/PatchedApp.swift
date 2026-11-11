import SwiftUI
import AppKit
import PatchedClient
import UpdateInstaller

@main
enum PatchedEntry {
    // Retain the migration lease throughout the app session, including before
    // any installer operation takes its per-app lock.
    @MainActor private static var installerLocations: InstallerLocations?

    @MainActor static func main() {
        // Reopened by a self-update: let the previous Patched finish quitting before touching any state.
        if let previous = SelfRelaunch.pidToAwait(in: CommandLine.arguments) {
            SelfRelaunch.waitForExit(of: previous)
        }
        // A self-update that crashed or was killed can leave its staging folder beside the app; nothing else
        // would ever remove it. Only Patched.app installs (not swift run builds) have one.
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") { SelfUpdater.removeStaleWorkFolders(besideApp: bundlePath) }
        do {
            let locations = try InstallerLocations.standard()
            installerLocations = locations
            if let notice = locations.migrationNotice {
                showStateAlert("Patched updater state", detail: notice)
            }
        }
        catch {
            FileHandle.standardError.write(Data(("Patched could not prepare its local state: \(error)\n").utf8))
            showStateAlert("Patched could not prepare its local state", detail: String(describing: error))
            exit(1)
        }
        PatchedApp.main()
    }

    @MainActor private static func showStateAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private typealias MenuInsertionState<Value> = SwiftUI.State<Value>

// Both scenes retain one session. Only explicit Check actions start
// read-only work; keeping the menu available does not schedule background work.
struct PatchedApp: App {
    @NSApplicationDelegateAdaptor(PatchedApplicationDelegate.self) private var appDelegate
    @StateObject private var session = NativeClientSession()
    @StateObject private var mainWindow = PatchedMainWindow()
    @MenuInsertionState private var menuInserted = true

    var body: some Scene {
        // The label's .task below may not run in a .menu-style menu-bar item, so the delegate also starts the
        // schedule once launching has finished. Starting is idempotent: whichever runs first wins.
        let _ = appDelegate.attach(session, showMainWindow: { [appDelegate] in
            appDelegate.reopen.open()
            NSApp.activate(ignoringOtherApps: true)
        })
        WindowGroup("Patched", id: NativeClientMenuWindow.id) {
            NativeClientRootView(session: session)
                .brandAccent()
                .background(PatchedMainWindowMarker(owner: mainWindow, reopen: appDelegate.reopen))
                .background(PatchedWindowPresenceMarker(presence: appDelegate.windowPresence))
        }
        .commands {
            // One main window: no File > New Window.
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Updates") {
                NativeClientUpdatesCommands(session: session)
            }
        }
        MenuBarExtra(isInserted: $menuInserted, content: {
            PatchedMenuContent(session: session, mainWindow: mainWindow)
        }, label: {
            NativeClientMenuLabel(updates: session.appUpdates)
                // The menu-bar item is on screen from launch, so this starts the schedule at launch.
                .startsBackgroundChecks(session: session, showMainWindow: {
                    appDelegate.reopen.open()
                    NSApp.activate(ignoringOtherApps: true)
                })
        })
        // A real NSMenu: native highlighting, keyboard navigation and VoiceOver menu semantics.
        .menuBarExtraStyle(.menu)
        // The standard Settings window: the app menu's Settings… (⌘,) and the menu bar's Settings… open it.
        Settings {
            NativeClientSettingsView(session: session)
                .brandAccent()
                .background(PatchedWindowPresenceMarker(presence: appDelegate.windowPresence))
        }
    }
}

private struct PatchedMenuContent: View {
    @ObservedObject var session: NativeClientSession
    let mainWindow: PatchedMainWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if #available(macOS 14.0, *) {
            PatchedMenuContentOpeningSettings(session: session, openMain: openMain)
        } else {
            NativeClientMenuView(session: session, openWindow: openMain, openSettings: {
                // macOS 13 has no openSettings action. Its Settings scene answers showPreferencesWindow:
                // (showSettingsWindow: only exists from macOS 14), so send whichever the app responds to.
                NSApp.activate(ignoringOtherApps: true)
                let settings = Selector(("showSettingsWindow:")), preferences = Selector(("showPreferencesWindow:"))
                if !NSApp.sendAction(settings, to: nil, from: nil) {
                    NSApp.sendAction(preferences, to: nil, from: nil)
                }
            })
        }
    }

    private func openMain() {
        mainWindow.reopen {
            openWindow(id: NativeClientMenuWindow.id)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@available(macOS 14.0, *)
private struct PatchedMenuContentOpeningSettings: View {
    let session: NativeClientSession
    let openMain: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NativeClientMenuView(session: session, openWindow: openMain, openSettings: {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        })
    }
}

/// Records only the window containing this app's root view. No window lookup or
/// window ownership is added to the shared client session.
@MainActor private final class PatchedMainWindow: ObservableObject {
    private weak var window: NSWindow?
    private var opening = false

    func attached(to window: NSWindow) {
        self.window = window
        opening = false
    }

    // Called only by explicit menu or Dock reopen gestures. Coalesce same-turn scene requests;
    // a later explicit gesture can retry if no window attaches.
    func reopen(createWindow: () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else if !opening {
            opening = true
            createWindow()
            DispatchQueue.main.async { [weak self] in self?.opening = false }
        }
    }
}

private struct PatchedMainWindowMarker: NSViewRepresentable {
    let owner: PatchedMainWindow
    let reopen: NativeClientReopenCoordinator
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> PatchedMainWindowMarkerView {
        registerOpener()
        return PatchedMainWindowMarkerView(owner: owner)
    }

    func updateNSView(_ nsView: PatchedMainWindowMarkerView, context: Context) {
        registerOpener()
    }

    private func registerOpener() {
        // Capture only the stable adapter and the scene action, never this view
        // or the coordinator retaining the closure. It survives root-view removal.
        let owner = owner, openWindow = openWindow
        reopen.register(opener: {
            owner.reopen { openWindow(id: NativeClientMenuWindow.id) }
            NSApp.activate(ignoringOtherApps: true)
        })
    }
}

private final class PatchedMainWindowMarkerView: NSView {
    private let owner: PatchedMainWindow

    init(owner: PatchedMainWindow) {
        self.owner = owner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { owner.attached(to: window) }
    }
}

/// Reports the window it is in (main or Settings) to the app's window presence, which shows the Dock icon and
/// app menu while such a window is open.
private struct PatchedWindowPresenceMarker: NSViewRepresentable {
    let presence: NativeClientWindowPresence

    func makeNSView(context: Context) -> PatchedWindowPresenceMarkerView {
        PatchedWindowPresenceMarkerView(presence: presence)
    }

    func updateNSView(_ nsView: PatchedWindowPresenceMarkerView, context: Context) {}
}

private final class PatchedWindowPresenceMarkerView: NSView {
    private let windowPresence: NativeClientWindowPresence

    init(presence: NativeClientWindowPresence) {
        windowPresence = presence
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { windowPresence.track(window) }
    }
}

@MainActor private final class PatchedApplicationDelegate: NSObject, NSApplicationDelegate {
    let reopen = NativeClientReopenCoordinator()
    /// Patched is a menu-bar app (LSUIElement); this makes it a regular app while one of its windows is open.
    let windowPresence = NativeClientWindowPresence()

    private weak var session: NativeClientSession?
    private var showMainWindow: (@MainActor () -> Void)?
    private var launched = false

    // Registered while launching, so a click on a notification that launched the app is delivered.
    func applicationWillFinishLaunching(_ notification: Notification) {
        SystemUpdateNotifier.shared.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        startBackgroundChecksIfReady()
    }

    /// Called from the scene body with the app's one session. Cheap and idempotent.
    func attach(_ session: NativeClientSession, showMainWindow: @escaping @MainActor () -> Void) {
        guard self.session !== session else { return }
        self.session = session
        self.showMainWindow = showMainWindow
        startBackgroundChecksIfReady()
    }

    private func startBackgroundChecksIfReady() {
        guard launched, let session, let showMainWindow else { return }
        // After the current turn, so it never runs inside a scene body evaluation.
        DispatchQueue.main.async { session.startBackgroundChecks(showMainWindow: showMainWindow) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        reopen.handleReopen(hasVisibleWindows: hasVisibleWindows)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !NativeClientLifecyclePolicy.continuesSessionAfterLastWindowCloses
    }
}
