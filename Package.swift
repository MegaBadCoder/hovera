// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RayDesk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CGVirtualDisplayPrivate", path: "Sources/CGVirtualDisplayPrivate"),
        .executableTarget(
            name: "RayDesk",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/RayDesk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
