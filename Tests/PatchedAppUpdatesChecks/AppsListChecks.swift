import Foundation
import SwiftUI
import Vision
import UpdateSources
import UpdateInstaller
import PatchedShell
@_spi(Testing) import PatchedClient

// The Applications list: a read-only view of the Updates controller's rows. Fakes only; nothing here
// reveals a real file or opens a real app.

@MainActor final class FakeRevealer: FileRevealing {
    var paths: [String] = []
    func reveal(path: String) { paths.append(path) }
}

private func noSourceOutcome(_ name: String, _ reason: NoSourceReason, id: String? = nil) -> AppCheckOutcome {
    AppCheckOutcome(app: app(name, id: id), teamID: nil, source: nil, lowConfidence: false, installable: false,
                    result: .noSource, noSourceReason: reason)
}

/// One app of every kind, in unsorted order.
@MainActor private func mixedController(installer: FakeInstaller = FakeInstaller()) async -> AppUpdatesController {
    let cask = UpdateSource.homebrewCask(token: "low")
    let electron = UpdateSource.electron(feed: URL(string: "https://example.com/latest-mac.yml")!)
    let controller = makeController(outcomes: [
        outcome(app("Zulu"), .upToDate),
        outcome(app("Bravo", id: "com.vendor.Special"), .updateAvailable(offer("2.0"))),
        outcome(app("Alpha"), .upToDate, source: electron),
        outcome(app("Brew"), .updateAvailable(offer("3.0", source: cask)), source: cask, low: true),
        storeOutcome(app("Store"), version: "5.0"),
        noSourceOutcome("Feedless", .noPublicFeed), noSourceOutcome("Unlisted", .appStoreNotListed),
        noSourceOutcome("Patched", .thisApp, id: NoSourceReason.patchedBundleID)], installer: installer)
    await runCheck(controller)
    return controller
}

