// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Baton",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Baton", targets: ["Baton"]),
        .library(name: "BatonCore", targets: ["BatonCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "BatonCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Baton",
            dependencies: [
                "BatonCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BatonCoreTests",
            dependencies: ["BatonCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
