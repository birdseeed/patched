import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import AppKit
@_spi(Testing) import PatchedClient

// Independent inert fixtures, literal limits and expectations. No downloaded assets.
private func iconPNG(_ red: UInt8 = 255, width: Int = 64, height: Int = 64) throws -> Data {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        pixels[i] = red; pixels[i + 1] = 255 - red; pixels[i + 3] = 255
    }
    let bytes = Data(pixels)
    guard let provider = CGDataProvider(data: bytes as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw CheckFailure(description: "Icon fixture CGImage unavailable")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
        throw CheckFailure(description: "Icon fixture encoder unavailable")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try expect(CGImageDestinationFinalize(destination), "Icon fixture PNG encoding failed")
    return output as Data
}
private func iconBE(_ value: Int) -> Data {
    let n = UInt32(value)
    return Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
}
private func iconICNS(_ png: Data) -> Data {
    Data("icns".utf8) + iconBE(png.count + 16) + Data("icp6".utf8) + iconBE(png.count + 8) + png
}
// Native fixture qualification only: never supplies a productive scanner outcome.
private func iconTwoEntryICNS() throws -> Data {
    let small = try iconPNG(width: 64, height: 64), large = try iconPNG(width: 128, height: 128)
    let body = Data("icp6".utf8) + iconBE(small.count + 8) + small +
        Data("ic07".utf8) + iconBE(large.count + 8) + large
    return Data("icns".utf8) + iconBE(body.count + 8) + body
}
private func iconFixtureFailure(_ label: String, _ reason: String) -> CheckFailure {
    CheckFailure(description: "FIXTURE-PREFLIGHT-UNSUPPORTED [" + label + "]: " + reason +
        "; setup/OS decoder diagnostic, never meaningful feature RED")
}
private func iconQualifyFixture(_ bytes: Data, label: String, type: String,
                                minimumCount: Int, expectedDimensions: Set<Int>) throws {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(bytes as CFData, sourceOptions),
          let actualType = CGImageSourceGetType(source) else {
        throw iconFixtureFailure(label, "native ImageIO source/type unavailable")
    }
    guard (actualType as String) == type else {
        throw iconFixtureFailure(label, "unexpected native image type " + (actualType as String))
    }
    let count = CGImageSourceGetCount(source)
    guard count >= minimumCount && count <= 16 else {
        throw iconFixtureFailure(label, "native sourceCount=" + String(count) +
            ", required " + String(minimumCount) + "...16")
    }
    var observedDimensions = Set<Int>()
    for index in 0..<count {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue == height.intValue, expectedDimensions.contains(width.intValue) else {
            throw iconFixtureFailure(label, "unexpected native representation dimensions at " + String(index))
        }
        observedDimensions.insert(width.intValue)
        let thumbnailOptions = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions),
              image.width == 64, image.height == 64 else {
            throw iconFixtureFailure(label, "native 64px thumbnail unavailable at " + String(index))
        }
        var rgba = [UInt8](repeating: 0, count: 16_384)
        let rendered = rgba.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard rendered && rgba[0] > 240 && rgba[1] < 10 && rgba[2] < 10 && rgba[3] == 255 else {
            throw iconFixtureFailure(label, "native decoded pixels do not match the solid red inert fixture")
        }
    }
    guard observedDimensions == expectedDimensions else {
        throw iconFixtureFailure(label, "native ImageIO did not expose every required physical representation")
    }
}
@MainActor func registerInstalledIconFixturePreflightChecks() {
    check("installed icon fixture preflight: native PNG, ICNS and padded PNG have genuine metadata/thumbnails/pixels") {
        let png = try iconPNG()
        var padded = png
        try expect(padded.count < 1_048_576, "FIXTURE-PREFLIGHT-UNSUPPORTED: PNG fixture exceeds input ceiling")
        padded.append(Data(repeating: 0, count: 1_048_576 - padded.count))
        try iconQualifyFixture(png, label: "original PNG", type: "public.png", minimumCount: 1, expectedDimensions: [64])
        try iconQualifyFixture(iconICNS(png), label: "single-entry ICNS", type: "com.apple.icns", minimumCount: 1, expectedDimensions: [64])
        try iconQualifyFixture(padded, label: "padded 1MiB PNG", type: "public.png", minimumCount: 1, expectedDimensions: [64])
        try iconQualifyFixture(iconTwoEntryICNS(), label: "two-entry ICNS", type: "com.apple.icns", minimumCount: 2, expectedDimensions: [64, 128])
    }
    // CAPTURE PREREQUISITE CONTROL BEGIN
    // CAPTURE PREREQUISITE CONTROL END
}
private struct IconFixture {
    let base: URL, root: URL
    init() throws {
        base = try newDirectory("native-shell-icon")
        root = base.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func app(_ name: String = "A.app", claim: Any? = "Icon.png", bytes: Data? = nil) throws -> URL {
        let app = root.appendingPathComponent(name), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleDisplayName": "Same", "CFBundleIdentifier": "example.same",
            "CFBundleShortVersionString": "2", "CFBundleVersion": "7"]
        if let claim { plist["CFBundleIconFile"] = claim }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if let bytes { try bytes.write(to: contents.appendingPathComponent("Resources/Icon.png")) }
        return app
    }
    func scanner(_ observer: (@Sendable (LocalInventoryReadEvent) -> Void)? = nil) -> LocalApplicationInventory {
        LocalApplicationInventory(fixtureRoots: [root.path], observer: observer)
    }
}
private func iconRow(_ observation: LocalInventoryObservation, _ app: URL) throws -> LocalApplicationObservation {
    guard let row = observation.applications.first(where: { $0.path == app.path }) else {
        throw CheckFailure(description: "Expected physical icon fixture row missing")
    }
    try expect(row.authorityUnknown && !row.installationAllowed && observation.authorityUnknown && !observation.installationAllowed,
               "Icon observation granted authority")
    return row
}
private func iconIdentity(_ row: LocalApplicationObservation) throws {
    try expect(row.displayName == "Same" && row.claimedBundleIdentifier == "example.same" &&
        row.claimedShortVersion == "2" && row.claimedBuild == "7" && row.metadataDisposition == .observed,
        "Optional icon failure changed independent metadata")
}
private final class IconProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0, decodes = 0
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (reads, decodes) }
    func event(_ event: LocalInventoryReadEvent) {
        lock.lock(); defer { lock.unlock() }
        if case .beforeIconRead = event { reads += 1 }
        if case .beforeIconDecode = event { decodes += 1 }
    }
}
private final class IconReadHold: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var held = false, used = false, expired = false
    var state: (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (held, expired) }
    func open() { release.signal() }
    func event(_ event: LocalInventoryReadEvent) {
        guard case .beforeIconRead = event else { return }
        lock.lock()
        if used { lock.unlock(); return }
        used = true; held = true; lock.unlock()
        let timeout = release.wait(timeout: .now() + 8) == .timedOut
        lock.lock(); held = false; expired = timeout; lock.unlock()
    }
}
@MainActor func registerInstalledIconChecks() {
    check("app icon: the rasterised icon fills the whole bitmap, corner to corner, at 128 px") {
        let source = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        guard let image = WorkspaceAppIconProvider.rasterise(source),
              let rep = image.representations.first as? NSBitmapImageRep else { try expect(false, "no bitmap"); return }
        try expect(rep.pixelsWide == 128 && rep.pixelsHigh == 128 && image.size == NSSize(width: 64, height: 64),
                   "size: \(rep.pixelsWide)x\(rep.pixelsHigh) px, \(image.size) pt")
        for (x, y) in [(2, 2), (125, 2), (2, 125), (125, 125), (64, 64)] {
            let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            try expect(alpha > 0.9, "pixel (\(x), \(y)) is empty: the icon does not fill the bitmap")
        }
    }
    for format in ["png", "icns"] {
        check("installed icon: real inert \(format) becomes eager per-copy pixels") {
            let f = try IconFixture(); defer { f.clean() }
            let png = try iconPNG(), app = try f.app(claim: "Icon." + format)
            try (format == "png" ? png : iconICNS(png)).write(to: app.appendingPathComponent("Contents/Resources/Icon." + format))
            let probe = IconProbe(), r = await f.scanner({ probe.event($0) }).scan()
            let row = try iconRow(r, app); try iconIdentity(row)
            try expect(row.installedIcon?.rgba.count == 16_384, "Real installed icon not normalised to 64x64 RGBA")
            if let pixels = row.installedIcon?.rgba {
                try expect(pixels[0] > 240 && pixels[1] < 10 && pixels[3] == 255, "Decoded icon pixels do not match real fixture")
            }
            try expect(probe.counts.0 == 1 && probe.counts.1 == 1, "Expected exactly one real read/decode notification")
        }
    }
    check("installed icon: genuine two-entry ICNS uses the held reader and eager pixels") {
        let bytes = try iconTwoEntryICNS()
        // Qualify the actual bytes before interpreting any scanner assertion as feature failure.
        try iconQualifyFixture(bytes, label: "two-entry ICNS reader prerequisite", type: "com.apple.icns",
            minimumCount: 2, expectedDimensions: [64, 128])
        let f = try IconFixture(); defer { f.clean() }
        let app = try f.app(claim: "Icon.icns")
        try bytes.write(to: app.appendingPathComponent("Contents/Resources/Icon.icns"))
        let probe = IconProbe(), row = try iconRow(await f.scanner({ probe.event($0) }).scan(), app)
        try iconIdentity(row)
        guard let rgba = row.installedIcon?.rgba, rgba.count == 16_384 else {
            throw CheckFailure(description: "Qualified two-entry ICNS did not produce eager 64x64 pixels")
        }
        try expect(rgba[0] > 240 && rgba[1] < 10 && rgba[2] < 10 && rgba[3] == 255,
            "Qualified two-entry ICNS returned wrong installed pixels")
        try expect(probe.counts.0 == 1 && probe.counts.1 == 1,
            "Two-entry icon did not use one bounded held read and selected thumbnail decode")
    }
    check("installed icon: absence preserves row and generic fallback") {
        let f = try IconFixture(); defer { f.clean() }
        let app = try f.app(claim: nil), r = await f.scanner().scan(), row = try iconRow(r, app)
        try iconIdentity(row)
        try expect(row.installedIcon == nil && r.completeness == .complete, "Absent optional icon invented pixels or broke scan")
    }
    for bytes in [Data(), Data("not an icon".utf8), Data([137,80,78,71,13,10,26,10])] {
        check("installed icon: malformed/truncated \(bytes.count) bytes retain metadata") {
            let f = try IconFixture(); defer { f.clean() }
            let app = try f.app(bytes: bytes), row = try iconRow(await f.scanner().scan(), app)
            try iconIdentity(row); try expect(row.installedIcon == nil, "Malformed image became an icon")
        }
    }
    let unsafeClaims: [Any] = ["../Icon.png", "/Icon.png", "Nested/Icon.png", "file:///Icon.png", "Icon.png\n", "Icon.svg", 7]
    for claim in unsafeClaims {
        check("installed icon: unsafe/unsupported name \(claim) is never read") {
            let f = try IconFixture(); defer { f.clean() }
            let app = try f.app(claim: claim, bytes: iconPNG()), probe = IconProbe()
            let row = try iconRow(await f.scanner({ probe.event($0) }).scan(), app)
            try iconIdentity(row)
            try expect(row.installedIcon == nil && probe.counts.0 == 0 && probe.counts.1 == 0, "Unsafe icon name reached I/O or decoder")
        }
    }
    for kind in ["symlink", "hardlink", "fifo"] {
        check("installed icon: \(kind) leaf refuses without losing metadata") {
            let f = try IconFixture(); defer { f.clean() }
            let app = try f.app(), file = app.appendingPathComponent("Contents/Resources/Icon.png")
            let outside = f.base.appendingPathComponent("Outside.png"); try iconPNG().write(to: outside)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: outside.path) }
            else if kind == "hardlink" { try expect(link(outside.path, file.path) == 0, "Hardlink fixture failed") }
            else { try expect(mkfifo(file.path, 0o600) == 0, "FIFO fixture failed") }
            let probe = IconProbe(), row = try iconRow(await f.scanner({ probe.event($0) }).scan(), app)
            try iconIdentity(row)
            try expect(row.installedIcon == nil && probe.counts.1 == 0, "Unsafe icon file decoded")
        }
    }
    for boundary in ["resources", "contents", "bundle", "root"] {
        check("installed icon: symlink \(boundary) never supplies installed pixels") {
            let f = try IconFixture(); defer { f.clean() }
            let app = try f.app(bytes: iconPNG())
            let path = boundary == "root" ? f.root : boundary == "bundle" ? app :
                app.appendingPathComponent(boundary == "resources" ? "Contents/Resources" : "Contents")
            let saved = f.base.appendingPathComponent("Saved")
            try FileManager.default.moveItem(at: path, to: saved)
            try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: saved.path)
            let probe = IconProbe(), r = await f.scanner({ probe.event($0) }).scan()
            try expect(r.applications.allSatisfy { $0.installedIcon == nil } && probe.counts.1 == 0,
                "Symlink ancestor supplied decoded pixels")
            try expect(r.issues.contains { $0.kind == .unsafePath }, "Unsafe ancestry was silent")
        }
    }
    check("installed icon: byte ceiling refuses before read or decode") {
        let f = try IconFixture(); defer { f.clean() }
        let app = try f.app(bytes: Data(repeating: 0, count: 1_048_577)), probe = IconProbe()
        let row = try iconRow(await f.scanner({ probe.event($0) }).scan(), app)
        try iconIdentity(row)
        try expect(row.installedIcon == nil && probe.counts.0 == 0 && probe.counts.1 == 0, "Oversize source entered read/decode")
    }
    check("installed icon: source dimension ceiling refuses before pixel decode") {
        let f = try IconFixture(); defer { f.clean() }
        let app = try f.app(bytes: iconPNG(width: 1025, height: 1)), probe = IconProbe()
        let row = try iconRow(await f.scanner({ probe.event($0) }).scan(), app)
        try iconIdentity(row)
        try expect(row.installedIcon == nil && probe.counts.1 == 0, "Oversize dimensions entered pixel decode")
    }
    for boundary in ["file", "resources", "contents", "bundle", "root"] {
        check("installed icon: actual \(boundary) replacement during captured read refuses old pixels") {
            let f = try IconFixture(); defer { f.clean() }
            let app = try f.app(bytes: iconPNG())
            let target = boundary == "root" ? f.root : boundary == "bundle" ? app : app.appendingPathComponent(
                boundary == "file" ? "Contents/Resources/Icon.png" : boundary == "resources" ? "Contents/Resources" : "Contents")
            let scanner = f.scanner { event in
                guard case .beforeIconRead = event else { return }
                try? FileManager.default.moveItem(at: target, to: f.base.appendingPathComponent("Moved"))
                // A real namespace mutation, not an injected scanner result.
            }
            let r = await scanner.scan()
            try expect(!r.applications.isEmpty, "Changed copy disappeared without safe row")
            try expect(r.applications.allSatisfy { $0.installedIcon == nil }, "Old icon survived changed ancestor/file")
            try expect(r.issues.contains { $0.kind == .changedDuringScan || $0.kind == .unreadable }, "Changed namespace was silent")
        }
    }
    check("installed icon: same-name same-ID copies retain distinct pixel values") {
        let f = try IconFixture(); defer { f.clean() }
        let a = try f.app("A.app", bytes: iconPNG(255)), b = try f.app("B.app", bytes: iconPNG(0))
        let r = await f.scanner().scan(), ar = try iconRow(r, a), br = try iconRow(r, b)
        try expect(ar.physicalIdentity != br.physicalIdentity && ar.installedIcon != nil && br.installedIcon != nil &&
            ar.installedIcon != br.installedIcon, "Same claims mixed two physical copies")
    }
    check("installed icon: new generation discards absent icon and another session shares no cache") {
        let f = try IconFixture(); defer { f.clean() }
        let app = try f.app(bytes: iconPNG()), scanner = f.scanner(), first = await scanner.scan()
        try expect(try iconRow(first, app).installedIcon != nil, "First generation positive fixture missing")
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources/Icon.png"))
        let second = await scanner.scan(), other = await f.scanner().scan()
        try expect(second.sessionID == first.sessionID && second.generation == first.generation + 1 &&
            other.sessionID != first.sessionID, "Scanner session/generation fixture invalid")
        try expect(try iconRow(second, app).installedIcon == nil, "Stale generation reused old icon")
        try expect(try iconRow(other, app).installedIcon == nil, "Cross-session icon cache reused")
    }
    check("installed icon: late real read cannot deliver pixels from a replaced copy") {
        let f = try IconFixture(); defer { f.clean() }
        let app = try f.app(bytes: iconPNG()), hold = IconReadHold()
        let inventory = f.scanner { hold.event($0) }
        let pending = Task { await inventory.scan() }
        let deadline = Date().addingTimeInterval(3)
        while !hold.state.0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard hold.state.0 else { hold.open(); _ = await pending.value; throw CheckFailure(description: "No real icon read to hold") }
        try FileManager.default.moveItem(at: app, to: f.base.appendingPathComponent("Old.app"))
        _ = try f.app(bytes: iconPNG(0))
        hold.open()
        let late = await pending.value
        try expect(!hold.state.1 && late.generation == 1 &&
            late.applications.allSatisfy { $0.installedIcon == nil },
            "Late old-copy completion populated replacement pixels")
        let fresh = await inventory.scan()
        try expect(fresh.generation == 2 && fresh.applications.first?.installedIcon?.rgba.first == 0,
            "Fresh generation failed to observe only replacement pixels")
    }
    check("installed icon: retained snapshot cache has hard count and byte limits") {
        let f = try IconFixture(); defer { f.clean() }
        for n in 0..<65 { _ = try f.app(String(format: "A%03d.app", n), bytes: iconPNG()) }
        let probe = IconProbe(), r = await f.scanner({ probe.event($0) }).scan()
        let icons = r.applications.compactMap(\.installedIcon)
        try expect(r.applications.count == 65 && icons.count == 64, "Retained-icon limit erased rows or failed at literal 64")
        try expect(icons.reduce(0) { $0 + $1.rgba.count } == 1_048_576 && probe.counts.1 == 64, "Pixel cache/decode work exceeded literal cap")
    }
    check("installed icon: aggregate encoded read work is reserved before read") {
        let f = try IconFixture(); defer { f.clean() }
        var bytes = try iconPNG(); bytes.append(Data(repeating: 0, count: 1_048_576 - bytes.count))
        for n in 0..<9 { _ = try f.app(String(format: "A%02d.app", n), bytes: bytes) }
        let probe = IconProbe(), r = await f.scanner({ probe.event($0) }).scan()
        try expect(r.applications.count == 9 && probe.counts.0 == 8, "Aggregate encoded reads did not stop at 8MiB")
        try expect(r.applications.compactMap(\.installedIcon).count == 8, "Bounded positive input or aggregate fallback missing")
    }
}
