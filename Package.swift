// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bloom",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Bloom", targets: ["Bloom"]),
        .library(name: "BloomCore", targets: ["BloomCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "BloomCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Bloom",
            dependencies: [
                "BloomCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BloomCoreTests",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
