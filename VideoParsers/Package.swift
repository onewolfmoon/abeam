// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VideoParsers",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VideoParsers", targets: ["VideoParsers"])
    ],
    dependencies: [
        .package(path: "../SignalingCore")
    ],
    targets: [
        .target(
            name: "VideoParsers",
            dependencies: ["SignalingCore"]
        ),
        .testTarget(
            name: "VideoParsersTests",
            dependencies: ["VideoParsers"]
        ),
    ]
)
