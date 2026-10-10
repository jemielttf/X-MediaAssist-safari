// swift-tools-version: 5.9
// Builds the shared Swift sources for `swift test`. The shipped app and extension are
// built by the Xcode project, which compiles these same source folders.
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "XMediaAssistCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "XMediaAssistCore", targets: ["XMediaAssistCore"])],
    targets: [
        // GIF options shared by the app and the extension through the App Group.
        .target(name: "XMediaAssistPreferences", path: "Shared"),

        // App-only preferences (Dock, login item).
        .target(name: "XMediaAssistAppSupport", dependencies: ["XMediaAssistPreferences"], path: "AppSupport"),
        .testTarget(name: "XMediaAssistAppSupportTests", dependencies: ["XMediaAssistAppSupport"],
                    path: "Tests/AppSupport"),

        // Download, save and GIF conversion. libgifski.a comes from script/build_gifski.sh.
        .systemLibrary(name: "CGifski", path: "Native/CGifski"),
        .target(name: "XMediaAssistCore", dependencies: ["CGifski", "XMediaAssistPreferences"],
                path: "Native", exclude: ["CGifski"],
                linkerSettings: [.unsafeFlags(["-L", root + "/build/gifski-universal"])]),
        .testTarget(name: "XMediaAssistCoreTests", dependencies: ["XMediaAssistCore"], path: "Tests/Native")
    ]
)
