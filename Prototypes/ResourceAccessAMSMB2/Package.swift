// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResourceAccessAMSMB2",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [.library(name: "ResourceAccessAMSMB2", targets: ["ResourceAccessAMSMB2"])],
    dependencies: [
        .package(path: "../ResourceAccess"),
        // Complete, pinned 4.0.3 sources with the documented local callback/error patch.
        .package(path: "../Vendor/AMSMB2")
    ],
    targets: [
        .target(name: "ResourceAccessAMSMB2", dependencies: [
            .product(name: "ResourceAccessCore", package: "ResourceAccess"),
            .product(name: "ResourceAccessSMB", package: "ResourceAccess"),
            .product(name: "AMSMB2", package: "AMSMB2")
        ]),
        .testTarget(name: "ResourceAccessAMSMB2Tests", dependencies: ["ResourceAccessAMSMB2"])
    ],
    swiftLanguageModes: [.v5]
)
