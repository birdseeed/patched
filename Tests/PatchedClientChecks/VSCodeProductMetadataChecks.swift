import Foundation
import Darwin
@_spi(Testing) import PatchedClient

// Proposed compiling checks against the existing scan API. Mirror permits a
// meaningful missing-field RED before adding implementation or refusing stubs.
private struct VSCodeMetadataFixture {
    let base: URL
    let root: URL
    init() throws {
        base = try newDirectory("product-metadata-fixture")
        root = base.appendingPathComponent("Applications")
        try expect(mkdir(root.path, 0o700) == 0, "Fixture root not exclusive")
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func app(_ name: String = "Code.app") throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources/app"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier":"com.microsoft.VSCode", "CFBundleName":"Code", "CFBundleShortVersionString":"1.100.0", "CFBundleVersion":"100"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    // Setup must pass before Mirror's intended missing-feature assertion.
    func validate(_ result: LocalInventoryObservation, apps: [URL],
                  allowedIssues: [LocalInventoryIssueKind] = [], budgetCase: Bool = false) throws {
        let prefix = "product-metadata fixture setup failed: "
        try expect(result.provenance == .fixture && result.generation == 1 && result.finishedAt >= result.startedAt,
                   prefix + "not the first completed fixture scan")
        try expect(result.roots.count == 1 && result.roots[0].path == root.path
                   && result.roots[0].scope == .fixture && result.roots[0].status == .scanned,
                   prefix + "exact owned root not scanned")
        try expect(result.applications.map(\.path).sorted() == apps.map(\.path).sorted(),
                   prefix + "missing, extra or wrong application rows")
        try expect(result.issues.allSatisfy { allowedIssues.contains($0.kind) && apps.map(\.path).contains($0.path ?? "") },
                   prefix + "unexpected scanner issue or issue path")
        try expect(result.completeness == (result.issues.isEmpty ? .complete : .incomplete),
                   prefix + "refused/unavailable or inconsistent scan")
        for row in result.applications {
            var physical = stat()
            try expect(lstat(row.path, &physical) == 0 && physical.st_mode & S_IFMT == S_IFDIR
                       && row.physicalIdentity.inode == UInt64(physical.st_ino)
                       && row.physicalIdentity.device == UInt64(UInt32(bitPattern: physical.st_dev)),
                       prefix + "row does not identify its real owned directory")
            let budgetStoppedPlist = budgetCase && row.metadataDisposition == .unavailable
                && result.issues.contains { $0.kind == .totalMetadataLimit && $0.path == row.path }
            if budgetStoppedPlist {
                try expect(row.claimedBundleIdentifier == nil && row.claimedShortVersion == nil && row.claimedBuild == nil
                           && row.displayName == URL(fileURLWithPath: row.path).deletingPathExtension().lastPathComponent,
                           prefix + "budget-refused plist retained unexpected identity")
            } else {
                try expect(row.metadataDisposition == .observed && row.displayName == "Code"
                           && row.claimedBundleIdentifier == "com.microsoft.VSCode"
                           && row.claimedShortVersion == "1.100.0" && row.claimedBuild == "100",
                           prefix + "expected literal plist claims not observed")
            }
            try expect(row.vendorMetadata.sparkleFeedURL == nil && row.vendorMetadata.sparkleDisposition == .unavailable,
                       prefix + "unexpected independent Sparkle claim")
            try expect(row.authorityUnknown && !row.installationAllowed && row.vendorMetadata.authorityUnknown
                       && !row.vendorMetadata.verificationAllowed && !row.vendorMetadata.installationAllowed
                       && !row.vendorMetadata.publicationAllowed, "Installed claims acquired authority")
        }
        try expect(result.authorityUnknown && !result.installationAllowed, "Inventory acquired authority")
    }
    func scan(_ app: URL, allowedIssues: [LocalInventoryIssueKind] = []) async throws -> (LocalInventoryObservation, LocalApplicationObservation) {
        let result = await LocalApplicationInventory(fixtureRoots: [root.path]).scan()
        try validate(result, apps: [app], allowedIssues: allowedIssues)
        guard let row = result.applications.first else { throw CheckFailure(description: "product-metadata fixture setup failed: missing row") }
        return (result, row)
    }
}
private func productFields(_ row: LocalApplicationObservation) throws -> (Data?, LocalInventoryMetadataDisposition) {
    let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: row.vendorMetadata).children.compactMap { child -> (String, Any)? in
        guard let label = child.label else { return nil }; return (label, child.value)
    })
    guard let raw = fields["productJSONBytes"], let bytes = raw as? Optional<Data>,
          let disposition = fields["productJSONDisposition"] as? LocalInventoryMetadataDisposition else {
        throw CheckFailure(description: "product-metadata missing bounded product.json metadata observation")
    }
    return (bytes, disposition)
}
// New SPI event contract, unimplemented: beforeProductMetadataRead(applicationPath:).
// Emit only after opening/capturing the product fd/name and before first byte read.
// Reflection is initial-baseline compatibility, not a synthetic scanner outcome.
private final class ProductSwap: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var problem: String?
    let app: URL
    init(app: URL) { self.app = app }
    func observe(_ event: LocalInventoryReadEvent) {
        let mirror = Mirror(reflecting: event)
        guard let item = mirror.children.first, item.label == "beforeProductMetadataRead" else { return }
        let fields = Mirror(reflecting: item.value).children
        guard let path = fields.first(where: { $0.label == "applicationPath" })?.value as? String, path == app.path else { return }
        lock.lock(); defer { lock.unlock() }; count += 1
        guard count == 1 else { problem = "product notification repeated"; return }
        do {
            let target = app.appendingPathComponent("Contents/Resources/app/product.json")
            try FileManager.default.moveItem(at: target, to: target.deletingLastPathComponent().appendingPathComponent("saved-product.json"))
            try Data("{\"quality\":\"beta\"}".utf8).write(to: target)
        } catch { problem = String(describing: error) }
    }
    func confirm() throws {
        lock.lock(); defer { lock.unlock() }
        try expect(count == 1 && problem == nil, "product-metadata product race setup failed: notification missing or swap failed: \(problem ?? "none")")
    }
}
@MainActor func registerVSCodeProductMetadataChecks() {
    check("exact fixed product path retains unparsed bytes and independent identity") {
        let f = try VSCodeMetadataFixture(); defer { f.clean() }; let app = try f.app()
        let bytes = Data("{\"quality\":\"stable\",\"updateUrl\":\"https://update.code.visualstudio.com\"}\n".utf8)
        try bytes.write(to: app.appendingPathComponent("Contents/Resources/app/product.json"))
        let (result,row) = try await f.scan(app); let (observed,disposition) = try productFields(row)
        try expect(observed == bytes && disposition == .observed, "Exact product bytes not observed")
        try expect(result.completeness == .complete && row.claimedBundleIdentifier == "com.microsoft.VSCode", "Product observation changed identity/completeness")
    }
    check("optional product absence remains unavailable") {
        let f = try VSCodeMetadataFixture(); defer { f.clean() }; let app = try f.app()
        let (result,row) = try await f.scan(app); let (bytes,disposition) = try productFields(row)
        try expect(bytes == nil && disposition == .unavailable && result.completeness == .complete, "Absent optional product inferred or made incomplete")
    }
    for count in [65_536,65_537] {
        check("raw product literal byte bound \(count)") {
            let f = try VSCodeMetadataFixture(); defer { f.clean() }; let app = try f.app()
            let bytes = Data(repeating: 32, count: count)
            try bytes.write(to: app.appendingPathComponent("Contents/Resources/app/product.json"))
            let (result,row) = try await f.scan(app, allowedIssues: count == 65_536 ? [] : [.malformedMetadata]); let (observed,disposition) = try productFields(row)
            if count == 65_536 { try expect(observed == bytes && disposition == .observed, "Exact raw byte bound refused") }
            else { try expect(observed == nil && disposition == .malformed && result.completeness == .incomplete, "Oversized product hidden or accepted") }
        }
    }
    for boundary in ["file","app","resources"] {
        check("no-follow product boundary \(boundary)") {
            let f = try VSCodeMetadataFixture(); defer { f.clean() }; let app = try f.app()
            try Data("{}".utf8).write(to: app.appendingPathComponent("Contents/Resources/app/product.json"))
            let relative = boundary == "file" ? "Contents/Resources/app/product.json" : boundary == "app" ? "Contents/Resources/app" : "Contents/Resources"
            let path = app.appendingPathComponent(relative), saved = f.base.appendingPathComponent("Saved")
            try FileManager.default.moveItem(at: path, to: saved)
            try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: saved.path)
            let (result,row) = try await f.scan(app, allowedIssues: [.unsafePath]); let (bytes,disposition) = try productFields(row)
            try expect(bytes == nil && disposition == .refused && result.issues.contains { $0.kind == .unsafePath }, "Symlink product read or hidden as absence")
        }
    }
    for kind in ["directory","hardlink","fifo"] {
        check("product regular singly-linked requirement \(kind)") {
            let f = try VSCodeMetadataFixture(); defer { f.clean() }; let app = try f.app()
            let path = app.appendingPathComponent("Contents/Resources/app/product.json")
            if kind == "directory" { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            else if kind == "fifo" { try expect(mkfifo(path.path, 0o600) == 0, "FIFO setup failed") }
            else { try Data("{}".utf8).write(to: path); try expect(link(path.path, f.base.appendingPathComponent("Alias").path) == 0, "Hardlink setup failed") }
            let (result,row) = try await f.scan(app, allowedIssues: [.unsafePath]); let (bytes,disposition) = try productFields(row)
            try expect(bytes == nil && disposition == .refused && result.issues.contains { $0.kind == .unsafePath }, "Unsafe product accepted")
        }
    }
    check("alternate product locations never supply data") {
        let f = try VSCodeMetadataFixture(); defer { f.clean() }; let app = try f.app()
        for path in ["product.json","Contents/product.json","Contents/Resources/product.json","Contents/Resources/app/product.json.js"] {
            try Data("{}".utf8).write(to: app.appendingPathComponent(path))
        }
        let (_,row) = try await f.scan(app); let (bytes,disposition) = try productFields(row)
        try expect(bytes == nil && disposition == .unavailable, "Alternate path supplied product bytes")
    }
    for bytes in [Data([0xc3,0x28]),Data([97,0,98])] {
        check("invalid UTF8 or NUL product is malformed") {
            let f = try VSCodeMetadataFixture(); defer { f.clean() }; let app = try f.app()
            try bytes.write(to: app.appendingPathComponent("Contents/Resources/app/product.json"))
            let (result,row) = try await f.scan(app, allowedIssues: [.malformedMetadata]); let (observed,disposition) = try productFields(row)
            try expect(observed == nil && disposition == .malformed && result.completeness == .incomplete, "Invalid raw product accepted or hidden")
            try expect(row.claimedBundleIdentifier == "com.microsoft.VSCode", "Independent identity lost")
        }
    }
    check("product bytes share aggregate metadata budget with plist and Electron config") {
        let f = try VSCodeMetadataFixture(); defer { f.clean() }
        let bytes = Data(repeating: 32, count: 65_536)
        var apps: [URL] = []
        for index in 0..<260 {
            let app = try f.app(String(format: "Code%03d.app",index)); apps.append(app)
            try bytes.write(to: app.appendingPathComponent("Contents/Resources/app/product.json"))
            try bytes.write(to: app.appendingPathComponent("Contents/Resources/app-update.yml"))
        }
        let result = await LocalApplicationInventory(fixtureRoots: [f.root.path]).scan()
        try f.validate(result, apps: apps, allowedIssues: [.totalMetadataLimit], budgetCase: true)
        try expect(result.applications.contains { $0.metadataDisposition == .observed }, "product-metadata fixture setup failed: no real plist observed before budget exhaustion")
        var retained = 0, observedProducts = 0
        for row in result.applications {
            let (product,disposition) = try productFields(row)
            if let product { retained += product.count; observedProducts += 1; try expect(disposition == .observed, "Retained unobserved product") }
            retained += row.vendorMetadata.electronConfigBytes?.count ?? 0
        }
        try expect(result.completeness == .incomplete && result.issues.contains { $0.kind == .totalMetadataLimit }, "Shared budget did not refuse")
        try expect(observedProducts > 0 && observedProducts < 260 && retained < 16_777_216, "Product data bypassed shared budget or all positives refused")
    }

    check("product name replacement during descriptor read refuses retained bytes") {
        let f = try VSCodeMetadataFixture(); defer { f.clean() }; let app = try f.app()
        try Data("{}".utf8).write(to: app.appendingPathComponent("Contents/Resources/app/product.json"))
        let swap = ProductSwap(app: app)
        let result = await LocalApplicationInventory(fixtureRoots: [f.root.path], observer: { swap.observe($0) }).scan()
        try f.validate(result, apps: [app], allowedIssues: [.changedDuringScan])
        guard let row = result.applications.first else { throw CheckFailure(description: "product-metadata fixture setup failed: no race app") }
        // Baseline reaches missing fields only after exact scan setup succeeded.
        let (bytes, disposition) = try productFields(row)
        try swap.confirm()
        try expect(bytes == nil && disposition == .refused && result.completeness == .incomplete
                   && result.issues.contains { $0.kind == .changedDuringScan && $0.path == app.path },
                   "Changed product name retained bytes or was hidden as absence")
    }

}
