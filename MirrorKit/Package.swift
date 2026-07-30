// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MirrorKit",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "MirrorKit", targets: ["MirrorKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", from: "150.0.0"),
    ],
    targets: [
        .target(
            name: "MirrorKit",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
    ]
)
