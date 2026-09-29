// swift-tools-version: 6.0
import PackageDescription

// The engine behind both apps and both widgets. It has no UI, no third-party
// dependencies, and no AppKit/UIKit imports, so the same code runs in the Mac
// menu-bar app, the iOS app, and every widget extension — and can be tested
// headlessly with `swift test` without a simulator or a running app.
let package = Package(
    name: "FireworksCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FireworksCore", targets: ["FireworksCore"])
    ],
    targets: [
        .target(name: "FireworksCore"),
        .testTarget(name: "FireworksCoreTests", dependencies: ["FireworksCore"])
    ]
)
