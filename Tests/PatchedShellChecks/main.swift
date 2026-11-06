import Foundation
import Darwin

// Additive independent shell-navigation checks. No app, window, helper or service is launched.
struct Failure: Error, CustomStringConvertible { let description: String }
func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(description: message) }
}
var cases: [(String, @MainActor () throws -> Void)] = []
@MainActor func check(_ name: String, _ body: @escaping @MainActor () throws -> Void) {
    cases.append((name, body))
}
registerNavigationChecks()
registerOffscreenChecks()
registerCompactBoundsChecks()
var failures = 0
for (name, body) in cases {
    do { try body(); print("PASS shell: \(name)") }
    catch { failures += 1; print("FAIL shell: \(name): \(error)") }
}
print("Shell fixture/offscreen checks: \(cases.count) cases, \(failures) failures. Native event routing, VoiceOver and installed icons remain unverified.")
exit(failures == 0 ? 0 : 1)
