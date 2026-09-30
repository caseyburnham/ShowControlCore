// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ShowControlCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "ShowControlCore", targets: ["ShowControlCore"]),
        .library(name: "ShowControlUI", targets: ["ShowControlUI"])
    ],
    targets: [
        .target(name: "ShowControlCore"),
        // SwiftUI, AppKit and UIKit glue both apps use identically. Main-actor by
        // default, like the apps themselves.
        .target(
            name: "ShowControlUI",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ShowControlCoreTests", dependencies: ["ShowControlCore"])
    ],
    swiftLanguageModes: [.v6]
)
