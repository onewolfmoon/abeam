// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "SignalingCore",
    platforms: [.macOS(.v13), .iOS(.v27)],
    products: [
        .library(name: "SignalingCore", targets: ["SignalingCore"]),
    ],
    targets: [
        .target(
            name: "SignalingCore"
        ),
    ]
)
