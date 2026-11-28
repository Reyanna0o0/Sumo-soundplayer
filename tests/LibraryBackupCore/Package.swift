// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LibraryBackupCoreTests", platforms: [.macOS(.v13)], dependencies: [
    .package(path: "../../hibiki"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", revision: "22787ffb59de99e5dc1fbfe80b19c97a904ad48d")
], targets: [
    .target(name: "BackupCore", dependencies: [.product(name: "HibikiCore", package: "hibiki"), .product(name: "ZIPFoundation", package: "ZIPFoundation")], path: "Sources"),
    .testTarget(name: "BackupTests", dependencies: ["BackupCore", .product(name: "HibikiCore", package: "hibiki")], path: "Tests")
], swiftLanguageModes: [.v5])
