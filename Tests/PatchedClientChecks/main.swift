import Foundation
import Darwin
import SwiftUI
import UpdateSources
@_spi(Testing) import PatchedClient

// Acceptance checks for the PatchedClient library: the local inventory, installed icons and vendor
// metadata, the native shell, menu, first-run setup and settings.
//
// No app is launched, nothing is mounted or downloaded, and no network is used.
// loopback peers. Disposable directories and painted pictures are the only writes, and both are new
// directories beneath this worktree's .build.

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

var cases: [(String, @MainActor () async throws -> Void)] = []
@MainActor func check(_ name: String, _ action: @escaping @MainActor () async throws -> Void) { cases.append((name, action)) }

@MainActor func until(_ what: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<1000 { if await condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
    throw CheckFailure(description: "Timed out waiting for \(what)")
}

// Additive native-menu lifecycle/image slice; original 15-check focused gate stays exact.
if CommandLine.arguments.contains("--native-menu-reopen") {
    registerNativeMenuReopenChecks()
    guard cases.count == 8 else {
        print("FAIL menu reopen: expected 8 checks, got \(cases.count)"); exit(1)
    }
    var errors = 0
    for (name, action) in cases {
        do { try await action(); print("PASS client: \(name)") }
        catch { errors += 1; print("FAIL client: \(name): \(error)") }
    }
    print("Menu reopen acceptance: \(cases.count) cases, \(errors) failures. Inactive adapter/image/source proof only; native proof remains separate.")
    exit(errors == 0 ? 0 : 1)
}

// native-menu focused registration follows the shared fixture URL initialisation.
if CommandLine.arguments.contains("--native-menu") {
    registerNativeMenuIntegrationChecks()
    guard cases.count == 10 else {
        print("FAIL native menu integration: expected 10 independently prepared checks, got \(cases.count)")
        exit(1)
    }
    var focusedFailures = 0
    for (name, action) in cases {
        do { try await action(); print("PASS client: \(name)") }
        catch { focusedFailures += 1; print("FAIL client: \(name): \(error)") }
    }
    print("Native menu integration acceptance: \(cases.count) cases, \(focusedFailures) failures. Fixture/offscreen/source checks only; native operating acceptance remains separate.")
    exit(focusedFailures == 0 ? 0 : 1)
}

/// The `.build` directory that holds this executable, found independently of the library.
func buildDirectory() throws -> URL {
    guard var build = Bundle.main.executableURL?.resolvingSymlinksInPath() else { throw CheckFailure(description: "Executable path unknown") }
    while build.lastPathComponent != ".build" {
        guard build.pathComponents.count > 1 else { throw CheckFailure(description: "This executable is not beneath a .build directory") }
        build.deleteLastPathComponent()
    }
    guard let physical = realpath(build.path, nil) else { throw CheckFailure(description: "No physical build directory") }
    defer { free(physical) }
    return URL(fileURLWithPath: String(cString: physical))
}
func newDirectory(_ prefix: String) throws -> URL {
    let directory = try buildDirectory().appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try expect(mkdir(directory.path, 0o700) == 0, "Directory was not created exclusively: errno \(errno)")
    return directory
}
func packageRoot() throws -> URL { try buildDirectory().deletingLastPathComponent() }
func source(_ relative: String) throws -> String {
    guard let text = try? String(contentsOf: try packageRoot().appendingPathComponent(relative), encoding: .utf8) else {
        throw CheckFailure(description: "Cannot read \(relative)")
    }
    return text
}
func swiftSources(_ directory: String) throws -> [(String, String)] {
    let root = try packageRoot().appendingPathComponent(directory)
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".swift") }.sorted()
    try expect(!names.isEmpty, "No sources in \(directory)")
    return try names.map { ($0, try source(directory + "/" + $0)) }
}
/// Source with whole-line comments removed, so prose cannot satisfy or trip a check.
func code(_ text: String) -> String { text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n") }
struct Painted { let name: String; let width: Int; let height: Int; let png: Data; let unpainted: Int; let distinct: Int }

// local-inventory additive independent native inventory checks.
registerLocalInventoryChecks()

// native-shell additive independent native shell composition checks.
if CommandLine.arguments.contains("--native-shell-composition") { cases.removeAll() }
registerNativeShellCompositionChecks()

// native-menu registers once in the ordinary gate; existing focused gates retain their scope.
if !CommandLine.arguments.contains("--native-shell-composition") { registerNativeMenuIntegrationChecks() }

// vendor-metadata additive installed vendor metadata extraction checks.
if !CommandLine.arguments.contains("--native-shell-composition") { registerInstalledVendorMetadataChecks() }

if !CommandLine.arguments.contains("--native-shell-composition") { registerSettingsChecks() }

// first-run additive independent controller checks; preserve older focused scopes.
if CommandLine.arguments.contains("--native-first-run") {
    cases.removeAll()
    registerSetupChecks()
} else if !CommandLine.arguments.contains("--native-shell-composition") {
    registerSetupChecks()
}

// product-metadata final focus preserves every pre-existing focused scope.
if CommandLine.arguments.contains("--product-metadata") {
    cases.removeAll()
    registerVSCodeProductMetadataChecks()
} else if !CommandLine.arguments.contains("--native-shell-composition") && !CommandLine.arguments.contains("--native-first-run") {
    registerVSCodeProductMetadataChecks()
}

// native-shell additive installed-icon checks. Earlier focused scopes remain exact.
if CommandLine.arguments.contains("--installed-icon-fixtures") {
    cases.removeAll()
    registerInstalledIconFixturePreflightChecks()
} else if CommandLine.arguments.contains("--installed-icons") {
    cases.removeAll()
    registerInstalledIconFixturePreflightChecks()
    registerInstalledIconChecks()
} else if !CommandLine.arguments.contains("--native-shell-composition") &&
          !CommandLine.arguments.contains("--native-first-run") &&
          !CommandLine.arguments.contains("--product-metadata") {
    registerInstalledIconFixturePreflightChecks()
    registerInstalledIconChecks()
}

// Register in the ordinary no-argument full gate without altering older focused scopes.
if CommandLine.arguments.count == 1 { registerNativeMenuReopenChecks() }

if CommandLine.arguments.count == 1 { registerRealStateTripwireChecks() }

if CommandLine.arguments.count == 1 { registerWindowPresenceChecks() }

var failures = 0
for (name, action) in cases {
    do { try await action(); print("PASS client: \(name)") }
    catch { failures += 1; print("FAIL client: \(name): \(error)") }
}
// Any trip beyond the deliberate ones means something asked for real user state, even if it swallowed the error.
if RealStateTripwire.tripCount != deliberateTripwireTrips {
    failures += 1
    print("FAIL client: real-state tripwire tripped \(RealStateTripwire.tripCount - deliberateTripwireTrips) time(s) beyond the deliberate checks; a check touched real user state")
}
print("Client flow acceptance: \(cases.count) cases, \(failures) failures. Test doubles are labelled and grant nothing. No download, mount, installation or launch.")
exit(failures == 0 ? 0 : 1)
