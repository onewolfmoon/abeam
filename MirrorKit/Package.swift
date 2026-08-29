// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "MirrorKit",
    platforms: [.macOS(.v14), .iOS(.v27)],
    products: [
        .library(name: "MirrorKit", targets: ["MirrorKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", from: "150.0.0")
    ],
    targets: [
        // Implemented in Objective C.
        //
        // WebRTC's umbrella header (WebRTC.h) never imports RTCAudioDevice.h,
        // so Swift's ClangImporter only ever sees
        // RTCAudioDevice/RTCAudioDeviceDelegate forward-declared. Conforming to
        // RTCAudioDevice from Swift fails with "this Objective-C protocol has
        // only been forward-declared".
        .target(
            name: "MirrorKitAudioBridge",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ]
        ),
        .target(
            name: "MirrorKit",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
                "MirrorKitAudioBridge",
            ]
        ),
    ]
)
