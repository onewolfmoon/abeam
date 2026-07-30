// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "MirrorKit",
    // iOS 27 minimum because SCContentSharingPicker/SCStream are iOS-available
    // starting there; macOS's ScreenCaptureKit APIs used here only need 12.3+,
    // but macOS 15 is kept as the floor to match vga's own Package.swift.
    platforms: [.macOS(.v15), .iOS(.v27)],
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
