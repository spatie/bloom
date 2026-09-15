// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BloomAuthentication",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "BloomAuthentication", targets: ["BloomAuthentication"])],
    dependencies: [
        .package(path: "../BloomClient"),
        .package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0"),
    ],
    targets: [.target(name: "BloomAuthentication", dependencies: ["BloomClient", .product(name: "AppAuth", package: "AppAuth-iOS")])]
)
