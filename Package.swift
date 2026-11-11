// swift-tools-version: 5.10
import PackageDescription

// The mail engine: JMAP client, models and compose helpers. Foundation only, so it builds and tests on Linux too.
// The app, its widget and its Share extension are in Wren.xcodeproj (made from project.yml), which uses this package.
let package = Package(
    name: "WrenKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WrenKit", targets: ["WrenKit"])],
    targets: [
        .target(name: "WrenKit"),
        .testTarget(name: "WrenKitTests", dependencies: ["WrenKit"]),
    ]
)
