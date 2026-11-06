import Foundation
import CoreGraphics
import ImageIO

/// Eager, immutable 64 x 64 premultiplied RGBA8 display pixels only.
/// No URL, lazy NSImage, decoder, authority, or productive public constructor.
public struct LocalInstalledIcon: Sendable, Equatable {
    public let rgba: Data
    internal init?(rgba: Data) {
        guard rgba.count == 16_384 else { return nil }
        self.rgba = rgba
    }
}

/// Used synchronously by the held inventory reader only. Source properties are
/// admitted before any pixel operation; no encoded data or decoder escapes.
internal enum LocalInstalledIconDecoder {
    static func normalise(_ bytes: Data, confirm: () throws -> Void,
                          beforeDecode: () -> Void) throws -> LocalInstalledIcon? {
        try confirm()
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, sourceOptions),
              let type = CGImageSourceGetType(source),
              ["public.png", "com.apple.icns"].contains(type as String) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 16 else { return nil }
        var pixels = 0
        for index in 0..<count {
            try confirm()
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, sourceOptions) as? [CFString: Any],
                  let width = dimension(properties[kCGImagePropertyPixelWidth]),
                  let height = dimension(properties[kCGImagePropertyPixelHeight]) else { return nil }
            let area = width.multipliedReportingOverflow(by: height)
            guard !area.overflow else { return nil }
            let sum = pixels.addingReportingOverflow(area.partialValue)
            guard !sum.overflow, sum.partialValue <= 4_194_304 else { return nil }
            pixels = sum.partialValue
            try confirm()
        }
        // The notification cannot supply an outcome and runs only after admission.
        try confirm()
        beforeDecode()
        try confirm()
        let thumbnailOptions = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCache: false] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              thumbnail.width > 0, thumbnail.width <= 64,
              thumbnail.height > 0, thumbnail.height <= 64 else { return nil }
        try confirm()
        var rgba = Data(repeating: 0, count: 16_384)
        let rendered = rgba.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let scale = min(64.0 / Double(thumbnail.width), 64.0 / Double(thumbnail.height))
            let width = Double(thumbnail.width) * scale, height = Double(thumbnail.height) * scale
            context.draw(thumbnail, in: CGRect(x: (64 - width) / 2, y: (64 - height) / 2,
                                               width: width, height: height))
            return true
        }
        try confirm()
        return rendered ? LocalInstalledIcon(rgba: rgba) : nil
    }

    private static func dimension(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= 1024, value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
}
