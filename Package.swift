// swift-tools-version: 6.2
import PackageDescription
#if os(Linux)
import Foundation

let serverTests = [
    "AtomicCrewStartTests.swift",
    "BridgeDrainTests.swift",
    "CodexMcpResultTests.swift",
    "ServerOwnershipTests.swift",
    "ServerConnectionsTests.swift",
    "ServerConnectionProfileTests.swift",
    "ServerReviewLifecycleTests.swift",
    "UnixSocketShutdownTests.swift",
    "ServerWorkspaceAdmissionsTests.swift",
    "ServerArchiveAdmissionTests.swift",
    "ProcessPipeAvailableTests.swift",
    "ServerClientLifecycleTests.swift",
    "ServerMCPTests.swift",
    "ServerUIBrokerTests.swift",
    "ServerPaneSplitTests.swift",
    "ServerTerminalRelayTests.swift",
    "RemoteCreationContractTests.swift",
    "ServerSetupTests.swift",
    "ServerProtocolVectorTests.swift",
    "SharedComposerContractTests.swift",
    "RemoteReviewContractTests.swift",
    "MobileProtocolContractTests.swift",
    "ServerDiagnosticsTests.swift",
    "SetupOutputTests.swift",
    "WorkspacePreviewTests.swift",
    "BrowserAddressDisplayTests.swift",
    "WorkspaceExecutionTests.swift",
    "ServerProjectSettingsTests.swift",
    "ServerReviewCacheTests.swift",
    "CodexRunnerTests.swift",
    "CodexTestSupport.swift",
    "ServerRuntimeTests.swift",
    "ServerReviewTests.swift",
    "ServerWorkspaceTests.swift",
    "ServerSidebarTests.swift",
    "ServerPreviewTests.swift",
    "ServerHTTPTests.swift",
    "ServerTerminalStreamTests.swift",
    "ProcessPipeLifetimeTests.swift",
    "PlanApprovalTests.swift",
    "CodexTranslationTests.swift",
    "LocalServerIdentityTests.swift",
    "TestSupport.swift",
    "ProcessLaunchTests.swift",
    "WorkspaceFileAccessTests.swift",
    "PaneStateNamespaceTests.swift",
    "ServerCrewQueueTests.swift",
    "ServerUIMediaTests.swift",
]
let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Tests/BloomCoreTests")
let otherTests = (try FileManager.default.contentsOfDirectory(atPath: testDirectory.path)).filter { !serverTests.contains($0) }

let package = Package(
    name: "Bloom",
    products: [
        .executable(name: "bloom-server", targets: ["bloom-server"]),
        .executable(name: "bloom-bridge", targets: ["bloom-bridge"]),
        .library(name: "BloomCore", targets: ["BloomCore"]),
    ],
    dependencies: [.package(path: "Packages/BloomClient"), .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2")],
    targets: [
        .systemLibrary(name: "SQLite3", path: "Sources/CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "BloomCore",
            dependencies: [.product(name: "BloomClient", package: "BloomClient"), "SQLite3", .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(name: "bloom-server", dependencies: ["BloomCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "bloom-bridge", dependencies: ["BloomCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "BloomCoreTests", dependencies: ["BloomCore"], path: "Tests/BloomCoreTests",
            exclude: otherTests, sources: serverTests, swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
#else

let package = Package(
    name: "Bloom",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Bloom", targets: ["Bloom"]),
        .executable(name: "bloom-bridge", targets: ["bloom-bridge"]),
        .executable(name: "bloom-server", targets: ["bloom-server"]),
        .library(name: "BloomCore", targets: ["BloomCore"]),
    ],
    dependencies: [
        .package(path: "Packages/BloomClient"),
        .package(path: "Packages/BloomAuthentication"),
        .package(path: "Packages/BloomUI"),
        .package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0"),
        // Native live Markdown editing for workspace notes. Pin the pre-1.0 API we integrate.
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "0.12.0"),
        // The terminal panes. The upper bound is not tidiness: SwiftTerm tags 1.20.0 as a
        // pre-release ("one last before 2.0"), and SwiftPM cannot see that flag because the tag
        // carries no semver pre-release identifier, so a bare `from:` would resolve to it. 1.19.0
        // is what upstream marks as the release, and what upstream says comes next is 2.0 with
        // breaking changes, which this range would have to be opened by hand for anyway.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.19.0" ..< "1.20.0"),
        // The updater. Sparkle ships as a binary XCFramework, so `swift build` links the app
        // against it but copies nothing: `Tools/build.sh` embeds `Sparkle.framework` into
        // `Contents/Frameworks` and adds the rpath that finds it there. See `Tools/build.sh`.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
        .package(url: "https://github.com/spatie/flare-client-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "BloomCore",
            dependencies: [.product(name: "BloomClient", package: "BloomClient")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Bloom",
            dependencies: [
                "BloomCore",
                .product(name: "BloomAuthentication", package: "BloomAuthentication"),
                .product(name: "BloomUI", package: "BloomUI"),
                .product(name: "AppAuth", package: "AppAuth-iOS"),
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Flare", package: "flare-client-swift"),
                .product(name: "FlareCrashReporter", package: "flare-client-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The MCP stdio shim an agent CLI launches, which forwards to the running app over a unix
        // domain socket. Its own file is three lines: `Tools/test-core.sh` mirrors only BloomCore
        // and its tests into the package it runs, so an executable target is invisible to the
        // suite and everything worth testing lives in `BridgeShim` instead.
        .executableTarget(
            name: "bloom-bridge",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "bloom-server",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BloomCoreTests",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

#endif
