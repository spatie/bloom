// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BloomClient",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "BloomClient", targets: ["BloomClient"])],
    targets: [
        .target(name: "BloomClient"),
        .testTarget(name: "BloomClientTests", dependencies: ["BloomClient"]),
    ]
)
