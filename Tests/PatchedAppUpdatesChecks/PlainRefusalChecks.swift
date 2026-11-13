import Foundation
import UpdateInstaller
@_spi(Testing) import PatchedClient

/// Rendered through the real helper refusal wording (`HelperRefusalDetail.make`), as the installer builds it.
private func helperDetail(_ paths: [String]) -> String {
    HelperRefusalDetail.make(name: "OneDrive.app", helpers: paths.enumerated().map { "\($1) (pid \(1400 + $0))" })
}

@MainActor func registerPlainRefusalChecks() {
    check("plain refusals: helper_running names the helpers without pids, paths or codes") {
        let detail = helperDetail(["Contents/StandaloneUpdaterDaemon.xpc/Contents/MacOS/StandaloneUpdaterDaemon",
                                   "Contents/OneDrive Sync Service.app/Contents/MacOS/OneDrive Sync Service"])
        let text = PlainRefusalText.text(name: "OneDrive", .helperRunning(detail))
        try expect(text == "OneDrive is still running in the background (StandaloneUpdaterDaemon and OneDrive Sync Service). Quit OneDrive (check the menu bar too), or restart your Mac, then try again.", text)
        for forbidden in ["pid", "1409", "/", "helper_running", "refused", "[", ".xpc", ".app"] {
            try expect(!text.contains(forbidden), "\(forbidden) in \(text)")
        }
        // De-duplicated, and at most two named.
        let many = PlainRefusalText.text(name: "Word", .helperRunning(helperDetail([
            "Contents/A.app/Contents/MacOS/A", "Contents/A.app/Contents/Helpers/A2", "Contents/B.xpc/Contents/MacOS/B", "Contents/MacOS/tool"])))
        try expect(many == "Word is still running in the background (A, B and others). Quit Word (check the menu bar too), or restart your Mac, then try again.", many)
        let one = PlainRefusalText.text(name: "Word", .helperRunning(helperDetail(["Contents/MacOS/Word Daemon"])))
        try expect(one.contains("(Word Daemon)"), one)
        try expect(HelperRefusalDetail.friendlyNames(in: "unrelated").isEmpty, "names from unrelated text")
    }
    check("plain refusals: app_running, app_would_not_quit, security refusals and the fallback") {
        try expect(PlainRefusalText.text(name: "Notes", .appRunning("Notes (pid 12)")) == "Quit Notes, then try again.", "app_running")
        try expect(PlainRefusalText.text(name: "Notes", .appWouldNotQuit("x")) == "Notes didn't quit. Quit it yourself, then try again.", "app_would_not_quit")
        let security = "The download didn't pass Patched's security checks, so nothing was changed."
        for refusal in [InstallRefusal.hashMismatch("abc"), .signatureInvalid("/tmp/x"), .notarisationRejected("y"), .edSignatureMissing] {
            try expect(PlainRefusalText.text(name: "Notes", refusal) == security, "\(refusal.code)")
        }
        let fallback = PlainRefusalText.text(name: "Notes", .swapFailed("/Applications/Notes.app: errno 5"))
        try expect(fallback == "Notes couldn't be updated. Nothing was changed.", fallback)
        for refusal in [InstallRefusal.io("/Users/x/file"), .journal("j"), .swapFailed("/p"), .unresolved("/p"), .download("https://h/p"), .busy("pid 4")] {
            let text = PlainRefusalText.text(name: "Notes", refusal)
            try expect(!text.contains("/") && !text.contains("pid") && !text.contains("\u{2014}") && !text.contains("["), "technical text for \(refusal.code): \(text)")
        }
    }
    check("plain refusals: the Updates result and Self Service use the plain text, the technical message is untouched") {
        let refusal = InstallRefusal.helperRunning(helperDetail(["Contents/OneDrive Sync Service.app/Contents/MacOS/OneDrive Sync Service"]))
        let row = AppUpdatesController.refusalResult(name: "OneDrive", refusal, format: .zip)
        try expect(row.text == "OneDrive is still running in the background (OneDrive Sync Service). Quit OneDrive (check the menu bar too), or restart your Mac, then try again.", row.text)
        try expect(SelfServiceController.refusalText(name: "OneDrive", refusal) == row.text, "self service text differs")
        try expect(refusal.message.contains("pid 1400") && refusal.code == "helper_running", "technical text changed: \(refusal)")
    }
}
