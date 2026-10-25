// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EmberCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "EmberCore", targets: ["EmberCore"])],
    targets: [
        .target(name: "EmberCore", path: "overrides/Feather/Ember/Core"),
        .testTarget(name: "EmberCoreTests", dependencies: ["EmberCore"], path: "Tests")
    ]
)
