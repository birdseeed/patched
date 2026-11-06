import SwiftUI
import AppKit

public enum ShellAppearance: CaseIterable, Sendable { case light, dark }
public enum ShellColorRole: CaseIterable, Sendable {
    case surface, sidebar, text, muted, accent, onAccent
}

/// Semantic values from Brand Kit v3; native text always uses system type.
public enum ShellBrand {
    public static func hex(_ role: ShellColorRole, appearance: ShellAppearance) -> String? {
        switch (role, appearance) {
        case (.surface, .light): return "#FFFFFF"
        case (.surface, .dark): return "#0F172A"
        case (.sidebar, .light): return "#F8FAFC"
        case (.sidebar, .dark): return "#1E293B"
        case (.text, .light): return "#0F172A"
        case (.text, .dark): return "#F8FAFC"
        case (.muted, .light): return "#6B7280"
        case (.muted, .dark): return "#94A3B8"
        case (.accent, .light): return "#2563EB"
        case (.accent, .dark): return "#60A5FA"
        case (.onAccent, .light): return "#FFFFFF"
        case (.onAccent, .dark): return "#0F172A"
        }
    }

    static func color(_ role: ShellColorRole, appearance: ShellAppearance) -> Color {
        // Only the compile-time palette above is parsed, never caller input.
        guard let hex = hex(role, appearance: appearance), let value = UInt32(hex.dropFirst(), radix: 16) else {
            return .primary
        }
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

/// Exact endpoint arcs from the canonical 64-unit SVG, uniformly fitted to the rect.
/// M23 60.618A30 30 0 1 0 16 57.377L16 32A16 16 0 1 1 23 45.229Z
public struct ShellBrandMark: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let outerStart = CGPoint(x: 23, y: 60.618)
        let outerEnd = CGPoint(x: 16, y: 57.377)
        let innerStart = CGPoint(x: 16, y: 32)
        let innerEnd = CGPoint(x: 23, y: 45.229)
        path.move(to: outerStart)
        addMasterArc(to: &path, from: outerStart, to: outerEnd, radius: 30, sweep: false)
        path.addLine(to: innerStart)
        addMasterArc(to: &path, from: innerStart, to: innerEnd, radius: 16, sweep: true)
        path.closeSubpath()
        let scale = min(rect.width, rect.height) / 64
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: rect.midX - 32 * scale, ty: rect.midY - 32 * scale)
        return path.applying(transform)
    }

    /// SVG endpoint-to-centre conversion for the master's two unrotated large circular arcs.
    /// Deriving the centres retains the SVG's literal, rounded endpoint coordinates.
    private func addMasterArc(to path: inout Path, from start: CGPoint, to end: CGPoint,
                              radius: CGFloat, sweep: Bool) {
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let squared = dx * dx + dy * dy
        let factor = sqrt(max(0, (radius * radius - squared) / squared)) * (sweep ? -1 : 1)
        let centre = CGPoint(x: (start.x + end.x) / 2 + factor * dy,
                             y: (start.y + end.y) / 2 - factor * dx)
        let startAngle = atan2(start.y - centre.y, start.x - centre.x)
        let endAngle = atan2(end.y - centre.y, end.x - centre.x)
        path.addArc(center: centre, radius: radius, startAngle: .radians(Double(startAngle)),
                    endAngle: .radians(Double(endAngle)), clockwise: !sweep)
    }
}

extension ShellBrand {
    /// Brand blue for tint and accents everywhere: #2563EB in light, #60A5FA in dark. It replaces the
    /// system accent colour so the app looks the same on every Mac.
    public static var accent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(hex(.accent, appearance: dark ? .dark : .light))
        })
    }

    private static func nsColor(_ hex: String?) -> NSColor {
        guard let hex, let value = UInt32(hex.dropFirst(), radix: 16) else { return .controlAccentColor }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// The Patched mark in the brand gradient, for window headers and the welcome screen.
/// The menu bar uses the same shape as a single-colour template image instead.
public struct BrandMarkView: View {
    private let size: CGFloat
    public init(size: CGFloat = 32) { self.size = size }
    public var body: some View {
        ShellBrandMark()
            .fill(RadialGradient(stops: [
                .init(color: Color(.sRGB, red: 34 / 255, green: 211 / 255, blue: 238 / 255), location: 0),
                .init(color: Color(.sRGB, red: 59 / 255, green: 130 / 255, blue: 246 / 255), location: 0.48),
                .init(color: Color(.sRGB, red: 37 / 255, green: 99 / 255, blue: 235 / 255), location: 1)
            ], center: UnitPoint(x: 0.82, y: 0.24), startRadius: 0, endRadius: size * 0.78),
                  style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
