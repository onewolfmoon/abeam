// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "vga",
    platforms: [.macOS(.v26)],
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
            dependencies: ["SignalingCore"]
        ),
    ]
)
