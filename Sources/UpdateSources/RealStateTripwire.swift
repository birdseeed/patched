import Foundation

/// Test tripwire. When `PATCHED_FORBID_REAL_STATE=1` is set, code that would resolve the owner's real
/// state folders (home Library, catalogue, caches) refuses instead. The production app and CLI never set it.
public enum RealStateTripwire {
    public static let variable = "PATCHED_FORBID_REAL_STATE"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var trips = 0

    public static var isActive: Bool { ProcessInfo.processInfo.environment[variable] == "1" }
    /// How many times real state was requested while the tripwire was active (including swallowed errors).
    public static var tripCount: Int { lock.lock(); defer { lock.unlock() }; return trips }

    public struct Forbidden: Error, Sendable, CustomStringConvertible {
        public let what: String
        public var description: String {
            "\(RealStateTripwire.variable)=1: refusing to touch real user state (\(what)); inject a temporary location"
        }
    }

    /// Throws `Forbidden` (and logs to stderr and counts) when the tripwire is active.
    public static func check(_ what: String) throws {
        guard isActive else { return }
        lock.lock(); trips += 1; lock.unlock()
        let error = Forbidden(what: what)
        FileHandle.standardError.write(Data(("REAL-STATE-TRIPWIRE: \(error)\n").utf8))
        throw error
    }
}
