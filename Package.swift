// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bloom",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Bloom", targets: ["Bloom"]),
        .executable(name: "bloom-bridge", targets: ["bloom-bridge"]),
        .executable(name: "bloom-sleep-helper", targets: ["bloom-sleep-helper"]),
        .executable(name: "bloom-mail-server", targets: ["bloom-mail-server"]),
        .library(name: "BloomCore", targets: ["BloomCore"]),
    ],
    dependencies: [
        // Native live Markdown editing for workspace notes.
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "0.12.0"),
        // SwiftTerm 1.20.0 is a prerelease with API changes.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.19.0" ..< "1.20.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
        .package(url: "https://github.com/spatie/flare-client-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "BloomCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "Bloom",
            dependencies: [
                "BloomCore",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Flare", package: "flare-client-swift"),
                .product(name: "FlareCrashReporter", package: "flare-client-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "bloom-bridge",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "bloom-sleep-helper",
            path: "Sources/bloom-sleep-helper",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "bloom-mail-server",
            path: "Sources/bloom-mail-server",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BloomCoreTests",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
