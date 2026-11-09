import Foundation
import AppKit
import CryptoKit
import Darwin
import Security
import SystemConfiguration
import UpdateSources

// Admin path (Phase 2b), in two parts with separate switches:
// - privileged replacement of root-owned apps: PATCHED_ENABLE_ADMIN_UPDATES=1 or --enable-admin-updates.
//   UNTESTED and known NOT to work for ad-hoc-signed builds: on macOS 27 the prompt appears and is granted,
//   then replaceItemAt fails with EIO (refused as admin_replace_unavailable). Revisit with Developer ID.
// - .pkg updates through Apple's Installer: on by default; PATCHED_ENABLE_PKG_UPDATES=0 turns them off. These
//   do not depend on Patched's own signing. Checked against a real notarised vendor package (DisplayLink 17.1,
//   9 November 2026): the right Team ID passes and a wrong one is refused.
// When a part is off, nothing for it is reachable from an update: it refuses exactly as before
// (needs_admin, unsupported_format). There is no fallback to osascript, "do shell script" or any other
// way of running commands as root.
//
// What it may do, and nothing more:
// - Replace one verified, staged .app with macOS's own admin prompt (NSWorkspace authorization plus
//   FileManager(authorization:).replaceItemAt). No helper, daemon, setuid tool, sudo, shell or the
//   deprecated Authorization Services "execute with privileges" call. Nothing runs as root in the background.
// - Hand one verified Developer ID Installer package to Apple's Installer, which shows its own window and
//   admin prompt. Package scripts then run as root under Apple's Installer, which is why the package's
//   Developer ID Installer Team ID must equal the installed app's and Apple must have notarised it.
// - Only from an explicit user action (a click in the app, or `patched update` typed at the Mac). The
//   consent token `AdminInteraction` is created only there; scheduled checks never create one.

public enum AdminUpdateFlag {
    /// Privileged replacement of root-owned apps.
    public static let environmentVariable = "PATCHED_ENABLE_ADMIN_UPDATES"
    public static let commandLineFlag = "--enable-admin-updates"
    /// `.pkg` updates through Apple's Installer.
    public static let packageEnvironmentVariable = "PATCHED_ENABLE_PKG_UPDATES"
    public static let packageCommandLineFlag = "--enable-pkg-updates"
    /// Exactly "1" turns it on; anything else (unset, "0", "true", "yes") leaves it off.
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentVariable] == "1"
    }
    /// `.pkg` updates are on by default (Apple's Installer asks for the password and does the installing);
    /// exactly "0" turns them off.
    public static func isPackageEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[packageEnvironmentVariable] != "0"
    }
}

/// One explicit user action that may use admin rights for one update or rollback. Its existence is the
/// consent: the installer uses the admin path only when the caller passes one. It also carries the
/// "Apple's Installer has opened" notice to the CLI or app, and the app's "Done" button.
public final class AdminInteraction: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let opened: @Sendable (String) -> Void
    public init(onInstallerOpened: @escaping @Sendable (String) -> Void = { _ in }) { opened = onInstallerOpened }
    /// The user says they have finished in Apple's Installer (the app's Done button).
    public func userFinishedInstaller() { lock.withLock { finished = true } }
    public var userSaysFinished: Bool { lock.withLock { finished } }
    /// Apple's Installer has opened; tells the CLI or the app (public so app checks can drive it).
    public func installerOpened(_ message: String) { opened(message) }
}

// MARK: Privileged replacement

/// Replaces an app bundle with admin rights granted by macOS's own prompt. Behind a protocol so checks use
/// a fake; the real one is used only when the flag is on and a person is at the Mac.
public protocol PrivilegedReplacing: Sendable {
    /// Asks macOS for the right to replace files (it may prompt now or at the first replacement). One
    /// session serves one transaction, so a restore after a failed check does not ask again.
    func authorize() async throws -> any PrivilegedReplacementSession
}

public protocol PrivilegedReplacementSession: Sendable {
    /// Replaces `target` with `replacement` (both absolute; `replacement` is moved, not copied). Throws
    /// `adminDenied` or `privilegedReplaceFailed`; the caller then judges what is on disk.
    func replaceItem(at target: String, withItemAt replacement: String) async throws
}

public struct WorkspacePrivilegedReplacer: PrivilegedReplacing {
    public init() {}

    public func authorize() async throws -> any PrivilegedReplacementSession {
        do { try RealStateTripwire.check("NSWorkspace admin authorization") }
        catch { throw InstallRefusal.adminDenied("\(error)") }
        return WorkspaceReplacementSession(authorization: try await Self.request())
    }

