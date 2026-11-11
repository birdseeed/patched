import SwiftUI
import AppKit

/// The "Open at login" setting. The Settings form refreshes the status (touching `SMAppService`) only when it is shown.
public struct OpenAtLoginView: View {
    @ObservedObject private var controller: OpenAtLoginController
    public init(controller: OpenAtLoginController) { self.controller = controller }

    /// Rows for a Settings form section: the toggle, its status and, when needed, the way to approve it.
    public var body: some View {
        Group {
            Toggle("Open Patched when I log in", isOn: Binding(get: { controller.isOn },
                                                              set: { controller.setEnabled($0) }))
                .disabled(!controller.isAvailable)
            Text(verbatim: controller.statusText).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.needsApproval {
                Button("Open Login Items settings") { controller.openSystemSettings() }
            }
        }
    }
}
