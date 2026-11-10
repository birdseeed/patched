import Foundation
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

// Per-row progress and Cancel for a single update. The installer is a fake that reports steps when told to;
// the real installer's cancellation is covered in UpdateInstallerChecks.

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var on = false
    var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

@MainActor private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw CheckFailure(description: "timed out waiting for " + what)
}

@MainActor func registerProgressAndCancelChecks() {
    let path = "/Fake/Alpha.app"

    check("helper running: the row says why and offers no quit prompt, since Patched can't quit a helper") {
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in throw InstallRefusal.helperRunning("Alpha.app has a helper process running from inside it") }
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0")))], installer: installer)
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: path) }
        let row = controller.rows.first { $0.name == "Alpha" }!
        try expect(controller.pendingQuit == nil, "offered to quit for a helper: \(String(describing: controller.pendingQuit))")
        try expect(row.result?.kind == .failure && row.result?.text.contains("helper") == true && row.result?.text.contains("--quit") == false,
                   "row: \(String(describing: row.result))")
    }

    check("progress: download bytes, verifying and installing reach the row, then clear; out-of-order steps are ignored") {
        let installer = FakeInstaller()
        let hold = Gate()
        installer.updateHandler = { _, _ in
            installer.emit(.downloading(received: 1_500_000, expected: 48_000_000))
            await hold.wait()
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0")))], installer: installer)
        await runCheck(controller)
        controller.update(id: path)
        try await waitFor("download progress") { controller.row(id: path)?.progress != nil }
        var row = controller.row(id: path)!
        try expect(row.progress == .downloading(received: 1_500_000, expected: 48_000_000), "progress: \(String(describing: row.progress))")
        try expect(row.progressText == "Downloading 1.5 of 48.0 MB" || row.progressText?.hasPrefix("Downloading 1") == true, "text: \(row.progressText ?? "nil")")
        try expect(abs((row.downloadFraction ?? 0) - 1.5 / 48) < 0.0001, "fraction: \(String(describing: row.downloadFraction))")
        installer.emit(.verifying)
        try await waitFor("verifying") { controller.row(id: path)?.progress == .verifying }
        try expect(controller.row(id: path)?.progressText == "Verifying…", "verifying text")
        installer.emit(.downloading(received: 2, expected: 3))     // late, out of order
        installer.emit(.installing)
        try await waitFor("installing") { controller.row(id: path)?.progress == .installing }
        try expect(controller.row(id: path)?.progressText == "Installing…", "installing text")
        hold.open(); await controller.waitUntilIdle()
        row = controller.row(id: path)!
        try expect(row.progress == nil && row.progressText == nil && !row.cancelRequested && row.activity == .idle, "progress left on the row")
    }

    check("progress: the byte text shares one unit, and says so without a total") {
        let gb = Locale(identifier: "en_GB")
        try expect(AppUpdateRow.downloadText(received: 12_300_000, expected: 48_000_000, locale: gb) == "Downloading 12.3 of 48.0 MB", AppUpdateRow.downloadText(received: 12_300_000, expected: 48_000_000, locale: gb))
        try expect(AppUpdateRow.downloadText(received: 400_000_000, expected: 1_200_000_000, locale: gb) == "Downloading 0.4 of 1.2 GB", "GB")
        try expect(AppUpdateRow.downloadText(received: 12_300_000, expected: nil, locale: gb) == "Downloading 12.3 MB", "no total")
        try expect(AppUpdateRow.downloadText(received: 0, expected: 48_000_000, locale: gb) == "Downloading 0.0 of 48.0 MB", "start")
        try expect(AppUpdateRow.downloadText(received: 9_000_000_000, expected: 1_000_000, locale: gb) == "Downloading 1.0 of 1.0 MB", "never over the total")
    }

    check("cancel: before the swap the update stops, the app is untouched and the row says so") {
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in
            installer.emit(.downloading(received: 10, expected: 100))
            // Like the real installer: notice the cancellation and throw.
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000) }
            throw CancellationError()
        }
        let rig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("Bravo"), .updateAvailable(offer("2.0")))], installer: installer)
        await runCheck(rig.controller)
        try expect(!rig.controller.canCancelUpdate(rig.controller.row(id: path)!), "cancel offered with nothing running")
        rig.controller.update(id: path)
        try await waitFor("progress") { rig.controller.row(id: path)?.progress != nil }
        let running = rig.controller.row(id: path)!
        try expect(rig.controller.canCancelUpdate(running), "cancel not offered while downloading")
        try expect(!rig.controller.canCancelUpdate(rig.controller.row(id: "/Fake/Bravo.app")!), "cancel offered on another row")
        rig.controller.cancelUpdate(id: path)
        try expect(rig.controller.row(id: path)?.progressText == "Cancelling…" && !rig.controller.canCancelUpdate(rig.controller.row(id: path)!), "no cancelling state")
        await rig.controller.waitUntilIdle()
        let row = rig.controller.row(id: path)!
        try expect(row.activity == .idle && row.result?.text == "Cancelled. Alpha was not changed." && row.result?.kind == .info, "result: \(String(describing: row.result))")
        try expect(row.status == .updateAvailable && row.installedVersion == "1.0" && row.progress == nil && !row.cancelRequested, "row changed: \(row)")
        try expect(rig.world[path]?.app.shortVersion == "1.0", "the world changed")
        try expect(!rig.controller.isWorking, "still working")
        // It can be updated again afterwards.
        installer.updateHandler = { outcome, _ in AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b") }
        rig.controller.update(id: path); await rig.controller.waitUntilIdle()
        try expect(rig.controller.row(id: path)?.result?.kind == .success, "update after cancel: \(String(describing: rig.controller.row(id: path)?.result))")
    }

    check("cancel: not offered or honoured once the swap has begun, so the update finishes") {
        let installer = FakeInstaller()
        let hold = Gate()
        let cancelledAtEnd = Flag()
        installer.updateHandler = { _, _ in
            installer.emit(.installing)
            await hold.wait()
            cancelledAtEnd.value = Task.isCancelled
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0")))], installer: installer)
        await runCheck(controller)
        controller.update(id: path)
        try await waitFor("installing") { controller.row(id: path)?.progress == .installing }
        try expect(!controller.canCancelUpdate(controller.row(id: path)!), "cancel offered after the commit point")
        controller.cancelUpdate(id: path)
        try expect(controller.row(id: path)?.cancelRequested == false, "cancel accepted after the commit point")
        hold.open(); await controller.waitUntilIdle()
        try expect(!cancelledAtEnd.value, "the operation was cancelled after the commit point")
        try expect(controller.row(id: path)?.result?.kind == .success, "update did not finish: \(String(describing: controller.row(id: path)?.result))")
    }

    check("cancel: Update All and the admin paths have no per-row Cancel, and Update All still reports its progress") {
        let installer = FakeInstaller()
        let hold = Gate()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Alpha" { installer.emit(.downloading(received: 5, expected: 10)); await hold.wait() }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let controller = makeController(outcomes: [outcome(app("Alpha"), .updateAvailable(offer("2.0"))), outcome(app("Bravo"), .updateAvailable(offer("2.0")))], installer: installer)
        await runCheck(controller)
        _ = controller.updateAll()
        try await waitFor("row progress in Update All") { controller.row(id: path)?.progress != nil }
        try expect(controller.updateAllProgress?.text == "Updating 1 of 2…", "Update All progress: \(String(describing: controller.updateAllProgress))")
        try expect(!controller.canCancelUpdate(controller.row(id: path)!), "per-row Cancel offered during Update All")
        controller.cancelUpdate(id: path)
        try expect(controller.row(id: path)?.cancelRequested == false, "Update All run cancelled by a row's Cancel")
        hold.open(); await controller.waitUntilIdle()
        try expect(controller.updateAllProgress == nil && controller.rows.allSatisfy { $0.result?.kind == .success }, "Update All did not finish: \(controller.rows.map { $0.result?.text ?? "-" })")
        // Admin rows: the ordinary-path progress and Cancel are not offered.
        let admin = FakeInstaller()
        admin.adminHandler = { _, _ in
            admin.emit(.downloading(received: 1, expected: 2))
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let adminRig = Rig([outcome(app("Alpha"), .updateAvailable(offer("2.0")))], installer: admin, adminUpdates: true)
        await runCheck(adminRig.controller)
        adminRig.controller.update(id: path); await adminRig.controller.waitUntilIdle()
        try expect(adminRig.controller.row(id: path)?.progress == nil, "progress left on an admin row")
    }
}
