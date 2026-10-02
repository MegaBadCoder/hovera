// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RayDesk",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CGVirtualDisplayPrivate", path: "Sources/CGVirtualDisplayPrivate"),
        .target(name: "RayDeskCore", path: "Sources/RayDeskCore"),
        .target(name: "CAprilTag", path: "Sources/CAprilTag", exclude: ["LICENSE.md", "UPSTREAM.txt"],
                publicHeadersPath: "include", cSettings: [.headerSearchPath("upstream")]),
        .target(name: "AprilTagTracking", dependencies: ["CAprilTag", "RayDeskCore"]),
        .executableTarget(
            name: "RayDesk",
            dependencies: ["CGVirtualDisplayPrivate", "RayDeskCore", "AprilTagTracking"],
            path: "Sources/RayDesk",
            exclude: ["Models"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RayDeskCoreTests",
            dependencies: ["RayDeskCore", "AprilTagTracking"],
            path: "Tests/RayDeskCoreTests",
            exclude: ["Fixtures"]
        ),
    ]
)
