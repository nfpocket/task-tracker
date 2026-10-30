// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TaskTrackerCore"),
        .executableTarget(name: "TaskTracker", dependencies: ["TaskTrackerCore"]),
        .testTarget(name: "TaskTrackerCoreTests", dependencies: ["TaskTrackerCore"]),
        .testTarget(name: "TaskTrackerTests", dependencies: ["TaskTracker", "TaskTrackerCore"]),
    ]
)
