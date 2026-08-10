// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ReceiverProtocol",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "ReceiverProtocol", targets: ["ReceiverProtocol"]),
    ],
    targets: [
        .target(
            name: "ReceiverProtocol"
        ),
    ]
)
