// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ProjectorKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ProjectorKit", targets: ["ProjectorKit"]),
    ],
    targets: [
        .target(name: "ProjectorKit"),
    ]
)
