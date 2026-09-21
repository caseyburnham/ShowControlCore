// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ShowControlCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "ShowControlCore", targets: ["ShowControlCore"])
    ],
    targets: [
        .target(name: "ShowControlCore"),
        .testTarget(name: "ShowControlCoreTests", dependencies: ["ShowControlCore"])
    ],
    swiftLanguageModes: [.v6]
)
