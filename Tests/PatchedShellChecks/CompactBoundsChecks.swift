import Foundation
import SwiftUI
import PatchedShell

/// Independent pixel bounds for the literal 40x40 synthetic magenta fixture.
/// No sidebar width, breakpoint or product-derived expected coordinates are assumed.
private func compactProbeBounds(_ image: CGImage) throws -> (count: Int, minX: Int, minY: Int, width: Int, height: Int) {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        return true
    }
    guard drew else { throw Failure(description: "Compact probe pixel inspection unavailable") }
    var count = 0
    var minX = image.width, minY = image.height
    var maxX = -1, maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width {
            let index = (y * image.width + x) * 4
            if bytes[index] > 240 && bytes[index + 1] < 15 && bytes[index + 2] > 240 {
                count += 1
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    return (count, minX, minY, count == 0 ? 0 : maxX - minX + 1, count == 0 ? 0 : maxY - minY + 1)
}

@MainActor func registerCompactBoundsChecks() {
    for dark in [false, true] {
        for compact in [false, true] {
            let width = compact ? 640 : 800
            let height = compact ? 480 : 600
            let name = "initial-content-bounds-" + String(width) + "-" + (dark ? "dark" : "light")
            check("compact bounds: " + name) {
                let output = try outputDirectory()
                let state = fixtureNavigation()
                let view = ShellView(navigation: state, destinationLabels: [.updates: longLabel],
                                     destinationContent: { _ in probe(longLabel) })
                let result = try render(view, width: width, height: height, dark: dark)
                try retain(result, name: name, output: output)
                let bounds = try compactProbeBounds(result.image)
                let boundingBox: String = "(\(bounds.minX),\(bounds.minY),\(bounds.width),\(bounds.height))"
                let diagnostic: String = "Compact probe \(name) bbox=\(boundingBox) magenta=\(bounds.count) retained=\(output.path)"
                print(diagnostic)
                try expect(bounds.width >= 39 && bounds.height >= 39 && bounds.count >= 1500,
                           "Initial painting clips the literal 40x40 content probe")
            }
        }
    }
}
