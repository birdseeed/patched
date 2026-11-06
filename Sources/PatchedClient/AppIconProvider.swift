import AppKit
import SwiftUI

// Select the property-wrapper type explicitly when an SDK also declares a State macro.
private typealias IconState<Value> = State<Value>

/// Supplies the icon Finder would show for an installed app. Display only: it reads nothing but the icon.
/// `cachedIcon` must be instant (memory only, called while rendering); `loadIcon` does any file work off the
/// main thread and may return nil.
@MainActor public protocol AppIconProviding: AnyObject {
    func cachedIcon(forPath path: String) -> NSImage?
    func loadIcon(forPath path: String) async -> NSImage?
}

/// Asks `NSWorkspace`, which understands asset catalogues (`Assets.car`) as well as plain `.icns` files.
/// Loading runs off the main thread: the path must be an absolute, non-symlinked `.app` directory, and the
/// result is rasterised once at 64 px. The cache is memory only, limited in count, and refreshed when the
/// bundle's modification date changes, so an updated app shows its new icon.
@MainActor public final class WorkspaceAppIconProvider: AppIconProviding {
    public static let shared = WorkspaceAppIconProvider()
    private final class Entry { let image: NSImage; let stamp: Double; init(_ i: NSImage, _ s: Double) { image = i; stamp = s } }
    private let cache = NSCache<NSString, Entry>()
    private var loading: [String: Task<NSImage?, Never>] = [:]
    /// A freshly rasterised bitmap handed back from the background load; nothing else holds it.
    private struct Loaded: @unchecked Sendable { let image: NSImage?; let stamp: Double?; let unchanged: Bool }

    public init(countLimit: Int = 256) { cache.countLimit = countLimit }

    public func cachedIcon(forPath path: String) -> NSImage? { cache.object(forKey: path as NSString)?.image }

    public func loadIcon(forPath path: String) async -> NSImage? {
        if let running = loading[path] { return await running.value }
        let previous = cache.object(forKey: path as NSString)
        let previousStamp = previous?.stamp
        let task = Task.detached(priority: .utility) { () -> Loaded in
            guard let stamp = Self.bundleStamp(path) else { return Loaded(image: nil, stamp: nil, unchanged: false) }
            if previousStamp == stamp { return Loaded(image: nil, stamp: stamp, unchanged: true) }
            return Loaded(image: Self.rasterise(NSWorkspace.shared.icon(forFile: path)), stamp: stamp, unchanged: false)
        }
        let wrapped = Task<NSImage?, Never> { [weak self] in
            let result = await task.value
            guard let self else { return result.image }
            self.loading[path] = nil
            if result.unchanged, let previous { return previous.image }
            guard let image = result.image, let stamp = result.stamp else {
                self.cache.removeObject(forKey: path as NSString); return nil
            }
            self.cache.setObject(Entry(image, stamp), forKey: path as NSString)
            return image
        }
        loading[path] = wrapped
        return await wrapped.value
    }

    /// Modification date of a real `.app` directory, or nil for anything else (relative, symlink, missing).
    nonisolated public static func bundleStamp(_ path: String) -> Double? {
        guard path.hasPrefix("/"), path.hasSuffix(".app") else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    }

    nonisolated static func rasterise(_ source: NSImage) -> NSImage? {
        let size = NSSize(width: 32, height: 32)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// An app's icon at `size` points. Asks the provider for the row's installed path, falls back to the
/// inventory's own pixels when it has them, then to a plain symbol.
struct AppIconView: View {
    let path: String
    let fallback: LocalInstalledIcon?
    let provider: AppIconProviding
    var size: CGFloat = 32
    /// Changes when the installed app changes (its version), so an app updated in place is looked up again:
    /// the provider then sees the new bundle modification date and re-reads the icon.
    var revision: String = ""

    @IconState private var loaded: NSImage?

    var body: some View {
        Group {
            if let image = loaded ?? provider.cachedIcon(forPath: path) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if let pixels = fallback?.cgImage {
                Image(decorative: pixels, scale: 1).resizable()
            } else {
                Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary).padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: path + "\u{0}" + revision) { loaded = await provider.loadIcon(forPath: path) }
    }
}
