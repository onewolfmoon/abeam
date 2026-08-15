// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SignalingCore",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "SignalingCore", targets: ["SignalingCore"]),
    ],
    targets: [
        .target(
            name: "SignalingCore"
        ),
    ]
)
