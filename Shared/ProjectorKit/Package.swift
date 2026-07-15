// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ProjectorKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "ProjectorKit", targets: ["ProjectorKit"]),
    ],
    targets: [
        .target(name: "ProjectorKit"),
    ]
)
