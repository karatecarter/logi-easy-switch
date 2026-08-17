// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogiEasySwitch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LogiEasySwitch", targets: ["LogiEasySwitchApp"]),
    ],
    targets: [
        .executableTarget(name: "LogiEasySwitchApp"),
    ],
    swiftLanguageModes: [.v5]
)