    static func request() async throws -> WorkspaceAuthorizationBox {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkspaceAuthorizationBox, Error>) in
            NSWorkspace.shared.requestAuthorization(to: .replaceFile) { authorization, error in
                if let authorization { continuation.resume(returning: WorkspaceAuthorizationBox(authorization)) }
                else { continuation.resume(throwing: Self.refusal(error, stage: "authorization")) }
            }
        }
    }

    /// Cancelled prompts and "no permission" (which macOS also uses for a declined prompt or system policy)
    /// are denials. An I/O error (EIO, directly or under NSFileWriteUnknownError) is macOS's helper refusing
    /// this build, as seen for ad-hoc signing on macOS 27. Everything else is a failure. Either way the
    /// caller re-reads the disk before deciding.
    public static func refusal(_ error: Error?, stage: String) -> InstallRefusal {
        guard let error = error as NSError? else {
            return .privilegedReplaceFailed("\(stage): macOS returned neither a grant nor an error")
        }
        let detail = "\(stage): \(error.domain) \(error.code): \(error.localizedDescription.prefix(200))"
        if error.domain == NSCocoaErrorDomain && (error.code == NSUserCancelledError || error.code == NSFileWriteNoPermissionError) {
            return .adminDenied(detail)
        }
        func isEIO(_ e: NSError) -> Bool { e.domain == NSPOSIXErrorDomain && e.code == Int(EIO) }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        if isEIO(error) || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteUnknownError && underlying.map(isEIO) == true) {
            return .adminReplaceUnavailable(detail + (underlying.map { " (underlying \($0.domain) \($0.code))" } ?? ""))
        }
        return .privilegedReplaceFailed(detail)
    }
    static func isExpired(_ error: Error) -> Bool { (error as NSError).code == NSWorkspaceAuthorizationInvalidError }
}

final class WorkspaceAuthorizationBox: @unchecked Sendable {
    let value: NSWorkspace.Authorization
    init(_ value: NSWorkspace.Authorization) { self.value = value }
}

final class WorkspaceReplacementSession: PrivilegedReplacementSession, @unchecked Sendable {
    private let lock = NSLock()
    private var authorization: WorkspaceAuthorizationBox
    init(authorization: WorkspaceAuthorizationBox) { self.authorization = authorization }

    func replaceItem(at target: String, withItemAt replacement: String) async throws {
        do {
            try replace(target, replacement, lock.withLock { authorization })
        } catch where WorkspacePrivilegedReplacer.isExpired(error) {
            // An authorization may be single use. Ask once more for this same transaction only.
            let fresh = try await WorkspacePrivilegedReplacer.request()
            lock.withLock { authorization = fresh }
            do { try replace(target, replacement, fresh) }
            catch { throw WorkspacePrivilegedReplacer.refusal(error, stage: "replace") }
        } catch {
            throw WorkspacePrivilegedReplacer.refusal(error, stage: "replace")
        }
    }

    private func replace(_ target: String, _ replacement: String, _ box: WorkspaceAuthorizationBox) throws {
        // A new FileManager for every use of an authorization, as AppKit requires.
        let manager = FileManager(authorization: box.value)
        _ = try manager.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: replacement))
    }
}

// MARK: Who is at the Mac

/// The admin path needs a person at the screen to answer macOS's prompt.
public protocol InteractiveSessionChecking: Sendable {
    /// Why this process cannot show an admin prompt to the person using it, or nil when it can.
    func interactiveProblem() -> String?
}

public struct ConsoleSessionCheck: InteractiveSessionChecking {
    public init() {}
    public func interactiveProblem() -> String? {
        var session = SecuritySessionId()
        var attributes = SessionAttributeBits()
        guard SessionGetInfo(callerSecuritySession, &session, &attributes) == errSecSuccess else {
            return "cannot read this login session"
        }
        guard attributes.contains(.sessionHasGraphicAccess) else {
            return "this session has no screen (for example SSH); run it from Terminal on the Mac itself"
        }
        var consoleUID: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) as String?, name != "loginwindow" else {
            return "nobody is logged in at the screen"
        }
        guard consoleUID == getuid() else { return "another user is logged in at the screen" }
        return nil
    }
}

// MARK: Installer packages

/// Strict checks of a downloaded `.pkg` before it is handed to Apple's Installer.
public protocol PackageVerifying: Sendable {
    /// Flat package, Developer ID Installer signature from `teamID`, and notarised (Gatekeeper install).
    func verifyPackage(at path: String, teamID: String) throws
}

