import Foundation
import Darwin
@_spi(Testing) import PatchedClient
import UpdateSources

// Independent physical fixtures. Expected facts below are literal, never generated
// by the inventory implementation or its public limit constants.
private struct InventoryFixture {
    let base: URL
    let root: URL
    init() throws {
        base = try newDirectory("inventory-fixture")
        root = base.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func app(_ relative: String, metadata: [String: Any]? = ["CFBundleName": "Literal App", "CFBundleIdentifier": "example.literal", "CFBundleShortVersionString": "2.3", "CFBundleVersion": "47"], binary: Bool = false) throws -> URL {
        let app = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if let metadata {
            let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: binary ? .binary : .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        return app
    }
    func scan() async -> LocalInventoryObservation { await LocalApplicationInventory(fixtureRoots: [root.path]).scan() }
}
private func inventoryIncomplete(_ result: LocalInventoryObservation, _ kind: LocalInventoryIssueKind) throws {
    try expect(result.completeness == .incomplete, "Limit or refusal became a complete/available empty result: \(result.completeness)")
    try expect(result.issues.contains { $0.kind == kind }, "Missing literal issue \(kind): \(result.issues)")
}
private func inventoryPhysical(_ path: String) throws -> (UInt64, UInt64) {
    var value = stat()
    try expect(lstat(path, &value) == 0, "Fixture physical identity unavailable")
    return (UInt64(value.st_dev), UInt64(value.st_ino))
}
@MainActor func registerLocalInventoryChecks() {
    check("inventory: empty physical root is explicitly scanned, complete and fixture labelled") {
        let f = try InventoryFixture(); defer { f.clean() }
        let r = await f.scan()
        try expect(r.provenance == .fixture && r.completeness == .complete, "Empty fixture was not complete and fixture-labelled")
        try expect(r.roots.count == 1 && r.roots[0].path == f.root.path && r.roots[0].scope == .fixture && r.roots[0].status == .scanned, "Root scope/status was not observed")
        try expect(r.applications.isEmpty && r.issues.isEmpty && !r.installationAllowed && r.authorityUnknown, "Empty scan invented evidence or authority")
    }
    check("inventory: XML and binary metadata are literal untrusted observations; duplicate copies remain separate in byte order") {
        let f = try InventoryFixture(); defer { f.clean() }
        let z = try f.app("Z.app", binary: true), a = try f.app("A.app")
        let identity = try inventoryPhysical(a.path)
        let r = await f.scan()
        try expect(r.completeness == .complete && r.applications.map(\.path) == [a.path, z.path], "Duplicate IDs collapsed or row order changed")
        try expect(r.applications.count == 2, "Expected two physical app copies")
        for row in r.applications {
            try expect(row.displayName == "Literal App" && row.claimedBundleIdentifier == "example.literal" && row.claimedShortVersion == "2.3" && row.claimedBuild == "47" && row.metadataDisposition == .observed, "Literal XML/binary metadata not retained")
            try expect(row.authorityUnknown && !row.installationAllowed, "Observed metadata became authority")
        }
        try expect(r.applications[0].physicalIdentity.device == identity.0 && r.applications[0].physicalIdentity.inode == identity.1, "Physical identity is not the actual bundle")
    }
    // An iPhone/iPad app from the App Store: Wrapper/<Name>.app holds the real Info.plist; there is no Contents folder.
    func wrappedFixture(_ f: InventoryFixture, _ name: String, inner: [String] = ["WiFiman.app"], id: String = "com.ubnt.wifiman",
                        itunes: [String: Any]? = nil, writeItunes: Bool = true) throws -> URL {
        let app = f.root.appendingPathComponent(name)
        let wrapper = app.appendingPathComponent("Wrapper")
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("WrappedBundle"), withIntermediateDirectories: true)
        for folder in inner {
            let dir = wrapper.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "WiFiman", "CFBundleShortVersionString": "1.37.1", "CFBundleVersion": "202605136"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: dir.appendingPathComponent("Info.plist"))
        }
        if writeItunes {
            let record = itunes ?? ["itemId": 1385561119, "bundleShortVersionString": "1.37.1", "softwareVersionBundleId": id, "kind": "software", "title": "WiFiman"]
            try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0).write(to: wrapper.appendingPathComponent("iTunesMetadata.plist"))
        }
        return app
    }
    check("inventory: a wrapped iPhone/iPad app is read from Wrapper and flagged; a normal app is not") {
        let f = try InventoryFixture(); defer { f.clean() }
        let wrapped = try wrappedFixture(f, "WiFiman.app")
        let normal = try f.app("Normal.app")
        let r = await f.scan()
        try expect(r.applications.count == 2 && r.completeness == .complete, "scan: \(r.applications.count) \(r.issues)")
        guard let w = r.applications.first(where: { $0.path == wrapped.path }) else { throw CheckFailure(description: "wrapped row missing") }
        try expect(w.isWrappedIOSApp && w.claimedBundleIdentifier == "com.ubnt.wifiman" && w.claimedShortVersion == "1.37.1"
                   && w.claimedBuild == "202605136" && w.displayName == "WiFiman" && w.metadataDisposition == .observed, "wrapped row: \(w)")
        try expect(!w.installationAllowed && w.authorityUnknown, "wrapped app gained authority")
        try expect(r.applications.first(where: { $0.path == normal.path })?.isWrappedIOSApp == false, "normal app flagged")
    }
    check("inventory: a wrapped app with a symlinked Wrapper, two inner apps, a symlinked inner app, a mismatched ID or no iTunes record is refused") {
        let f = try InventoryFixture(); defer { f.clean() }
        // Symlinked Wrapper.
        let real = try wrappedFixture(f, "Real.app")
        let linked = f.root.appendingPathComponent("Linked.app")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("Wrapper"), withDestinationURL: real.appendingPathComponent("Wrapper"))
        _ = try wrappedFixture(f, "Two.app", inner: ["A.app", "B.app"])
        // An inner "app" that is a symlink to a real one.
        let sym = try wrappedFixture(f, "Sym.app", inner: [])
        try FileManager.default.createSymbolicLink(at: sym.appendingPathComponent("Wrapper/Evil.app"), withDestinationURL: real.appendingPathComponent("Wrapper/WiFiman.app"))
        _ = try wrappedFixture(f, "Mismatch.app", itunes: ["softwareVersionBundleId": "com.someone.else", "itemId": 1])
        _ = try wrappedFixture(f, "NoItunes.app", writeItunes: false)
        let r = await f.scan()
        for name in ["Linked", "Two", "Sym", "Mismatch", "NoItunes"] {
            guard let row = r.applications.first(where: { $0.path.hasSuffix("/\(name).app") }) else { throw CheckFailure(description: "\(name) missing") }
            try expect(!row.isWrappedIOSApp && row.claimedBundleIdentifier == nil && row.claimedShortVersion == nil && row.metadataDisposition != .observed,
                       "\(name) was accepted: \(row)")
        }
        try expect(r.applications.first(where: { $0.path == real.path })?.isWrappedIOSApp == true, "the genuine one was lost")
        try expect(r.completeness == .incomplete, "refusals were not reported")
    }

    check("inventory: display-name fallback, missing mandatory claims, wrong types and malformed plist stay observable") {
        let f = try InventoryFixture(); defer { f.clean() }
        _ = try f.app("Missing.app", metadata: nil)
        _ = try f.app("Partial.app", metadata: ["CFBundleName": "Partial"])
        _ = try f.app("Wrong.app", metadata: ["CFBundleIdentifier": 9, "CFBundleVersion": ["bad"]])
        let bad = try f.app("Broken.app", metadata: nil)
        try Data("this is not a plist".utf8).write(to: bad.appendingPathComponent("Contents/Info.plist"))
        let r = await f.scan()
        try expect(r.applications.count == 4, "Unsafe metadata erased safe physical apps")
        guard let missing = r.applications.first(where: { $0.path.hasSuffix("/Missing.app") }), let partial = r.applications.first(where: { $0.path.hasSuffix("/Partial.app") }), let wrong = r.applications.first(where: { $0.path.hasSuffix("/Wrong.app") }), let broken = r.applications.first(where: { $0.path.hasSuffix("/Broken.app") }) else { throw CheckFailure(description: "Missing independently named metadata rows") }
        try expect(missing.displayName == "Missing" && missing.metadataDisposition == .unavailable, "Missing plist claims success")
        try expect(partial.claimedBundleIdentifier == nil && partial.claimedShortVersion == nil && partial.claimedBuild == nil && partial.metadataDisposition != .observed, "Missing mandatory fields claim successful metadata")
        try expect(wrong.claimedBundleIdentifier == nil && wrong.claimedBuild == nil && wrong.metadataDisposition == .malformed, "Wrong plist types accepted")
        try expect(broken.metadataDisposition == .malformed, "Invalid bytes accepted")
    }
    check("inventory: SUPublicEDKey presence, of any value, marks the app as pinning a Sparkle key") {
        let f = try InventoryFixture(); defer { f.clean() }
        let base: [String: Any] = ["CFBundleName": "K", "CFBundleIdentifier": "example.k", "CFBundleShortVersionString": "1", "CFBundleVersion": "2"]
        _ = try f.app("Absent.app", metadata: base)
        _ = try f.app("Str.app", metadata: base.merging(["SUPublicEDKey": "abc="]) { $1 })
        _ = try f.app("Empty.app", metadata: base.merging(["SUPublicEDKey": ""]) { $1 })
        _ = try f.app("NonStr.app", metadata: base.merging(["SUPublicEDKey": 7]) { $1 })
        let r = await f.scan()
        func key(_ n: String) throws -> String? {
            guard let a = r.applications.first(where: { $0.path.hasSuffix("/\(n).app") }) else { throw CheckFailure(description: "missing \(n)") }
            let mapped = InstalledApp(observation: a)
            try expect(mapped.sparklePublicEDKey == a.vendorMetadata.sparklePublicEDKey, "\(n): key lost mapping into InstalledApp")
            return a.vendorMetadata.sparklePublicEDKey
        }
        // Same reading as the installer (Locations.swift): absent is nil, a string is kept, any other type is "".
        try expect(try key("Absent") == nil && key("Str") == "abc=" && key("Empty") == "" && key("NonStr") == "", "key capture wrong")
        let absent = try r.applications.first { $0.path.hasSuffix("/Absent.app") }.map(InstalledApp.init(observation:))
        try expect(absent?.pinsSparkleKey == false, "absent key must not pin")
    }
    check("inventory: LSBackgroundOnly marks background-only helpers, and only a truthy value does") {
        let f = try InventoryFixture(); defer { f.clean() }
        let base: [String: Any] = ["CFBundleName": "B", "CFBundleIdentifier": "example.b", "CFBundleShortVersionString": "1", "CFBundleVersion": "2"]
        func with(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { $1 } }
        _ = try f.app("Absent.app", metadata: base)
        _ = try f.app("BoolTrue.app", metadata: with(["LSBackgroundOnly": true]))
        _ = try f.app("BoolFalse.app", metadata: with(["LSBackgroundOnly": false]))
        _ = try f.app("StrYes.app", metadata: with(["LSBackgroundOnly": "YES"]))
        _ = try f.app("StrNo.app", metadata: with(["LSBackgroundOnly": "no"]))
        _ = try f.app("UIElement.app", metadata: with(["LSUIElement": true]))
        let r = await f.scan()
        func flag(_ n: String) throws -> Bool {
            guard let a = r.applications.first(where: { $0.path.hasSuffix("/\(n).app") }) else { throw CheckFailure(description: "missing \(n)") }
            let mapped = InstalledApp(observation: a)
            try expect(mapped.isBackgroundOnly == a.vendorMetadata.backgroundOnly, "\(n): flag lost mapping into InstalledApp")
            return a.vendorMetadata.backgroundOnly
        }
        try expect(try flag("BoolTrue") && flag("StrYes"), "truthy LSBackgroundOnly not captured")
        try expect(try !flag("Absent") && !flag("BoolFalse") && !flag("StrNo") && !flag("UIElement"), "non-background app flagged background-only")
    }
    check("inventory: publisher and management-looking plist keys never confer authority") {
        let f = try InventoryFixture(); defer { f.clean() }
        let claims: [String: Any] = ["CFBundleName": "Claims", "CFBundleIdentifier": "example.claims", "CFBundleShortVersionString": "1", "CFBundleVersion": "2", "Publisher": "Apple", "TeamIdentifier": "TRUST-ME", "Architecture": "arm64", "Homebrew": true, "UpdateEligible": true, "InstallationAllowed": true]
        let a = try f.app("ClaimA.app", metadata: claims), b = try f.app("ClaimB.app", metadata: claims)
        let r = await f.scan()
        try expect(r.applications.map(\.path) == [a.path, b.path] && r.applications.allSatisfy { $0.authorityUnknown && !$0.installationAllowed && $0.claimedBundleIdentifier == "example.claims" } && r.authorityUnknown && !r.installationAllowed, "Untrusted arbitrary keys became identity/installation authority or collapsed copies")
    }
    check("inventory: no nested app or hidden-directory traversal") {
        let f = try InventoryFixture(); defer { f.clean() }
        let outer = try f.app("Outer.app")
        _ = try f.app("Outer.app/Contents/Hidden.app")
        _ = try f.app(".hidden/Secret.app")
        let r = await f.scan()
        try expect(r.applications.map(\.path) == [outer.path], "Traversed an app bundle or hidden directory")
    }
    check("inventory: missing and regular-file roots are distinct from scanned empty roots") {
        let f = try InventoryFixture(); defer { f.clean() }
        let missing = f.base.appendingPathComponent("Absent")
        let absent = await LocalApplicationInventory(fixtureRoots: [missing.path]).scan()
        try expect(absent.roots.count == 1 && absent.roots[0].status == .absent && absent.applications.isEmpty, "Missing root was not explicit absent")
        let file = f.base.appendingPathComponent("FileRoot"); try Data().write(to: file)
        let refused = await LocalApplicationInventory(fixtureRoots: [file.path]).scan()
        try expect(refused.completeness != .complete && refused.roots.count == 1 && refused.roots[0].status == .refused, "File root became complete empty inventory")
    }
    check("inventory: unreadable root and child remain incomplete while unaffected rows survive") {
        let f = try InventoryFixture(); defer { f.clean() }
        let unreadable = try f.app("Unreadable.app"), good = try f.app("Good.app")
        try expect(chmod(unreadable.path, 0o000) == 0, "Could not protect fixture child")
        defer { _ = chmod(unreadable.path, 0o700) }
        let child = await f.scan()
        try expect(child.completeness == .incomplete && child.applications.contains { $0.path == good.path && $0.metadataDisposition == .observed }, "Unreadable child hid unaffected observation or claimed complete")
        try expect(child.applications.filter { $0.path == unreadable.path }.allSatisfy { $0.metadataDisposition != .observed && $0.claimedBundleIdentifier == nil }, "Unreadable child supplied metadata")
        let g = try InventoryFixture(); defer { g.clean() }
        try expect(chmod(g.root.path, 0o000) == 0, "Could not protect fixture root")
        defer { _ = chmod(g.root.path, 0o700) }
        let root = await g.scan()
        try expect(root.completeness != .complete && root.applications.isEmpty && root.roots.first?.status != .scanned && !root.issues.isEmpty, "Unreadable root became scanned empty inventory")
    }
    check("inventory: symlink root and symlink ancestor refuse before traversal") {
        let f = try InventoryFixture(); defer { f.clean() }
        _ = try f.app("Escape.app")
        let link = f.base.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: f.root.path)
        let ancestor = f.base.appendingPathComponent("Ancestor")
        try FileManager.default.createSymbolicLink(atPath: ancestor.path, withDestinationPath: f.base.path)
        for path in [link.path, ancestor.appendingPathComponent("Applications").path] {
            let r = await LocalApplicationInventory(fixtureRoots: [path]).scan()
            try expect(r.applications.isEmpty && r.completeness != .complete && r.roots.first?.status == .refused, "Symlink root/ancestor was followed")
        }
    }
    check("inventory: symlink child directory and bundle are never followed") {
        let f = try InventoryFixture(); defer { f.clean() }
        let outside = f.base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("Escape.app/Contents"), withIntermediateDirectories: true)
        for name in ["LinkedDirectory", "Linked.app"] { try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent(name).path, withDestinationPath: outside.path) }
        let r = await f.scan()
        try expect(r.applications.isEmpty && r.completeness == .incomplete, "Symlink child/bundle became an observed app")
    }
    check("inventory: symlink Contents and Info.plist cannot supply metadata") {
        for contents in [true, false] {
            let f = try InventoryFixture(); defer { f.clean() }
            let app = try f.app("Linked.app"), original = app.appendingPathComponent(contents ? "Contents" : "Contents/Info.plist")
            let saved = f.base.appendingPathComponent(contents ? "SavedContents" : "Saved.plist")
            try FileManager.default.moveItem(at: original, to: saved)
            try FileManager.default.createSymbolicLink(atPath: original.path, withDestinationPath: saved.path)
            let r = await f.scan()
            try expect(r.completeness == .incomplete && r.applications.count == 1 && r.applications[0].metadataDisposition != .observed && r.applications[0].claimedBundleIdentifier == nil, "Followed metadata symlink")
        }
    }
    check("inventory: FIFO and directory Info.plist refuse without blocking or parsing") {
        for fifo in [true, false] {
            let f = try InventoryFixture(); defer { f.clean() }
            let app = try f.app("Special.app", metadata: nil), path = app.appendingPathComponent("Contents/Info.plist")
            if fifo { try expect(mkfifo(path.path, 0o600) == 0, "Could not create exclusive FIFO fixture") }
            else { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            let r = await f.scan()
            try expect(r.completeness == .incomplete && r.applications.count == 1 && r.applications[0].metadataDisposition != .observed, "Nonregular metadata was accepted")
        }
    }
    check("inventory: a valid plist at exactly one MiB remains observable") {
        let f = try InventoryFixture(); defer { f.clean() }
        let app = try f.app("Exact.app")
        let plist = app.appendingPathComponent("Contents/Info.plist")
        var bytes = try Data(contentsOf: plist)
        try expect(bytes.count < 1_048_576, "Fixture plist unexpectedly oversized")
        bytes.append(Data(repeating: 32, count: 1_048_576 - bytes.count))
        try bytes.write(to: plist)
        let r = await f.scan()
        try expect(r.completeness == .complete && r.applications.count == 1 && r.applications[0].metadataDisposition == .observed && r.applications[0].claimedBundleIdentifier == "example.literal", "Exact one MiB valid plist refused")
    }
    check("inventory: oversized metadata refuses at literal one MiB") {
        let f = try InventoryFixture(); defer { f.clean() }
        let app = try f.app("Large.app", metadata: nil)
        try Data(repeating: 120, count: 1_048_577).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let r = await f.scan(); try inventoryIncomplete(r, .plistLimit)
        try expect(r.applications.count == 1 && r.applications[0].metadataDisposition != .observed, "Oversized metadata was parsed")
    }
    check("inventory: aggregate metadata reads are bounded at literal sixteen MiB") {
        let f = try InventoryFixture(); defer { f.clean() }
        for i in 0..<20 { _ = try f.app(String(format: "A%02d.app", i), metadata: ["CFBundleName": "Large", "CFBundleIdentifier": "example.large", "CFBundleShortVersionString": "1", "CFBundleVersion": "1", "UnobservedPadding": String(repeating: "x", count: 900_000)]) }
        let r = await f.scan(); try inventoryIncomplete(r, .totalMetadataLimit)
        try expect(r.applications.filter { $0.metadataDisposition == .observed }.count <= 18, "Read/accepted more than the aggregate metadata budget")
    }
    check("inventory: application retention and issue retention have literal fixed caps") {
        let f = try InventoryFixture(); defer { f.clean() }
        for i in 0..<513 { _ = try f.app(String(format: "A%03d.app", i)) }
        let r = await f.scan(); try inventoryIncomplete(r, .applicationLimit)
        try expect(r.applications.count == 512, "Retained app cap is not exactly 512")
        let g = try InventoryFixture(); defer { g.clean() }
        for i in 0..<520 { try FileManager.default.createSymbolicLink(atPath: g.root.appendingPathComponent("Link\(i)").path, withDestinationPath: "/nonexistent-local-inventory") }
        let q = await g.scan(); try inventoryIncomplete(q, .issueLimit)
        try expect(q.issues.count == 512 && q.applications.isEmpty, "Issue cap is not exactly 512")
    }
    check("inventory: every directory entry counts toward the literal 8192 bound") {
        let f = try InventoryFixture(); defer { f.clean() }
        for i in 0..<8193 { try Data().write(to: f.root.appendingPathComponent("file\(i)")) }
        let r = await f.scan(); try inventoryIncomplete(r, .entryLimit)
        try expect(r.applications.isEmpty, "Ordinary files became apps")
    }
    check("inventory: traversal stops at literal depth four and reports truncation") {
        let f = try InventoryFixture(); defer { f.clean() }
        _ = try f.app("one/two/three/four/Fifth.app")
        let neighbour = try f.app("one/two/three/Fourth.app")
        let r = await f.scan(); try inventoryIncomplete(r, .depthLimit)
        try expect(r.applications.map(\.path) == [neighbour.path], "Depth truncation lost the valid neighbour or traversed deeper than four")
    }
    check("inventory: nested apps within depth four remain visible and exact field bound is accepted") {
        let f = try InventoryFixture(); defer { f.clean() }
        let app = try f.app("one/two/three/Fourth.app", metadata: ["CFBundleName": String(repeating: "x", count: 1024), "CFBundleIdentifier": "example.boundary", "CFBundleShortVersionString": "1", "CFBundleVersion": "1"])
        let r = await f.scan()
        try expect(r.completeness == .complete && r.applications.map(\.path) == [app.path], "Valid depth-four app was omitted")
        try expect(r.applications[0].displayName == String(repeating: "x", count: 1024) && r.applications[0].metadataDisposition == .observed, "Exact field bound was rejected")
    }
    check("inventory: relative fixture root refuses without interpreting the working directory") {
        let r = await LocalApplicationInventory(fixtureRoots: ["relative/Applications"]).scan()
        try expect(r.completeness != .complete && r.applications.isEmpty && r.roots.first?.status == .refused, "Relative root was accepted")
    }
    check("inventory: overlong and control-bearing claimed fields are never displayed as valid metadata") {
        let f = try InventoryFixture(); defer { f.clean() }
        _ = try f.app("Fields.app", metadata: ["CFBundleName": "Bad\nName", "CFBundleIdentifier": String(repeating: "x", count: 1025), "CFBundleShortVersionString": "1\u{00}", "CFBundleVersion": "1"], binary: true)
        let r = await f.scan()
        try expect(r.applications.count == 1, "Invalid fields erased physical row")
        let a = r.applications[0]
        try expect(a.displayName == "Fields" && a.claimedBundleIdentifier == nil && a.claimedShortVersion == nil && a.metadataDisposition != .observed, "Invalid/overlong fields leaked as trusted display metadata")
        try expect(a.displayName.utf8.count <= 1024 && !a.displayName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, "Unsafe displayed text")
    }
    check("inventory: overlong requested path refuses before filesystem access") {
        let f = try InventoryFixture(); defer { f.clean() }
        let r = await LocalApplicationInventory(fixtureRoots: [f.root.path + "/" + String(repeating: "x", count: 4097)]).scan()
        try expect(r.completeness != .complete && r.applications.isEmpty && r.issues.contains { $0.kind == .pathLimit }, "Overlong path did not refuse explicitly")
        try expect(r.issues.allSatisfy { ($0.path?.utf8.count ?? 0) <= 4096 }, "Issue echoed unbounded path")
    }
    check("inventory: entries added to the root, its parent, the bundle or Contents mid-scan do not make the scan incomplete") {
        let f = try InventoryFixture(); defer { f.clean() }
        let app = try f.app("Busy.app")
        let folders = [f.base, f.root, app, app.appendingPathComponent("Contents")]
        let scanner = LocalApplicationInventory(fixtureRoots: [f.root.path], observer: { event in
            guard case .beforeMetadataRead(let path) = event, path == app.path else { return }
            // Other programs writing beside the scan: every folder on the path gains and loses an entry, so its
            // times, size and link count change while its identity does not.
            for folder in folders {
                let extra = folder.appendingPathComponent("extra-entry")
                try? FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
                try? FileManager.default.removeItem(at: extra)
                try? Data("x".utf8).write(to: folder.appendingPathComponent("extra-file"))
            }
        })
        let r = await scanner.scan()
        try expect(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("extra-file").path), "observer was not invoked at the metadata read")
        try expect(r.completeness == .complete && r.issues.isEmpty, "a busy ancestor made the scan incomplete: \(r.completeness) \(r.issues)")
        try expect(r.applications.map(\.displayName) == ["Literal App"], "apps: \(r.applications.map(\.displayName))")
    }
    check("inventory: replacing bundle, Contents or plist after identity capture refuses changed metadata") {
        for boundary in ["bundle", "contents", "plist"] {
            let f = try InventoryFixture(); defer { f.clean() }
            let app = try f.app("Race.app")
            let target = boundary == "bundle" ? app : app.appendingPathComponent(boundary == "contents" ? "Contents" : "Contents/Info.plist")
            let saved = f.base.appendingPathComponent("Saved-" + boundary)
            let scanner = LocalApplicationInventory(fixtureRoots: [f.root.path], observer: { event in
                switch event {
                case .beforeProductMetadataRead: break
                case .beforeIconRead, .beforeIconDecode: break
                case .beforeMetadataRead(let path):
                    guard path == app.path else { return }
                    // Deterministic actual namespace replacement. Never returns scanner data.
                    do {
                        try FileManager.default.moveItem(at: target, to: saved)
                        if boundary == "plist" {
                            let bytes = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Replacement", "CFBundleIdentifier": "example.replacement", "CFBundleShortVersionString": "9", "CFBundleVersion": "9"], format: .xml, options: 0)
                            try bytes.write(to: target)
                        } else {
                            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                        }
                    } catch { /* Verified below through the physical saved fixture. */ }
                }
            })
            let r = await scanner.scan()
            try expect(FileManager.default.fileExists(atPath: saved.path), "Race observer was not invoked at the physical read boundary")
            try inventoryIncomplete(r, .changedDuringScan)
            try expect(r.applications.allSatisfy { $0.metadataDisposition != .observed && $0.claimedBundleIdentifier == nil }, "Changed namespace supplied accepted metadata")
        }
    }
    check("inventory: generations advance in one session and prior immutable results survive filesystem changes") {
        let f = try InventoryFixture(); defer { f.clean() }
        let app = try f.app("First.app")
        let scanner = LocalApplicationInventory(fixtureRoots: [f.root.path])
        let before = Date(), first = await scanner.scan(), middle = Date()
        try FileManager.default.removeItem(at: app)
        _ = try f.app("Second.app", metadata: ["CFBundleName": "Second", "CFBundleIdentifier": "example.second", "CFBundleShortVersionString": "7", "CFBundleVersion": "8"])
        let second = await scanner.scan(), after = Date()
        try expect(first.generation == 1 && second.generation == 2 && first.sessionID == second.sessionID, "No session-owned monotonic generation")
        try expect(first.applications.map(\.displayName) == ["Literal App"] && second.applications.map(\.displayName) == ["Second"], "Old snapshot mutated or new scan reused stale rows")
        try expect(first.startedAt >= before && first.finishedAt <= middle && first.startedAt <= first.finishedAt && second.startedAt >= middle && second.finishedAt <= after && second.startedAt <= second.finishedAt, "Observed wall times not bracketed by actual calls")
        let other = await LocalApplicationInventory(fixtureRoots: [f.root.path]).scan()
        try expect(other.sessionID != first.sessionID && other.generation == 1, "Different scanner shares session/generation")
    }
    check("inventory: source boundaries retain explicit scan, fixed bounds and no app composition or execution") {
        let scanner = code(try source("Sources/PatchedClient/LocalApplicationInventory.swift"))
        let dto = code(try source("Sources/PatchedClient/LocalInventoryObservation.swift"))
        for forbidden in ["URLSession", "NSURLConnection", "NSWorkspace", "NSRunningApplication", "Process(", "posix_spawn", "execv", "dlopen", "Bundle(", "Bundle.init", "Timer", "DispatchSource", "ArtifactInspector", "InstalledIdentity", "Catalog", "InstallTransaction", "NSImage", "CGImageSource"] {
            try expect(!scanner.contains(forbidden), "Scanner contains forbidden capability \(forbidden)")
        }
        for appPath in ["Sources/PatchedApp/PatchedApp.swift", "Sources/PatchedClient/NativeClientSession.swift"] {
            try expect(!code(try source(appPath)).contains("LocalApplicationInventory"), "Existing UI auto-composes scanner")
        }
        try expect(scanner.contains("public actor LocalApplicationInventory") && scanner.contains("public init()") && scanner.contains("public func scan()"), "Scanner is not explicit actor-owned API")
        try expect(dto.contains("public let applications") && dto.contains("public let generation") && dto.contains("public let sessionID"), "Observation is not immutable")
        try expect(LocalInventoryLimits.applications == 512 && LocalInventoryLimits.directoryEntries == 8192 && LocalInventoryLimits.directoryDepth == 4 && LocalInventoryLimits.plistBytes == 1_048_576 && LocalInventoryLimits.totalMetadataBytes == 16_777_216 && LocalInventoryLimits.issues == 512 && LocalInventoryLimits.fieldBytes == 1024 && LocalInventoryLimits.pathBytes == 4096, "Fixed literal limits changed")
    }
}
