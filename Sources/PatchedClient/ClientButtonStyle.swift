import SwiftUI
import PatchedShell

/// Painted entirely by SwiftUI, so the control also appears in an offscreen rendering.
/// Prominent is a filled accent shape, plain is an outline, disabled is a grey outline.
struct ClientButtonStyle: ButtonStyle {
    let enabled: Bool
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let filled = enabled && prominent
        return configuration.label
            .foregroundStyle(filled ? Color.white : (enabled ? Color.primary : Color.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(shape.fill(filled ? ShellBrand.accent : Color.secondary.opacity(enabled ? 0.08 : 0.15)))
            .overlay(shape.strokeBorder(Color.secondary.opacity(filled ? 0 : 0.5), lineWidth: 1))
            .opacity(enabled && configuration.isPressed ? 0.6 : 1)
            .contentShape(shape)
    }
}