public struct SystemPackageVerifier: PackageVerifying {
    public typealias Runner = @Sendable (String, [String], TimeInterval) -> ProcessRunner.Output
    let run: Runner
    public init(run: @escaping Runner = { ProcessRunner.run($0, $1, timeout: $2) }) { self.run = run }

    public func verifyPackage(at path: String, teamID: String) throws {
        try PackageFile.requireFlat(path)
        let signature = run("/usr/sbin/pkgutil", ["--check-signature", path], 120)
        try PackageSignature.interpretCheckSignature(status: signature.timedOut ? -1 : signature.status,
                                                     output: signature.stdout + "\n" + signature.stderr,
                                                     path: path, teamID: teamID)
        let assessment = run("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", path], 120)
        try PackageSignature.interpretInstallAssessment(status: assessment.timedOut ? -1 : assessment.status,
                                                        output: assessment.stdout + "\n" + assessment.stderr,
                                                        path: path, teamID: teamID)
    }
}

public enum PackageFile {
    /// A flat package is one regular file in xar format. Bundle-style (directory) packages, symlinks and
    /// anything without a version 1 xar header are refused.
    public static func requireFlat(_ path: String) throws {
        guard let info = FileSafety.lstatInfo(path) else { throw InstallRefusal.packageMalformed("\(path) does not exist") }
        if FileSafety.isSymlink(info) { throw InstallRefusal.packageMalformed("\(path) is a symlink") }
        if FileSafety.isDirectory(info) { throw InstallRefusal.packageMalformed("bundle-style (folder) packages are not supported") }
        guard FileSafety.isRegular(info) else { throw InstallRefusal.packageMalformed("\(path) is not a regular file") }
        guard info.st_size >= 28 else { throw InstallRefusal.packageMalformed("too small to be a package") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw InstallRefusal.io("cannot open \(path)") }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 8)
        guard read(fd, &header, 8) == 8 else { throw InstallRefusal.packageMalformed("cannot read the header") }
        guard header[0...3] == [0x78, 0x61, 0x72, 0x21] else { throw InstallRefusal.packageMalformed("not a xar archive") }
        let headerSize = Int(header[4]) << 8 | Int(header[5])
        let version = Int(header[6]) << 8 | Int(header[7])
        guard version == 1, headerSize >= 28 else {
            throw InstallRefusal.packageMalformed("xar header version \(version), size \(headerSize)")
        }
    }

    /// Lower-case hex SHA-256 of a file, streamed.
    public static func sha256Hex(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw InstallRefusal.io("cannot read \(path)") }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Parsers for `pkgutil --check-signature` and `spctl --assess --type install`. Every line must be one
/// they understand; anything unexpected is a refusal.
public enum PackageSignature {
    static let developerIDStatus = "Status: signed by a developer certificate issued by Apple for distribution"
    static let installerLeafPrefix = "Developer ID Installer: "
    static let intermediate = "Developer ID Certification Authority"
    static let root = "Apple Root CA"

