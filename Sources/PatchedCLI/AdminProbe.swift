import Foundation
import Darwin
import UpdateInstaller

/// `patched admin-probe --enable-admin-updates`: a one-off check, for the owner, that the real admin
/// pieces work on this Mac. Hidden and experimental; see scripts/admin-probe-runbook.md.
///
/// - Without `--package` it replaces one fixed dummy bundle, `/private/tmp/patched-admin-probe/root/Fake.app`,
///   which the runbook creates root-owned with sudo, using the same `WorkspacePrivilegedReplacer` the
///   installer uses. Nothing else can be targeted: the paths are fixed, must be root-owned, not writable
///   by group or others, and contain no symlinks. The replacement is a dummy bundle written here.
/// - With `--package <pkg> --team <TEAMID>` it runs only the read-only package checks and prints the raw
///   `pkgutil` and `spctl` output. Nothing is installed.
enum AdminProbe {
    static let base = "/private/tmp/patched-admin-probe"
    static var target: String { base + "/root/Fake.app" }

    static func say(_ text: String) { print(text); fflush(stdout) }

    static func checkPackage(_ path: String, team: String) -> Int32 {
        for (tool, arguments) in [("/usr/sbin/pkgutil", ["--check-signature", path]),
                                  ("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", path])] {
            let output = ProcessRunner.run(tool, arguments, timeout: 120)
            say("--- \(tool) \(arguments.joined(separator: " ")) (exit \(output.status))")
            say((output.stdout + output.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            try SystemPackageVerifier().verifyPackage(at: path, teamID: team)
            say("PACKAGE OK: flat package, Developer ID Installer for \(team), notarised. (Nothing was installed.)")
            return 0
        } catch {
            say("PACKAGE REFUSED: \(error)")
            return 1
        }
    }

    /// Root-owned, a real directory, and not writable by group or others.
    static func requireRootOwned(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw InstallRefusal.unsafePath("\(path) is not a directory (create it with the runbook's sudo steps)")
        }
        guard info.st_uid == 0 else { throw InstallRefusal.unsafePath("\(path) is not owned by root") }
        guard info.st_mode & 0o022 == 0 else { throw InstallRefusal.unsafePath("\(path) is writable by group or others") }
    }

    static func readVersion(_ bundle: String) -> String {
        (try? String(contentsOfFile: bundle + "/Contents/version.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }
    static func owner(_ path: String) -> String {
        var info = stat()
        return lstat(path, &info) == 0 ? "uid \(info.st_uid) gid \(info.st_gid) mode \(String(info.st_mode & 0o7777, radix: 8))" : "missing"
    }

    static func replaceFakeApp() async -> Int32 {
        var staging: String?
        defer { if let staging { try? FileManager.default.removeItem(atPath: staging) } }
        do {
            try FileSafety.requireNoSymlinks(target)
            for path in [base, base + "/root", target] { try requireRootOwned(path) }
            if let problem = ConsoleSessionCheck().interactiveProblem() { throw InstallRefusal.needsInteractiveAdmin(problem) }
            guard let temp = FileSafety.realPath(NSTemporaryDirectory()) else { throw InstallRefusal.io("no temporary folder") }
            let folder = temp + "/patched-admin-probe-" + UUID().uuidString
            try FileSafety.makeFreshPrivateDirectory(folder)
            staging = folder
            let replacement = folder + "/Fake.app"
            try FileManager.default.createDirectory(atPath: replacement + "/Contents", withIntermediateDirectories: true)
            try Data("probe 2 (replaced by patched admin-probe)\n".utf8).write(to: URL(fileURLWithPath: replacement + "/Contents/version.txt"))
            guard FileSafety.directoryIdentity(folder)?.device == FileSafety.directoryIdentity(target)?.device else {
                throw InstallRefusal.unsafePath("\(folder) and \(target) are on different volumes")
            }
            say("before: \(target) says \"\(readVersion(target))\", \(owner(target))")
            say("asking macOS for admin rights (its own prompt)...")
            let started = Date()
            let session = try await WorkspacePrivilegedReplacer().authorize()
            say("authorization returned after \(String(format: "%.1f", Date().timeIntervalSince(started))) s; replacing...")
            try await session.replaceItem(at: target, withItemAt: replacement)
            say("after: \(target) says \"\(readVersion(target))\", \(owner(target)); version.txt \(owner(target + "/Contents/version.txt"))")
            say("replacement still at the staging path: \(FileSafety.exists(replacement) ? "yes" : "no")")
            say(readVersion(target).hasPrefix("probe 2") ? "PROBE OK: the admin replacement works here." : "PROBE FAILED: the target did not change.")
            return readVersion(target).hasPrefix("probe 2") ? 0 : 1
        } catch {
            say("PROBE REFUSED: \(error)")
            say("after: \(target) says \"\(readVersion(target))\", \(owner(target))")
            return 1
        }
    }
}
