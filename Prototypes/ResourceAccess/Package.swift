// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SumoResourceAccess",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [
        .library(name: "ResourceAccessCore", targets: ["ResourceAccessCore"]),
        .library(name: "ResourceAccessHTTP", targets: ["ResourceAccessHTTP"]),
        .library(name: "ResourceAccessSMB", targets: ["ResourceAccessSMB"]),
        .library(name: "PlaybackCoordination", targets: ["PlaybackCoordination"])
    ],
    targets: [
        .target(name: "ResourceAccessCore"),
        .target(name: "ResourceAccessHTTP", dependencies: ["ResourceAccessCore"]),
        .target(name: "ResourceAccessSMB", dependencies: ["ResourceAccessCore"]),
        .target(name: "PlaybackCoordination", dependencies: ["ResourceAccessCore"]),
        .testTarget(name: "ResourceAccessTests", dependencies: [
            "ResourceAccessCore", "ResourceAccessHTTP", "ResourceAccessSMB", "PlaybackCoordination"
        ])
    ],
    swiftLanguageModes: [.v5]
)
