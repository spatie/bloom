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
        // The updater. Sparkle ships as a binary XCFramework, so `swift build` links the app
        // against it but copies nothing: `build.sh` embeds `Sparkle.framework` into
        // `Contents/Frameworks` and adds the rpath that finds it there. See `build.sh`.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
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
                .product(name: "Sparkle", package: "Sparkle"),
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
