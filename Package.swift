// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Blittie",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SignalingCore", targets: ["SignalingCore"]),
        .library(name: "ReceiverProtocol", targets: ["ReceiverProtocol"]),
    ],
    targets: [
        .target(
            name: "SignalingCore",
            resources: [.copy("Resources")]
        ),
        .target(
            name: "ReceiverProtocol"
        ),
        .executableTarget(
            name: "BlittieProjector",
            dependencies: ["SignalingCore", "ReceiverProtocol"]
        ),
        .executableTarget(
            name: "BlittieScreen",
            dependencies: ["SignalingCore", "ReceiverProtocol"]
        ),
        .testTarget(
            name: "ReceiverProtocolTests",
            dependencies: ["ReceiverProtocol"]
        ),
        .testTarget(
            name: "BlittieScreenTests",
            dependencies: ["BlittieScreen"]
        ),
    ]
)
