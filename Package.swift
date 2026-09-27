// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RayDesk",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CGVirtualDisplayPrivate", path: "Sources/CGVirtualDisplayPrivate"),
        .target(name: "RayDeskCore", path: "Sources/RayDeskCore"),
        .executableTarget(
            name: "RayDesk",
            dependencies: ["CGVirtualDisplayPrivate", "RayDeskCore"],
            path: "Sources/RayDesk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RayDeskCoreTests",
            dependencies: ["RayDeskCore"],
            path: "Tests/RayDeskCoreTests"
        ),
    ]
)
