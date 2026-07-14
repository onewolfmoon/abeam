// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "vga",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SignalingCore", targets: ["SignalingCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMinor(from: "0.27.0")),
    ],
    targets: [
        .target(
            name: "SignalingCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "Sender",
            dependencies: ["SignalingCore"]
        ),
        .executableTarget(
            name: "Receiver",
            dependencies: ["SignalingCore", "FlyingFox"]
        ),
    ]
)
