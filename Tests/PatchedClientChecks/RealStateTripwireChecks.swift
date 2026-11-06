import Foundation
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

/// Trips the checks themselves caused on purpose; the end-of-run guard allows exactly these.
nonisolated(unsafe) var deliberateTripwireTrips = 0

@MainActor func registerRealStateTripwireChecks() {
    check("real-state tripwire: constructing the production session resolves no real state") {
        let previous = ProcessInfo.processInfo.environment[RealStateTripwire.variable]
        setenv(RealStateTripwire.variable, "1", 1)
        defer { if let previous { setenv(RealStateTripwire.variable, previous, 1) } else { unsetenv(RealStateTripwire.variable) } }
        let before = RealStateTripwire.tripCount
        let session = NativeClientSession()
        _ = session.appUpdates
        _ = AppUpdatesController.live()
        try expect(RealStateTripwire.tripCount == before, "constructing the session or live controller resolved real state")
        try expect(session.appUpdates.catalogueError == nil && session.appUpdates.notice == nil, "construction reported a state problem")
    }
    check("real-state tripwire: the real resolvers refuse when it is set, and say why") {
        let previous = ProcessInfo.processInfo.environment[RealStateTripwire.variable]
        setenv(RealStateTripwire.variable, "1", 1)
        defer { if let previous { setenv(RealStateTripwire.variable, previous, 1) } else { unsetenv(RealStateTripwire.variable) } }
        let before = RealStateTripwire.tripCount
        do { _ = try InstallerLocations.standard(); throw CheckFailure(description: "standard() resolved real state") }
        catch let error as RealStateTripwire.Forbidden { try expect(error.description.contains("PATCHED_FORBID_REAL_STATE"), "unclear message: \(error)") }
        do { _ = try UserCatalogue.load(); throw CheckFailure(description: "default catalogue was read") }
        catch is CatalogueError {}
        try expect(RealStateTripwire.tripCount == before + 2, "trips not counted")
        deliberateTripwireTrips += 2
    }
}
