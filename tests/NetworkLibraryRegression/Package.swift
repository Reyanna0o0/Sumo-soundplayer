// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NetworkLibraryRegression", platforms: [.macOS(.v13)], dependencies: [
    .package(path: "../../hibiki")
], targets: [
    .testTarget(name: "NetworkLibraryTests", dependencies: [.product(name: "HibikiCore", package: "hibiki")], path: "Tests")
], swiftLanguageModes: [.v5])
