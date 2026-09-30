// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "XMediaAssistCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "XMediaAssistCore", targets: ["XMediaAssistCore"])],
    targets: [
        .target(name: "XMediaAssistAppSupport", path: "AppSupport"),
        .testTarget(name: "XMediaAssistAppSupportTests", dependencies: ["XMediaAssistAppSupport"], path: "Tests/AppSupport"),
        .systemLibrary(name: "CGifski", path: "Native/CGifski"),
        .target(name: "XMediaAssistCore", dependencies: ["CGifski"], path: "Native", exclude: ["CGifski"],
                linkerSettings: [.unsafeFlags(["-L", root + "/build/gifski-universal"])]),
        .testTarget(name: "XMediaAssistCoreTests", dependencies: ["XMediaAssistCore"], path: "Tests/Native")
    ]
)