    /// The leaf must be "Developer ID Installer: <name> (<TEAMID>)" with TEAMID equal to `teamID`, issued by
    /// Apple's Developer ID Certification Authority under Apple Root CA (exactly three certificates).
    public static func interpretCheckSignature(status: Int32, output: String, path: String, teamID: String) throws {
        func refuse(_ why: String) -> InstallRefusal { .packageSignatureInvalid(why) }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard status == 0 else { throw refuse("pkgutil exit \(status): \(lines.dropFirst().first.map { String($0.prefix(200)) } ?? "no output")") }
        guard TeamIdentifier.isValid(teamID) else { throw refuse("Team ID \"\(teamID)\" is malformed") }
        let name = (path as NSString).lastPathComponent
        guard lines.first == "Package \"\(name)\":" else { throw refuse("unexpected pkgutil output: \(lines.first.map { String($0.prefix(120)) } ?? "none")") }
        let chainStart = lines.firstIndex(of: "Certificate Chain:")
        let header = lines[1..<(chainStart ?? lines.count)]
        let statuses = header.filter { $0.hasPrefix("Status:") }
        guard statuses.count == 1, statuses[0] == developerIDStatus else {
            if statuses.contains("Status: signed Apple Software") {
                throw refuse("signed by Apple, not with a Developer ID Installer certificate")
            }
            throw refuse(statuses.count > 1 ? "more than one signature status" : statuses.first.map { String($0.prefix(200)) } ?? "no signature status")
        }
        guard let chainStart, lines.filter({ $0 == "Certificate Chain:" }).count == 1 else { throw refuse("no certificate chain") }
        for line in header where !line.hasPrefix("Status:") && !line.hasPrefix("Notarization:") && !line.hasPrefix("Signed with ") {
            throw refuse("unexpected pkgutil line: \(line.prefix(120))")
        }
        var subjects: [String] = []
        for line in lines[(chainStart + 1)...] {
            if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]), line[line.index(after: dot)...].hasPrefix(" ") {
                guard number == subjects.count + 1 else { throw refuse("certificate chain is out of order") }
                subjects.append(String(line[line.index(dot, offsetBy: 2)...]))
                continue
            }
            let isFingerprint = line.allSatisfy { $0.isHexDigit || $0 == " " }
            guard !subjects.isEmpty, line.hasPrefix("Expires: ") || line == "SHA256 Fingerprint:" || isFingerprint
                    || line.allSatisfy({ $0 == "-" }) else {
                throw refuse("unexpected line in the certificate chain: \(line.prefix(120))")
            }
        }
        guard subjects.count == 3 else { throw refuse("expected 3 certificates, found \(subjects.count)") }
        guard subjects[1] == intermediate, subjects[2] == root else {
            throw refuse("not issued by Apple's Developer ID authority: \(subjects[1]) / \(subjects[2])")
        }
        let leaf = subjects[0]
        guard leaf.hasPrefix(installerLeafPrefix) else { throw refuse("not a Developer ID Installer certificate: \(leaf.prefix(120))") }
        guard leaf.hasSuffix(")"), let open = leaf.lastIndex(of: "(") else { throw refuse("no Team ID in \(leaf.prefix(120))") }
        let team = String(leaf[leaf.index(after: open)..<leaf.index(before: leaf.endIndex)])
        guard TeamIdentifier.isValid(team) else { throw refuse("malformed Team ID in \(leaf.prefix(120))") }
        guard team == teamID else { throw refuse("signed by Team ID \(team), the installed app is \(teamID)") }
    }

    /// `spctl --assess --type install -vv`: accepted, not overridden, notarised Developer ID, and the
    /// origin names the same Team ID.
    public static func interpretInstallAssessment(status: Int32, output: String, path: String, teamID: String) throws {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard status == 0, lines.contains("\(path): accepted") else {
            throw InstallRefusal.notarisationRejected(lines.first(where: { !$0.isEmpty }).map { String($0.prefix(200)) } ?? "exit \(status)")
        }
        if lines.contains(where: { $0.hasPrefix("override=") }) {
            throw InstallRefusal.notarisationRejected("Gatekeeper assessment is overridden or disabled")
        }
        guard lines.contains("source=Notarized Developer ID") else {
            throw InstallRefusal.notarisationRejected(lines.first(where: { $0.hasPrefix("source=") }) ?? "not notarised Developer ID")
        }
        let origins = lines.filter { $0.hasPrefix("origin=") }
        guard origins.count == 1, origins[0].hasPrefix("origin=" + installerLeafPrefix), origins[0].hasSuffix("(\(teamID))") else {
            throw InstallRefusal.notarisationRejected("origin is not Developer ID Installer for Team ID \(teamID): \(origins.first ?? "none")")
        }
    }
}

/// Hands a verified package to Apple's Installer, which shows its own window and admin prompt.
public protocol PackageInstallerOpening: Sendable {
    func openInstaller(forPackageAt path: String) throws
}

public struct SystemInstallerOpener: PackageInstallerOpening {
    /// By full path, so an app that merely calls itself "Installer" is never chosen.
    public static let installerApp = "/System/Library/CoreServices/Installer.app"
    let run: SystemPackageVerifier.Runner
    public init(run: @escaping SystemPackageVerifier.Runner = { ProcessRunner.run($0, $1, timeout: $2) }) { self.run = run }

    public func openInstaller(forPackageAt path: String) throws {
        do { try RealStateTripwire.check("Apple's Installer") }
        catch { throw InstallRefusal.installerFailed("\(error)") }
        try FileSafety.requireNoSymlinks(Self.installerApp)
        let result = run("/usr/bin/open", ["-a", Self.installerApp, path], 60)
        guard result.succeeded else { throw InstallRefusal.installerFailed("open: \(result.summary)") }
    }
}

