// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MirrorKit",
    // Mirroring requires iOS 27+. However, since Abeam disables mirroring on
    // platforms that don't have ScreenCaptureKit, it's easier just to make this
    // package always include-able on any platform Abeam builds on.
    //
    // TODO: Figure out whether conditional inclusion of this library based on
    // availability of ScreenCaptureKit is possible.
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "MirrorKit", targets: ["MirrorKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/onewolfmoon/WebRTC", from: "150.0.0")
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
