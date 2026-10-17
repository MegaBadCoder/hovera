// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RayDesk",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CGVirtualDisplayPrivate", path: "Sources/CGVirtualDisplayPrivate"),
        .target(name: "RayDeskLocalization", path: "Sources/RayDeskLocalization"),
        .target(name: "RayDeskCore", dependencies: ["RayDeskLocalization"], path: "Sources/RayDeskCore"),
        .executableTarget(
            name: "RayDesk",
            dependencies: ["CGVirtualDisplayPrivate", "RayDeskCore", "RayDeskLocalization"],
            path: "Sources/RayDesk",
            exclude: ["Models"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RayDeskCoreTests",
            dependencies: ["RayDeskCore", "RayDeskLocalization"],
            path: "Tests/RayDeskCoreTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "RayDeskLocalizationTests",
            dependencies: ["RayDeskLocalization"],
            path: "Tests/RayDeskLocalizationTests"
        ),
    ]
)
