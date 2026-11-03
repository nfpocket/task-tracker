// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskTracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TaskTracker", targets: ["TaskTracker"]),
        // What agents call to put checks and ideas on the menu: see Sources/MenuCLI.
        .executable(name: "menu", targets: ["MenuCLI"]),
    ],
    targets: [
        .target(name: "TaskTrackerCore"),
        .executableTarget(name: "TaskTracker", dependencies: ["TaskTrackerCore"]),
        .executableTarget(name: "MenuCLI", dependencies: ["TaskTrackerCore"]),
        .testTarget(name: "TaskTrackerCoreTests", dependencies: ["TaskTrackerCore"]),
        .testTarget(name: "TaskTrackerTests", dependencies: ["TaskTracker", "TaskTrackerCore"]),
    ]
)
