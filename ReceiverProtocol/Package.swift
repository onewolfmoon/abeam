// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReceiverProtocol",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ReceiverProtocol", targets: ["ReceiverProtocol"])
    ],
    targets: [
        .target(
            name: "ReceiverProtocol"
        ),
        .testTarget(
            name: "ReceiverProtocolTests",
            dependencies: ["ReceiverProtocol"]
        ),
    ]
)
