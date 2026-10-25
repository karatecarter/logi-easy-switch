// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Switchboard", targets: ["LogiEasySwitchApp"]),
    ],
    targets: [
        .executableTarget(name: "LogiEasySwitchApp"),
        .testTarget(name: "LogiEasySwitchAppTests", dependencies: ["LogiEasySwitchApp"]),
    ],
    swiftLanguageModes: [.v5]
)
