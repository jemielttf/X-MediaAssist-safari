// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XMediaAssistCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "XMediaAssistCore", targets: ["XMediaAssistCore"])],
    targets: [
        .target(name: "XMediaAssistCore", path: "Native"),
        .testTarget(name: "XMediaAssistCoreTests", dependencies: ["XMediaAssistCore"], path: "Tests/Native")
    ]
)
