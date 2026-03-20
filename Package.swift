// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlowDeckDaemon",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DaemonCore",
            path: "Sources/DaemonCore"
        ),
        .executableTarget(
            name: "switchboard",
            dependencies: ["DaemonCore"],
            path: "Sources/Daemon"
        ),
        .testTarget(
            name: "DaemonCoreTests",
            dependencies: ["DaemonCore"],
            path: "Tests/DaemonCoreTests"
        ),
    ]
)
