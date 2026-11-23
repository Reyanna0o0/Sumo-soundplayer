// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ImportRegression", platforms: [.macOS(.v13)], dependencies: [
    .package(path: "../../hibiki"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", revision: "22787ffb59de99e5dc1fbfe80b19c97a904ad48d")
], targets: [.executableTarget(name: "CoreRegression", dependencies: [
    .product(name: "HibikiCore", package: "hibiki"),
    .product(name: "ZIPFoundation", package: "ZIPFoundation")
], path: "Sources")], swiftLanguageModes: [.v5])
