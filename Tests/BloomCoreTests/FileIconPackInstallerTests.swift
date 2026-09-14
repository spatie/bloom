import Foundation
import Testing
@testable import BloomCore

@Suite("Installing file icon packs")
struct FileIconPackInstallerTests {
    @Test("only artwork paths, the manifest and the licence are extracted", arguments: [
        "../outside.svg", "extension/icons/../../outside.svg", "extension/icons/./file.svg",
        "/extension/icons/file.svg", "extension/icons/..\\outside.svg", "extension/dist/src/extension.js",
        "extension/src/icons/../../outside.svg", "extension/src/icons//file.svg",
    ])
    func rejectsUnwantedEntries(path: String) {
        for choice in FileIconPack.allCases {
            #expect(!FileIconPackInstaller.isArtworkEntry(path, for: choice))
        }
    }

    @Test("installs each pack layout, persists across instances, and preserves a good install on invalid downloads",
          arguments: [FileIconPack.vscodeIcons, .material, .symbols])
    func installAndReload(choice: FileIconPack) async throws {
        let download = try #require(choice.download)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-icons-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let manifestURL = source.appendingPathComponent(download.manifestPath)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let prefix: String = switch choice {
        case .vscodeIcons: "../../icons/"
        case .material: "../icons/"
        case .symbols: "icons/files/"
        case .bloom: ""
        }
        let manifest = FileIconThemeTests.manifest.replacingOccurrences(of: "../../icons/", with: prefix)
        try Data(manifest.utf8).write(to: manifestURL)
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(manifest.utf8))
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="red"/></svg>"#.utf8)
        for definition in theme.iconDefinitions.values where !definition.iconPath.isEmpty {
            let url = manifestURL.deletingLastPathComponent().appendingPathComponent(definition.iconPath).standardizedFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try svg.write(to: url)
        }
        try Data("Fixture licence".utf8).write(to: source.appendingPathComponent("extension/LICENSE.txt"))
        try Data("do not extract".utf8).write(to: source.appendingPathComponent("extension/code.js"))
        let archive = root.appendingPathComponent("icons.zip")
        try await Shell.check("/usr/bin/zip", ["-qr", archive.path, "extension"], cwd: source.path)
        let destination = root.appendingPathComponent("installed")
        let installer = try FileIconPackInstaller(choice: choice, directory: destination, archiveURL: archive)
        let installed = try await installer.install()
        #expect(installed.artwork["swift"] == svg)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("extension/code.js").path))
        let reloaded = try await FileIconPackInstaller(choice: choice, directory: destination).load()
        #expect(reloaded.artwork == installed.artwork)

        let invalid = root.appendingPathComponent("invalid.zip")
        try Data("not a zip".utf8).write(to: invalid)
        await #expect(throws: (any Error).self) {
            _ = try await FileIconPackInstaller(choice: choice, directory: destination, archiveURL: invalid).install()
        }
        let preserved = try await installer.load()
        #expect(preserved.artwork == installed.artwork)
    }
}
