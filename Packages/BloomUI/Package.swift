// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BloomUI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "BloomUI", targets: ["BloomUI"])],
    dependencies: [.package(path: "../BloomClient")],
    targets: [.target(name: "BloomUI", dependencies: ["BloomClient"])]
)
