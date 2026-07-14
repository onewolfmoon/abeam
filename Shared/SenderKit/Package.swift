// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SenderKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SenderKit", targets: ["SenderKit"]),
    ],
    targets: [
        .target(name: "SenderKit"),
    ]
)
