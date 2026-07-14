// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YouTubeFullscreen",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "YouTubeFullscreen",
            path: "Sources/YouTubeFullscreen"
        )
    ]
)
