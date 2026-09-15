// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BloomSSH",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "BloomSSH", targets: ["BloomSSH"])],
    dependencies: [
        .package(path: "../BloomClient"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "BloomSSH", dependencies: ["BloomClient", .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "BloomSSHTests", dependencies: ["BloomSSH"]),
    ]
)
