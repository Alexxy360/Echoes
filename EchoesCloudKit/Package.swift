// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EchoesCloudKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "EchoesCloudKit", targets: ["EchoesCloudKit"])],
    targets: [
        .target(name: "EchoesCloudKit"),
        .testTarget(name: "EchoesCloudKitTests", dependencies: ["EchoesCloudKit"]),
    ]
)
