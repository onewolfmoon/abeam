// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "MirrorKit",
    // Package floor is NOT iOS 27 even though SCContentSharingPicker/SCStream
    // only become available there: those specific types carry their own
    // @available(iOS 27, *) annotations (see ScreenPicker.swift,
    // ScreenCaptureSession.swift, WebRTCMirrorSession.swift), so the package
    // itself can target the same iOS 17 floor as ReceiverProtocol and still
    // build for pre-27 devices — callers just can't touch the gated types
    // outside an `if #available(iOS 27, *)` block. macOS's ScreenCaptureKit
    // APIs used here only need 12.3+, but macOS 15 is kept as the floor to
    // match vga's own Package.swift.
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "MirrorKit", targets: ["MirrorKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/onewolfmoon/WebRTC", from: "150.0.0"),
    ],
    targets: [
        // Objective-C, not Swift: WebRTC's umbrella header (WebRTC.h) never
        // imports RTCAudioDevice.h, so Swift's ClangImporter only ever sees
        // RTCAudioDevice/RTCAudioDeviceDelegate forward-declared, never
        // concretely -- conforming to RTCAudioDevice from Swift fails with
        // "this Objective-C protocol has only been forward-declared". A
        // plain Objective-C translation unit isn't limited to the umbrella's
        // exported set the same way, so it can import that header directly.
        .target(
            name: "MirrorKitAudioBridge",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
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
