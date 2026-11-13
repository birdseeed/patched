import Foundation

/// Runs a fixed system tool by absolute path with an argv array: no shell, stdin from /dev/null,
/// a minimal environment, bounded output capture and a hard timeout.
public enum ProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let timedOut: Bool
        public let stdout: String
        public let stderr: String
        /// Set when the watchdog stopped the process; the watchdog's reason.
        public var abortedBy: String? = nil
        public var succeeded: Bool { !timedOut && abortedBy == nil && status == 0 }
        /// Public so the package verifier's checks can feed it recorded tool output.
        public init(status: Int32, timedOut: Bool, stdout: String, stderr: String, abortedBy: String? = nil) {
            self.status = status; self.timedOut = timedOut; self.stdout = stdout; self.stderr = stderr; self.abortedBy = abortedBy
        }
        /// Short one-line summary for refusal messages.
        public var summary: String {
            if timedOut { return "timed out" }
            if let abortedBy { return "stopped: \(abortedBy)" }
            let text = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            // hdiutil prints deprecation warnings first; the useful line is the last real one.
            let lines = text.split(separator: "\n").map(String.init).filter { !$0.contains("WARNING:") }
            let firstLine = lines.last ?? ""
            return "exit \(status)" + (firstLine.isEmpty ? "" : ": \(firstLine.prefix(300))")
        }
    }

    /// The only programs the installer may start. `pkgutil` (read-only package signature check) and
    /// `open` (hands a verified package to Apple's Installer) are used by the admin path; `codesign` (verify
    /// only) and `open` (reopen the new Patched) by Patched's self-update.
    public static let allowedTools: Set<String> = ["/usr/bin/ditto", "/usr/bin/hdiutil", "/usr/sbin/spctl",
                                                   "/usr/sbin/pkgutil", "/usr/bin/open", "/usr/bin/codesign", "/bin/launchctl"]
    static let captureLimit = 256 * 1024

    private final class Verdict: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        private var halted = false
        func set(_ reason: String) { lock.withLock { if value == nil { value = reason } } }
        var reason: String? { lock.withLock { value } }
        private var childExited = false
        let wake = DispatchSemaphore(value: 0)
        func stop() { lock.withLock { halted = true }; wake.signal() }
        var stopped: Bool { lock.withLock { halted } }
        func markExited() { lock.withLock { childExited = true }; wake.signal() }
        var exited: Bool { lock.withLock { childExited } }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < ProcessRunner.captureLimit { data.append(chunk.prefix(ProcessRunner.captureLimit - data.count)) }
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// `watchdog`, if given, runs on its own thread every `pollInterval` while the process runs, so a slow
    /// scan can never delay the timeout. Returning a reason terminates the process (SIGTERM, then SIGKILL).
    /// It also runs once more after the process exits, so a run that finishes between polls is still judged.
    public static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval,
                           pollInterval: TimeInterval = 0.25, watchdog: (@Sendable () -> String?)? = nil) -> Output {
        guard allowedTools.contains(tool) else {
            return Output(status: -1, timedOut: false, stdout: "", stderr: "tool not allowed: \(tool)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = Capture(), err = Capture()
        let outEOF = DispatchSemaphore(value: 0), errEOF = DispatchSemaphore(value: 0)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; outEOF.signal() } else { out.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; errEOF.signal() } else { err.append(chunk) }
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return Output(status: -1, timedOut: false, stdout: "", stderr: "could not start \(tool): \(error.localizedDescription)")
        }
        var timedOut = false
        var abortedBy: String?
        let deadline = Date().addingTimeInterval(timeout)
        let verdict = Verdict()
        // One worker runs every scan, so two never overlap. After the child exits it runs one more scan that
        // started after the exit (the final budget verdict) and signals `finalDone`.
        let finalDone = DispatchSemaphore(value: 0)
        if let watchdog {
            let thread = Thread {
                while true {
                    let afterExit = verdict.exited
                    if let reason = watchdog() { verdict.set(reason); finalDone.signal(); return }
                    if afterExit || verdict.stopped { finalDone.signal(); return }
                    _ = verdict.wake.wait(timeout: .now() + pollInterval)
                }
            }
            thread.start()
        }
        var finished = false
        while true {
            let slice = min(watchdog == nil ? timeout : min(pollInterval, 0.05), max(0, deadline.timeIntervalSinceNow))
            if done.wait(timeout: .now() + slice) == .success { finished = true; break }
            if let reason = verdict.reason { abortedBy = reason; break }
            if Date() >= deadline { timedOut = true; break }
        }
        if finished, abortedBy == nil, watchdog != nil {
            // Final check, under the same deadline: the process may have finished between polls.
            verdict.markExited()
            if finalDone.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
                // Never report success without the final verdict: this is a timeout.
                timedOut = true
            } else {
                abortedBy = verdict.reason
            }
        }
        verdict.stop()
        if !finished {
            process.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 5)
            }
        }
        // Let the readers reach end of file, but never block on a helper that inherited the pipe.
        _ = outEOF.wait(timeout: .now() + 2)
        _ = errEOF.wait(timeout: .now() + 2)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        return Output(status: process.isRunning ? -1 : process.terminationStatus, timedOut: timedOut,
                      stdout: out.text, stderr: err.text, abortedBy: abortedBy)
    }
}
