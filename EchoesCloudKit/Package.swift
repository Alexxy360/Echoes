// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EchoesCloudKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "EchoesCloudKit", targets: ["EchoesCloudKit"])],
    dependencies: [.package(path: "../EchoesCore")],
    targets: [
        .target(name: "EchoesCloudKit", dependencies: [.product(name: "EchoesCore", package: "EchoesCore")]),
        .testTarget(name: "EchoesCloudKitTests", dependencies: ["EchoesCloudKit"]),
    ]
)