public enum InstallerActivity {
    public static let bundleID = "com.apple.installer"
    /// True while any instance of Apple's Installer is running.
    public static func isRunning() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

public enum InstallerWaitResult: Sendable, Equatable {
    /// The installed app changed and stayed the same for a few reads.
    case changed
    /// The user said they have finished (Done).
    case finishedByUser
    case timedOut
}

/// Waits for the user to finish in Apple's Installer. The installer judges the disk afterwards either way.
public protocol InstallerCompletionWaiting: Sendable {
    func waitForInstaller(appAt path: String, installed: BundleFacts, interaction: AdminInteraction) async -> InstallerWaitResult
    /// Once the app has changed, Installer may still be writing the rest of it (Info.plist often lands first).
    /// While it is running and the result is undecided, Patched looks again every `settleInterval`, for at most
    /// `settleTimeout`, before giving up.
    var settleInterval: TimeInterval { get }
    var settleTimeout: TimeInterval { get }
}

extension InstallerCompletionWaiting {
    public var settleInterval: TimeInterval { 5 }
    public var settleTimeout: TimeInterval { 5 * 60 }
}

/// Polls the installed app's Info.plist until it differs from before and stays put for `stableReads`
/// reads (Installer writes files one by one), until the user presses Done, or until `timeout`.
public struct VersionPollingWaiter: InstallerCompletionWaiting {
    public var timeout: TimeInterval
    public var interval: TimeInterval
    public var stableReads: Int
    /// See `InstallerCompletionWaiting`: each look re-runs codesign and spctl, so it is not done every poll.
    public var settleInterval: TimeInterval
    /// Bounded well below `timeout`: a package that failed leaves Installer open on its summary screen.
    public var settleTimeout: TimeInterval
    public init(timeout: TimeInterval = 30 * 60, interval: TimeInterval = 2, stableReads: Int = 3,
                settleInterval: TimeInterval = 5, settleTimeout: TimeInterval = 5 * 60) {
        self.timeout = timeout; self.interval = interval; self.stableReads = max(1, stableReads)
        self.settleInterval = settleInterval; self.settleTimeout = settleTimeout
    }

    public func waitForInstaller(appAt path: String, installed: BundleFacts, interaction: AdminInteraction) async -> InstallerWaitResult {
        let deadline = Date().addingTimeInterval(timeout)
        var candidate: BundleFacts?
        var stable = 0
        while true {
            if interaction.userSaysFinished { return .finishedByUser }
            if let facts = try? BundleFacts.read(bundleAt: path), facts != installed {
                if facts == candidate { stable += 1 } else { candidate = facts; stable = 1 }
                if stable >= stableReads { return .changed }
            } else {
                candidate = nil; stable = 0
            }
            if Date() >= deadline || Task.isCancelled { return .timedOut }
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
        }
    }
}

// MARK: Everything the admin path needs

/// The admin path's seams, and which of its two parts are switched on. An installer without one (or
/// with a part off) never uses that part.
public struct AdminUpdatePath: Sendable {
    public let replacer: any PrivilegedReplacing
    public let packages: any PackageVerifying
    public let opener: any PackageInstallerOpening
    public let waiter: any InstallerCompletionWaiting
    public let session: any InteractiveSessionChecking
    /// Root-owned apps through macOS's prompt (PATCHED_ENABLE_ADMIN_UPDATES).
    public let allowsReplacement: Bool
    /// `.pkg` through Apple's Installer (on unless PATCHED_ENABLE_PKG_UPDATES=0).
    public let allowsPackages: Bool

    public init(replacer: any PrivilegedReplacing, packages: any PackageVerifying, opener: any PackageInstallerOpening,
                waiter: any InstallerCompletionWaiting, session: any InteractiveSessionChecking,
                allowsReplacement: Bool, allowsPackages: Bool) {
        self.replacer = replacer; self.packages = packages; self.opener = opener; self.waiter = waiter; self.session = session
        self.allowsReplacement = allowsReplacement; self.allowsPackages = allowsPackages
    }

    /// The real macOS pieces, with the chosen parts switched on.
    public static func system(replacement: Bool, packages: Bool) -> AdminUpdatePath {
        AdminUpdatePath(replacer: WorkspacePrivilegedReplacer(), packages: SystemPackageVerifier(), opener: SystemInstallerOpener(),
                        waiter: VersionPollingWaiter(), session: ConsoleSessionCheck(),
                        allowsReplacement: replacement, allowsPackages: packages)
    }

    /// The real pieces for whichever parts are switched on (environment variable or CLI flag); nil when neither is.
    public static func ifEnabled(adminFlag: Bool = false, packageFlag: Bool = false,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> AdminUpdatePath? {
        let replacement = adminFlag || AdminUpdateFlag.isEnabled(environment: environment)
        let packages = packageFlag || AdminUpdateFlag.isPackageEnabled(environment: environment)
        return replacement || packages ? system(replacement: replacement, packages: packages) : nil
    }
}
