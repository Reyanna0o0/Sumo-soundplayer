// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HibikiCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v18)
    ],
    products: [
        .library(name: "HibikiCore", targets: ["HibikiCore"]),
        .executable(name: "SelfTest", targets: ["SelfTest"])
    ],
    targets: [
        .target(name: "HibikiCore"),
        // 自建测试执行器：命令行工具里没有 XCTest，用可执行目标跑断言
        .executableTarget(
            name: "ASRTool",
            dependencies: ["HibikiCore"]
        ),
        .executableTarget(
            name: "ScriptProbe",
            dependencies: ["HibikiCore"]
        ),
        .executableTarget(name: "SelfTest", dependencies: ["HibikiCore"]),
        .executableTarget(name: "ScanProbe", dependencies: ["HibikiCore"]),
    ],
    swiftLanguageModes: [.v5]
)
