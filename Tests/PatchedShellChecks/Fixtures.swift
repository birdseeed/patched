import Foundation
import Darwin
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PatchedShell

// Literal approved specification, intentionally independent of product-generated lists.
let expectedMain: [ShellDestination] = [.updates, .applications]
let expectedLower: [ShellDestination] = [.support, .settings]
let destinationLabels: [(ShellDestination, String)] = [
    (.updates, "Updates"), (.applications, "Applications"),
    (.support, "Help & Support"), (.settings, "Settings")
]
let expectedPalette: [(ShellColorRole, String, String)] = [
    (.surface, "#FFFFFF", "#0F172A"), (.sidebar, "#F8FAFC", "#1E293B"),
    (.text, "#0F172A", "#F8FAFC"), (.muted, "#6B7280", "#94A3B8"),
    (.accent, "#2563EB", "#60A5FA"), (.onAccent, "#FFFFFF", "#0F172A")
]
let longLabel = String(repeating: "Prüfung des Aktualisierungsverlaufs 日本語 ", count: 4)
let literalLabel = "<b>**Sample app**</b> & \"Name\"\nSecond line"

@MainActor func fixtureNavigation(destination: ShellDestination = .updates,
                                  onSelection: @escaping (ShellDestination) -> Void = { _ in }) -> ShellNavigation {
    ShellNavigation(destination: destination, onSelection: onSelection)
}

/// Magenta is a synthetic content probe, never a Patched brand or installed-app icon.
let probeColor = Color(red: 1, green: 0, blue: 1)
@MainActor func probe(_ text: String) -> AnyView {
    AnyView(VStack(alignment: .leading) {
        Text(verbatim: text).font(.body).fixedSize(horizontal: false, vertical: true)
        Rectangle().fill(probeColor).frame(width: 40, height: 40)
    })
}

struct Rendered {
    let image: CGImage
    let png: Data
}
@MainActor func render<V: View>(_ view: V, width: Int = 800, height: Int = 600,
                               dark: Bool = false) throws -> Rendered {
    let app = NSApplication.shared
    if app.activationPolicy() != .prohibited {
        _ = app.setActivationPolicy(.prohibited)
    }
    guard app.activationPolicy() == .prohibited, !app.isActive else {
        throw Failure(description: "Cannot establish prohibited inactive fixture process")
    }
    let content = view
        .frame(width: CGFloat(width), height: CGFloat(height))
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
    let host = NSHostingView(rootView: content)
    host.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.wantsLayer = true
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    // Close only this fixture's never-ordered window, including on capture failure.
    defer { window.close() }
    func assertUnshown() throws {
        guard app.activationPolicy() == .prohibited, !window.isVisible, !app.isActive else {
            throw Failure(description: "Owned fixture window visible or check process active; capture refused")
        }
    }
    try assertUnshown()
    host.needsLayout = true
    host.layoutSubtreeIfNeeded()
    host.needsDisplay = true
    host.displayIfNeeded()
    window.displayIfNeeded()
    try assertUnshown()

    // Bounded same-thread settling; no activation, window ordering or synthetic events.
    let deadline = Date().addingTimeInterval(0.20)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
    }
    try assertUnshown()
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    window.displayIfNeeded()
    try assertUnshown()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw Failure(description: "Cannot allocate native cache bitmap")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try assertUnshown()
    guard let captured = bitmap.cgImage else {
        throw Failure(description: "Missing native cache output")
    }
    let image: CGImage
    if captured.width == width, captured.height == height {
        image = captured
    } else {
        // Normalize only an actual, bounded integral backing scale to the frozen pixel size.
        guard width > 0, height > 0,
              captured.width % width == 0, captured.height % height == 0,
              captured.width / width == captured.height / height,
              (2...4).contains(captured.width / width),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Incorrectly bounded native cache output")
        }
        context.interpolationQuality = .high
        context.draw(captured, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let normalized = context.makeImage(), normalized.width == width, normalized.height == height else {
            throw Failure(description: "Cannot normalize native backing scale")
        }
        image = normalized
    }
    try assertUnshown()
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure(description: "PNG encoder unavailable")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure(description: "PNG encoding failed") }
    return Rendered(image: image, png: data as Data)
}
func probePixelCount(_ image: CGImage) throws -> Int {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        return true
    }
    guard drew else { throw Failure(description: "Pixel inspection unavailable") }
    return stride(from: 0, to: bytes.count, by: 4).reduce(0) { result, index in
        result + (bytes[index] > 240 && bytes[index + 1] < 15 && bytes[index + 2] > 240 ? 1 : 0)
    }
}
@MainActor func outputDirectory() throws -> URL {
    guard var build = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        throw Failure(description: "Executable path unavailable")
    }
    while build.lastPathComponent != ".build" {
        guard build.pathComponents.count > 1 else { throw Failure(description: "Executable is outside .build") }
        build.deleteLastPathComponent()
    }
    let output = build.appendingPathComponent("patched-shell-fixture-\(UUID().uuidString)")
    guard mkdir(output.path, 0o700) == 0 else { throw Failure(description: "Cannot create exclusive fixture output") }
    return output
}
@MainActor func retain(_ result: Rendered, name: String, output: URL) throws {
    try result.png.write(to: output.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
}
