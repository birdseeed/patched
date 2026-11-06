// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Patched",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PatchedShell", targets: ["PatchedShell"]),
        .executable(name: "patched-shell-checks", targets: ["PatchedShellChecks"]),
        .executable(name: "PatchedApp", targets: ["PatchedApp"]),
        .library(name: "PatchedClient", targets: ["PatchedClient"]),
        .executable(name: "patched-client-checks", targets: ["PatchedClientChecks"]),
        .library(name: "UpdateSources", targets: ["UpdateSources"]),
        .executable(name: "update-sources-checks", targets: ["UpdateSourcesChecks"]),
        .library(name: "UpdateInstaller", targets: ["UpdateInstaller"]),
        .executable(name: "update-installer-checks", targets: ["UpdateInstallerChecks"]),
        .executable(name: "patched-app-updates-checks", targets: ["PatchedAppUpdatesChecks"]),
        .executable(name: "patched", targets: ["PatchedCLI"])
    ],
    targets: [
        .target(name: "PatchedShell"),
        .executableTarget(name: "PatchedShellChecks", dependencies: ["PatchedShell"], path: "Tests/PatchedShellChecks"),
        .target(name: "PatchedClient", dependencies: ["PatchedShell", "UpdateSources", "UpdateInstaller"]),
        .executableTarget(name: "PatchedApp", dependencies: ["PatchedClient", "UpdateInstaller"]),
        .executableTarget(name: "PatchedClientChecks", dependencies: ["PatchedClient", "PatchedShell", "UpdateSources", "UpdateInstaller"],
                          path: "Tests/PatchedClientChecks"),
        .target(name: "UpdateSources"),
        .executableTarget(name: "UpdateSourcesChecks", dependencies: ["UpdateSources"],
                          path: "Tests/UpdateSourcesChecks"),
        .target(name: "UpdateInstaller", dependencies: ["UpdateSources"]),
        .executableTarget(name: "UpdateInstallerChecks", dependencies: ["UpdateInstaller", "UpdateSources"],
                          path: "Tests/UpdateInstallerChecks"),
        .executableTarget(name: "PatchedAppUpdatesChecks", dependencies: ["PatchedClient", "PatchedShell", "UpdateSources", "UpdateInstaller"],
                          path: "Tests/PatchedAppUpdatesChecks"),
        .executableTarget(name: "PatchedCLI", dependencies: ["PatchedClient", "UpdateSources", "UpdateInstaller"])
    ]
)
