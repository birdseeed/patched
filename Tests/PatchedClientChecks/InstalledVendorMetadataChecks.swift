import Foundation
import Darwin
@_spi(Testing) import PatchedClient

// Independent physical fixtures and literal expectations. No product parser or
// limit constant constructs expected data. All writes stay under owned .build.
private struct VendorMetadataFixture {
    let base: URL
    let root: URL
    init() throws {
        guard var build = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw CheckFailure(description: "Vendor fixture executable path unavailable")
        }
        while build.lastPathComponent != ".build" {
            guard build.pathComponents.count > 1 else { throw CheckFailure(description: "Vendor fixtures require .build executable") }
            build.deleteLastPathComponent()
        }
        guard let physical = realpath(build.path, nil) else { throw CheckFailure(description: "Vendor fixture build path unavailable") }
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("vendor-fixture-" + UUID().uuidString)
        try expect(mkdir(base.path, 0o700) == 0, "Vendor fixture base was not exclusive")
        root = base.appendingPathComponent("Applications")
        try expect(mkdir(root.path, 0o700) == 0, "Vendor fixture root was not exclusive")
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func app(_ name: String = "Literal.app", feed: Any? = nil, binary: Bool = false, config: Data? = nil) throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": "Literal Vendor", "CFBundleIdentifier": "example.vendor", "CFBundleShortVersionString": "2.3", "CFBundleVersion": "47"]
        if let feed { plist["SUFeedURL"] = feed }
        let bytes = try PropertyListSerialization.data(fromPropertyList: plist, format: binary ? .binary : .xml, options: 0)
        try bytes.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let config { try config.write(to: app.appendingPathComponent("Contents/Resources/app-update.yml")) }
        return app
    }
    func scan() async -> LocalInventoryObservation { await LocalApplicationInventory(fixtureRoots: [root.path]).scan() }
}
private func vendorRow(_ result: LocalInventoryObservation, _ app: URL) throws -> LocalApplicationObservation {
    guard let row = result.applications.first(where: { $0.path == app.path }) else { throw CheckFailure(description: "Missing physical vendor fixture row") }
    try expect(row.authorityUnknown && !row.installationAllowed && row.vendorMetadata.authorityUnknown && !row.vendorMetadata.installationAllowed && !row.vendorMetadata.verificationAllowed && !row.vendorMetadata.publicationAllowed, "Vendor claims granted authority")
    return row
}
private func vendorIdentity(_ row: LocalApplicationObservation) throws {
    try expect(row.displayName == "Literal Vendor" && row.claimedBundleIdentifier == "example.vendor" && row.claimedShortVersion == "2.3" && row.claimedBuild == "47" && row.metadataDisposition == .observed, "Vendor observation changed independent app identity")
}
private func vendorIssue(_ result: LocalInventoryObservation, _ kind: LocalInventoryIssueKind) throws {
    try expect(result.completeness == .incomplete && result.issues.contains { $0.kind == kind }, "Unsafe vendor input did not report literal issue \(kind)")
}
@MainActor func registerInstalledVendorMetadataChecks() {
    for binary in [false, true] {
        check("installed vendor: \(binary ? "binary" : "XML") plist exposes literal HTTPS claim and exact unparsed config bytes") {
            let f = try VendorMetadataFixture(); defer { f.clean() }
            let bytes = Data("# retained comment\r\nprovider: custom\r\nurl: https://updates.example.invalid/raw\r\nunrecognised: [opaque, text]\r\n".utf8)
            let app = try f.app(feed: "https://updates.example.invalid/feed.xml?channel=preview", binary: binary, config: bytes)
            let r = await f.scan(), row = try vendorRow(r, app)
            try vendorIdentity(row)
            try expect(r.completeness == .complete && r.issues.isEmpty, "Safe vendor claims made inventory incomplete")
            try expect(row.vendorMetadata.sparkleFeedURL == "https://updates.example.invalid/feed.xml?channel=preview" && row.vendorMetadata.sparkleDisposition == .observed, "Literal SUFeedURL was not observed")
            try expect(row.vendorMetadata.electronConfigBytes == bytes && row.vendorMetadata.electronDisposition == .observed, "Exact config bytes were not retained")
        }
    }
    check("installed vendor: ordinary absence preserves complete inventory and claimed identity") {
        let f = try VendorMetadataFixture(); defer { f.clean() }
        let app = try f.app()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources"))
        let r = await f.scan(), row = try vendorRow(r, app)
        try vendorIdentity(row)
        try expect(r.completeness == .complete && r.issues.isEmpty, "Absent optional vendor data became an issue")
        try expect(row.vendorMetadata.sparkleFeedURL == nil && row.vendorMetadata.electronConfigBytes == nil && row.vendorMetadata.sparkleDisposition == .unavailable && row.vendorMetadata.electronDisposition == .unavailable, "Absent metadata invented an observation")
    }
    for (label, feed) in [("wrong type", 9 as Any), ("http", "http://updates.example.invalid/f"), ("file", "file:///tmp/feed"), ("relative", "/feed.xml"), ("credentials", "https://user:pass@updates.example.invalid/f"), ("fragment", "https://updates.example.invalid/f#part"), ("control", "https://updates.example.invalid/f\n"), ("oversize", "https://updates.example.invalid/" + String(repeating: "a", count: 2049))] {
        check("installed vendor: unsafe SUFeedURL \(label) is malformed without losing app identity") {
            let f = try VendorMetadataFixture(); defer { f.clean() }
            let app = try f.app(feed: feed, config: Data("opaque valid UTF8".utf8))
            let r = await f.scan(), row = try vendorRow(r, app)
            try vendorIdentity(row); try vendorIssue(r, .malformedMetadata)
            try expect(row.vendorMetadata.sparkleFeedURL == nil && row.vendorMetadata.sparkleDisposition == .malformed, "Unsafe SUFeedURL accepted or hidden as absent")
            try expect(row.vendorMetadata.electronConfigBytes == Data("opaque valid UTF8".utf8) && row.vendorMetadata.electronDisposition == .observed, "Malformed feed discarded unrelated valid config")
        }
    }
    check("installed vendor: HTTPS URL accepts exactly 2048 UTF8 bytes and config accepts exactly 65536 bytes") {
        let f = try VendorMetadataFixture(); defer { f.clean() }
        let prefix = "https://updates.example.invalid/"
        let feed = prefix + String(repeating: "a", count: 2048 - prefix.utf8.count)
        let bytes = Data(repeating: 32, count: 65_536)
        let app = try f.app(feed: feed, config: bytes)
        let r = await f.scan(), row = try vendorRow(r, app)
        try expect(r.completeness == .complete && row.vendorMetadata.sparkleFeedURL == feed && row.vendorMetadata.sparkleDisposition == .observed && row.vendorMetadata.electronConfigBytes == bytes && row.vendorMetadata.electronDisposition == .observed, "Exact literal vendor bounds refused")
    }
    for (label, bytes) in [("oversize", Data(repeating: 32, count: 65_537)), ("invalid UTF8", Data([0xc3, 0x28])), ("NUL", Data([97, 0, 98]))] {
        check("installed vendor: \(label) config is refused while valid feed and identity survive") {
            let f = try VendorMetadataFixture(); defer { f.clean() }
            let app = try f.app(feed: "https://updates.example.invalid/f", config: bytes)
            let r = await f.scan(), row = try vendorRow(r, app)
            try vendorIdentity(row)
            try expect(r.completeness == .incomplete && !r.issues.isEmpty, "Invalid config failure was silent")
            try expect(row.vendorMetadata.electronConfigBytes == nil && [.malformed, .refused].contains(row.vendorMetadata.electronDisposition), "Invalid config was observed or hidden as absent")
            try expect(row.vendorMetadata.sparkleFeedURL == "https://updates.example.invalid/f" && row.vendorMetadata.sparkleDisposition == .observed, "Bad config discarded valid feed")
        }
    }
    for boundary in ["config", "resources", "contents"] {
        check("installed vendor: symlink \(boundary) refuses vendor data without following target") {
            let f = try VendorMetadataFixture(); defer { f.clean() }
            let app = try f.app(config: Data("provider: generic\n".utf8))
            let path = app.appendingPathComponent(boundary == "config" ? "Contents/Resources/app-update.yml" : boundary == "resources" ? "Contents/Resources" : "Contents")
            let saved = f.base.appendingPathComponent("Saved")
            try FileManager.default.moveItem(at: path, to: saved)
            try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: saved.path)
            let r = await f.scan(), row = try vendorRow(r, app)
            try vendorIssue(r, .unsafePath)
            try expect(row.vendorMetadata.electronConfigBytes == nil && row.vendorMetadata.electronDisposition == .refused, "Symlink vendor data followed or hidden as absent")
            if boundary != "contents" { try vendorIdentity(row) }
        }
    }
    for kind in ["fifo", "directory", "hardlink"] {
        check("installed vendor: \(kind) config refuses without blocking") {
            let f = try VendorMetadataFixture(); defer { f.clean() }
            let app = try f.app(), path = app.appendingPathComponent("Contents/Resources/app-update.yml")
            if kind == "fifo" { try expect(mkfifo(path.path, 0o600) == 0, "FIFO fixture creation failed") }
            else if kind == "directory" { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            else {
                let saved = f.base.appendingPathComponent("Other.yml"); try Data("opaque".utf8).write(to: saved)
                try expect(link(saved.path, path.path) == 0, "Hardlink fixture creation failed")
            }
            let r = await f.scan(), row = try vendorRow(r, app)
            try vendorIdentity(row); try vendorIssue(r, .unsafePath)
            try expect(row.vendorMetadata.electronConfigBytes == nil && row.vendorMetadata.electronDisposition == .refused, "Special/hardlinked config accepted or hidden as absent")
        }
    }
    check("installed vendor: only exact fixed app-update.yml path is read; app copies preserve order") {
        let f = try VendorMetadataFixture(); defer { f.clean() }
        let z = try f.app("Z.app"), a = try f.app("A.app")
        for relative in ["Contents/Resources/app-update.yaml", "Contents/app-update.yml", "app-update.yml", "Contents/Resources/Nested/app-update.yml"] {
            let path = a.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("provider: do-not-read\n".utf8).write(to: path)
        }
        let r = await f.scan()
        try expect(r.applications.map(\.path) == [a.path, z.path] && r.completeness == .complete && r.issues.isEmpty, "Alternate paths traversed or original row order/count changed")
        for app in [a, z] {
            let row = try vendorRow(r, app); try vendorIdentity(row)
            try expect(row.vendorMetadata.electronConfigBytes == nil && row.vendorMetadata.electronDisposition == .unavailable, "Alternate filename supplied vendor data")
        }
    }
    check("installed vendor: config reads share the existing sixteen MiB metadata budget") {
        let f = try VendorMetadataFixture(); defer { f.clean() }
        var plistSizes: [String: Int] = [:]
        for index in 0..<18 {
            let app = try f.app(String(format: "A%02d.app", index), config: Data(repeating: 32, count: 65_536))
            let path = app.appendingPathComponent("Contents/Info.plist")
            var bytes = try Data(contentsOf: path)
            try expect(bytes.count < 900_000, "Unexpected aggregate fixture plist size")
            bytes.append(Data(repeating: 32, count: 900_000 - bytes.count))
            try bytes.write(to: path)
            plistSizes[app.path] = 900_000
        }
        let r = await f.scan()
        try vendorIssue(r, .totalMetadataLimit)
        try expect(r.applications.count == 18, "Metadata exhaustion erased safe physical rows")
        var acceptedBytes = 0
        for row in r.applications {
            if row.metadataDisposition == .observed { acceptedBytes += plistSizes[row.path] ?? 0 }
            acceptedBytes += row.vendorMetadata.electronConfigBytes?.count ?? 0
        }
        try expect(acceptedBytes <= 16_777_216, "Plist and vendor config observations exceeded combined literal byte bound")
    }
    for ancestor in [false, true] {
        check("installed vendor: symlink \(ancestor ? "ancestor" : "root") never supplies vendor data") {
            let f = try VendorMetadataFixture(); defer { f.clean() }
            _ = try f.app(feed: "https://updates.example.invalid/f", config: Data("opaque".utf8))
            let path = f.base.appendingPathComponent("Linked")
            try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: ancestor ? f.base.path : f.root.path)
            let requested = ancestor ? path.appendingPathComponent("Applications").path : path.path
            let r = await LocalApplicationInventory(fixtureRoots: [requested]).scan()
            try expect(r.applications.isEmpty && r.completeness == .incomplete && r.roots.first?.status == .refused, "Symlink root ancestry supplied vendor rows")
            try vendorIssue(r, .unsafePath)
        }
    }
    for boundary in ["plist", "contents", "bundle", "root"] {
        check("installed vendor: actual \(boundary) replacement invalidates every vendor observation") {
            let f = try VendorMetadataFixture(); defer { f.clean() }
            let app = try f.app(feed: "https://updates.example.invalid/f", config: Data("opaque".utf8))
            let target = boundary == "root" ? f.root : boundary == "bundle" ? app : app.appendingPathComponent(boundary == "contents" ? "Contents" : "Contents/Info.plist")
            let saved = f.base.appendingPathComponent("Swapped")
            let scanner = LocalApplicationInventory(fixtureRoots: [f.root.path], observer: { event in
                switch event {
                case .beforeProductMetadataRead: break
                case .beforeIconRead, .beforeIconDecode: break
                case .beforeMetadataRead(let path):
                    guard path == app.path else { return }
                    do {
                        try FileManager.default.moveItem(at: target, to: saved)
                        if boundary == "plist" { try Data("replacement".utf8).write(to: target) }
                        else { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                    } catch { /* Physical saved target is independently required below. */ }
                }
            })
            let r = await scanner.scan()
            try expect(FileManager.default.fileExists(atPath: saved.path), "Replacement observer did not perform real namespace mutation")
            try vendorIssue(r, .changedDuringScan)
            for row in r.applications {
                try expect(row.claimedBundleIdentifier == nil && row.vendorMetadata.sparkleFeedURL == nil && row.vendorMetadata.electronConfigBytes == nil && row.vendorMetadata.sparkleDisposition != .observed && row.vendorMetadata.electronDisposition != .observed, "Invalidated namespace retained vendor/identity observation")
            }
        }
    }
}
