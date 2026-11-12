// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EchoesCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "EchoesCore", targets: ["EchoesCore"])],
    targets: [
        .target(name: "EchoesCore"),
        .testTarget(name: "EchoesCoreTests", dependencies: ["EchoesCore"]),
    ]
)