@MainActor func registerAppsListChecks() {
    check("apps list: background-only helpers are hidden from both lists unless there is an update to show") {
        func helper(_ name: String) -> InstalledApp {
            InstalledApp(name: name, path: "/Fake/\(name).app", bundleID: "com.example.\(name.lowercased())",
                         shortVersion: "1.0", build: "1.0", isBackgroundOnly: true)
        }
        let controller = makeController(outcomes: [
            outcome(app("Plain"), .upToDate),
            outcome(helper("QuietHelper"), .noSource, noSource: true),
            outcome(helper("BusyHelper"), .updateAvailable(offer("2.0")))])
        await runCheck(controller)
        let names = controller.rows.map(\.name)
        try expect(names == ["BusyHelper", "Plain", "QuietHelper"], "rows must still hold every checked app: \(names)")
        try expect(controller.rows.first { $0.name == "QuietHelper" }?.isBackgroundOnly == true, "flag lost on the row")
        try expect(controller.updatesRows.map(\.name).sorted() == ["BusyHelper", "Plain"], "Updates list: \(controller.updatesRows.map(\.name))")
        let listed = AppsListModel.visibleRows(controller.applicationsRows, query: "", filter: .all).map(\.name)
        try expect(listed == ["BusyHelper", "Plain"], "Applications list: \(listed)")
        try expect(controller.summary == "2 apps checked, 1 with updates available.", "summary counts hidden rows: \(controller.summary)")
    }
    check("apps list: rows are sorted by name") {
        let controller = await mixedController()
        let names = AppsListModel.visibleRows(Array(controller.rows.reversed()), query: "", filter: .all).map(\.name)
        try expect(names == ["Alpha", "Bravo", "Brew", "Feedless", "Patched", "Store", "Unlisted", "Zulu"], "order: \(names)")
    }

    check("apps list: search matches name and bundle ID, ignoring case") {
        let controller = await mixedController()
        @MainActor func names(_ q: String, _ f: AppsListFilter = .all) -> [String] { AppsListModel.visibleRows(controller.rows, query: q, filter: f).map(\.name) }
        try expect(names("brAV") == ["Bravo"], "name: \(names("brAV"))")
        try expect(names("VENDOR.special") == ["Bravo"], "bundle ID: \(names("VENDOR.special"))")
        try expect(names("  zulu ") == ["Zulu"], "trimmed: \(names("  zulu "))")
        try expect(names("nothing-like-this").isEmpty, "no match")
        try expect(names("br") == ["Bravo", "Brew"], "two matches: \(names("br"))")
        try expect(names("br", .updates) == ["Bravo", "Brew"] && names("alp", .updates).isEmpty, "search combines with the segment")
    }

    check("apps list: each segment filters correctly") {
        let controller = await mixedController()
        @MainActor func names(_ f: AppsListFilter) -> [String] { AppsListModel.visibleRows(controller.rows, query: "", filter: f).map(\.name) }
        try expect(names(.all).count == 8, "all")
        try expect(names(.updates) == ["Bravo", "Brew", "Store"], "updates: \(names(.updates))")
        try expect(names(.upToDate) == ["Alpha", "Zulu"], "up to date: \(names(.upToDate))")
        try expect(names(.noSource) == ["Feedless", "Patched", "Unlisted"], "no source: \(names(.noSource))")
        try expect(AppsListFilter.allCases.map(\.rawValue) == ["All", "Updates", "Up to date", "No source"], "segment titles")
    }

    check("apps list: status and source text for each kind of row") {
        let controller = await mixedController()
        @MainActor func row(_ n: String) throws -> AppUpdateRow { try controller.rows.first { $0.name == n }.unwrap() }
        let update = try row("Bravo"), current = try row("Alpha"), low = try row("Brew"), store = try row("Store")
        try expect(update.listStatus == "Update to 2.0" && update.sourceBadge == "Sparkle", "update: \(update.listStatus) \(update.sourceBadge ?? "-")")
        try expect(current.listStatus == "Up to date" && current.sourceBadge == "Electron", "up to date: \(current.listStatus) \(current.sourceBadge ?? "-")")
        try expect(low.sourceBadge == "Homebrew (unconfirmed)" && low.listStatus == "Update to 3.0", "low confidence: \(low.sourceBadge ?? "-") \(low.listStatus)")
        try expect(store.sourceBadge == "App Store" && store.listStatus == "Update to 5.0", "store: \(store.sourceBadge ?? "-") \(store.listStatus)")
        try expect(try row("Feedless").listStatus == "No public update feed" && row("Feedless").sourceBadge == nil, "no feed")
        try expect(try row("Unlisted").listStatus == "Updates through the App Store", "not listed")
        try expect(try row("Patched").listStatus == "This app", "this app")
        // A plain Homebrew match with confidence has no suffix.
        let brew = UpdateSource.homebrewCask(token: "ok")
        let sure = makeController(outcomes: [outcome(app("Sure"), .upToDate, source: brew)])
        await runCheck(sure)
        try expect(sure.rows[0].sourceBadge == "Homebrew", "confident homebrew: \(sure.rows[0].sourceBadge ?? "-")")
    }

    check("apps list: only a real, still-listed .app folder can be revealed") {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("patched-applist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let real = base.appendingPathComponent("Real.app"), link = base.appendingPathComponent("Link.app")
        let notApp = base.appendingPathComponent("Plain"), file = base.appendingPathComponent("File.app")
        let dirLink = base.appendingPathComponent("DirLink")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createDirectory(at: notApp, withIntermediateDirectories: true)
        try Data().write(to: file)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        try fm.createSymbolicLink(at: dirLink, withDestinationURL: base)
        try expect(AppRevealCheck.isRevealable(real.path), "real app refused")
        for bad in [link.path, notApp.path, file.path, dirLink.appendingPathComponent("Real.app").path,
                    base.appendingPathComponent("Missing.app").path, "Relative.app"] {
            try expect(!AppRevealCheck.isRevealable(bad), "accepted \(bad)")
        }
        // Through the action: the row must still be in the controller's rows, and the path must still be good.
        func installed(_ url: URL) -> InstalledApp {
            InstalledApp(name: url.deletingPathExtension().lastPathComponent, path: url.path, bundleID: "com.example.x",
                         shortVersion: "1.0", build: "1.0")
        }
        let apps = [real, link, base.appendingPathComponent("Missing.app")].map(installed)
        let controller = makeController(outcomes: apps.map { outcome($0, .upToDate) })
        await runCheck(controller)
        let installer = FakeInstaller()
        let other = makeController(outcomes: [outcome(installed(real), .upToDate)], installer: installer)
        await runCheck(other)
        let revealer = FakeRevealer()
        let actions = AppsListActions(revealer: revealer, showUpdate: { _ in }, currentRows: { controller.rows })
        @MainActor func row(_ n: String) throws -> AppUpdateRow { try controller.rows.first { $0.name == n }.unwrap() }
        try expect(actions.showInFinder(try row("Real")), "real row refused")
        try expect(revealer.paths == [real.path], "revealed: \(revealer.paths)")
        try expect(!actions.showInFinder(try row("Link")) && !actions.showInFinder(try row("Missing")), "bad row accepted")
        // A row the controller no longer lists (a stale view row) is refused even if the folder is fine.
        let gone = actions.showInFinder(other.rows[0])
        try expect(gone, "same path is still listed, so it is allowed")
        let empty = AppsListActions(revealer: revealer, showUpdate: { _ in }, currentRows: { [] })
        try expect(!empty.showInFinder(try row("Real")), "removed row accepted")
        try expect(revealer.paths == [real.path, real.path], "unexpected reveals: \(revealer.paths)")
    }

    check("apps list: Show in Updates through the session starts nothing") {
        let installer = FakeInstaller()
        let controller = await mixedController(installer: installer)
        let opener = RecordingOpener()
        let nav = ShellNavigation(destination: .applications)
        let session = NativeClientSession(navigation: nav, appUpdates: controller, urlOpener: opener)
        let rowsBefore = controller.rows, eventsBefore = installer.recorder.events
        var shown: [String] = []
        let actions = AppsListActions(revealer: FakeRevealer(), showUpdate: { shown.append($0); _ = session.showUpdate(id: $0) },
                                      currentRows: { controller.rows })
        let bravo = try controller.rows.first { $0.name == "Bravo" }.unwrap()
        let zulu = try controller.rows.first { $0.name == "Zulu" }.unwrap()
        actions.showInUpdates(bravo)
        actions.showInUpdates(zulu)
        try expect(shown == [bravo.id], "show in Updates: \(shown)")
        try expect(nav.destination == .updates && controller.focusedRowID == bravo.id, "did not navigate and focus")
        try expect(controller.rows == rowsBefore, "rows changed")
        try expect(installer.recorder.events == eventsBefore, "installer or scanner reached: \(installer.recorder.events)")
        try expect(opener.nothingOpened, "something was opened")
        try expect(controller.updateAllInvocations == 0 && controller.phase == .idle, "Update All or a check started")
    }

    check("apps list: Check Now stays after a check, and a catalogue failure is explained") {
        let controller = await mixedController()
        let revealer = FakeRevealer()
        @MainActor func shown(_ c: AppUpdatesController) throws -> String { try paintedText(AppsListView(controller: c, revealer: revealer, showUpdate: { _ in })) }
        try expect(controller.hasChecked && AppsListView.checkNowEnabled(controller), "Check Now not available after a check")
        let after = try shown(controller)
        try expect(after.contains("checked"), "header subtitle missing: \(after)")
        // The header's right-hand corner holds the button: its border and text are not white.
        let rep = try NSBitmapImageRep(data: paintView(AppsListView(controller: controller, revealer: revealer, showUpdate: { _ in }), width: 820, height: 560)).unwrap()
        let scale = CGFloat(rep.pixelsWide) / 820
        var inked = 0
        for x in Int(700 * scale)..<Int(800 * scale) { for y in Int(18 * scale)..<Int(50 * scale) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent < 0.8 { inked += 1 }
        } }
        try expect(inked > 40, "Check Now not drawn after a check (\(inked) dark pixels)")
        let broken = Counter()
        let failing = makeController(outcomes: [outcome(app("Alpha"), .upToDate)], catalogue: { broken.value > 0 ? "/x/catalogue.json: not a JSON object" : nil })
        _ = broken.next()
        await failing.refreshInstallerState()
        let text = try shown(failing)
        try expect(text.contains("paused") && text.contains("JSON object"), "failure text missing: \(text)")
        try expect(text.contains("Try again"), "no recovery action: \(text)")
        try expect(!AppsListView.checkNowEnabled(failing), "Check Now should be disabled while the catalogue is unusable")
        let slow = makeController(outcomes: [outcome(app("Alpha"), .upToDate)])
        slow.check()
        try expect(!AppsListView.checkNowEnabled(slow), "Check Now should be disabled while checking")
        await slow.waitUntilIdle()
    }

    check("apps list: the Applications destination renders AppsListView, driven by the Updates controller") {
        let source = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/NativeClientSession.swift", encoding: .utf8)
        let start = try source.range(of: "case .applications:").unwrap()
        let tail = String(source[start.upperBound...])
        let branch = String(tail[..<(tail.range(of: "case .updates:")?.lowerBound ?? tail.endIndex)])
        try expect(branch.contains("AppsListView(controller: session.appUpdates"), "destination: \(branch)")
        let updatesView = try String(contentsOfFile: sourcesRoot() + "/PatchedClient/AppUpdatesView.swift", encoding: .utf8)
        try expect(updatesView.contains("row.sourceBadge") && !updatesView.contains("Text(verbatim: row.source)"), "Updates view shows raw source strings")
        try expect(!branch.contains("LocalApplicationsView") && !branch.contains("session.applications"), "legacy view still used")
        // And painted for real: the root view on the Applications destination shows the rows.
        let controller = await mixedController()
        let nav = ShellNavigation(destination: .applications)
        let session = NativeClientSession(navigation: nav, appUpdates: controller, urlOpener: RecordingOpener())
        let fake = FakeIconProvider(); controller.iconProvider = fake
        let png = try paintView(NativeClientRootView(session: session), width: 900, height: 640)
        try expect(png.count > 5_000, "blank")
        try expect(fake.requested.contains("/Fake/Alpha.app"), "icons were not requested for the list rows")
    }

    check("apps list: render with long names and every status") {
        let cask = UpdateSource.homebrewCask(token: "low")
        let electron = UpdateSource.electron(feed: URL(string: "https://example.com/latest-mac.yml")!)
        let controller = makeController(outcomes: [
            outcome(app("Adobe Creative Cloud Desktop Application With A Very Long Name"), .updateAvailable(offer("12.4.1.99"))),
            outcome(app("Alpha"), .upToDate, source: electron),
            outcome(app("Brew Low Confidence"), .updateAvailable(offer("3.0", source: cask)), source: cask, low: true),
            storeOutcome(app("Pages")),
            noSourceOutcome("Feedless", .noPublicFeed), noSourceOutcome("Unlisted", .appStoreNotListed),
            noSourceOutcome("Patched", .thisApp, id: NoSourceReason.patchedBundleID),
            outcome(app("Zulu"), .upToDate)])
        controller.iconProvider = FakeIconProvider()
        await runCheck(controller)
        let revealer = FakeRevealer()
        let light = try paintView(AppsListView(controller: controller, revealer: revealer, showUpdate: { _ in }), width: 820, height: 560)
        let dark = try paintView(AppsListView(controller: controller, revealer: revealer, showUpdate: { _ in }), width: 820, height: 560, dark: true)
        let empty = try paintView(AppsListView(controller: makeController(outcomes: []), revealer: revealer, showUpdate: { _ in }), width: 820, height: 560)
        try expect(light.count > 5_000 && light != dark && light != empty, "renders look wrong")
        let dir = "/private/tmp/claude-501/-Users-andybridson-Development/c6e254ca-213f-4635-bb4d-d24e69057d29/scratchpad"
        if ProcessInfo.processInfo.environment["PATCHED_APPS_LIST_PNG"] != nil {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try light.write(to: URL(fileURLWithPath: dir + "/apps-tab.png"))
            try dark.write(to: URL(fileURLWithPath: dir + "/apps-tab-dark.png"))
            try empty.write(to: URL(fileURLWithPath: dir + "/apps-tab-empty.png"))
        }
        try expect(revealer.paths.isEmpty, "painting must not act")
    }
}

/// The text recognised in a painted view, so a check can say a message really is on screen.
@MainActor func paintedText<V: View>(_ view: V) throws -> String {
    let png = try paintView(view, width: 820, height: 560)
    guard let painted = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CheckFailure(description: "no image") }
    // Text recognition misses some small native button titles at 1x and misreads some digits at 2x, so the
    // result is what either reading of the same pixels finds.
    guard let context = CGContext(data: nil, width: painted.width * 2, height: painted.height * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CheckFailure(description: "no context") }
    context.interpolationQuality = .high
    context.draw(painted, in: CGRect(x: 0, y: 0, width: painted.width * 2, height: painted.height * 2))
    guard let enlarged = context.makeImage() else { throw CheckFailure(description: "no enlarged image") }
    return try [painted, enlarged].map { image in
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
    }.joined(separator: " || ")
}
