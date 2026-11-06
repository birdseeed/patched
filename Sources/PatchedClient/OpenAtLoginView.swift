import SwiftUI
import AppKit

/// The "Open at login" setting. Reading the status touches `SMAppService` only when this is shown.
public struct OpenAtLoginView: View {
    @ObservedObject private var controller: OpenAtLoginController
    public init(controller: OpenAtLoginController) { self.controller = controller }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Open at login").font(.title2).accessibilityAddTraits(.isHeader)
            Toggle("Open Patched when I log in", isOn: Binding(get: { controller.isOn },
                                                              set: { controller.setEnabled($0) }))
                .disabled(!controller.isAvailable)
            Text(verbatim: controller.statusText).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.needsApproval {
                Button("Open Login Items settings") { controller.openSystemSettings() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }
}
