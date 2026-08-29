// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SignalingCore",
    platforms: [.macOS(.v13), .iOS(.v13)],
    products: [
        .library(name: "SignalingCore", targets: ["SignalingCore"]),
    ],
    targets: [
        .target(
            name: "SignalingCore"
        ),
    ]
)
