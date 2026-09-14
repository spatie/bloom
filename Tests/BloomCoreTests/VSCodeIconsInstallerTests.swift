import Foundation
import Testing
@testable import BloomCore

@Suite("Installing vscode-icons artwork")
struct VSCodeIconsInstallerTests {
    @Test("only flat artwork paths, the manifest and the licence are extracted", arguments: [
        "../outside.svg", "extension/icons/../../outside.svg", "extension/icons/nested/file.svg",
        "/extension/icons/file.svg", "extension/icons/..\\outside.svg", "extension/dist/src/extension.js",
    ])
    func rejectsUnwantedEntries(path: String) {
        #expect(!VSCodeIconsInstaller.isArtworkEntry(path))
    }

    @Test("installs artwork, persists across instances, and preserves a good install on invalid downloads")
    func installAndReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-icons-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let manifestURL = source.appendingPathComponent(VSCodeIconsInstaller.manifestPath)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(FileIconThemeTests.manifest.utf8).write(to: manifestURL)
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(FileIconThemeTests.manifest.utf8))
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
        let installer = VSCodeIconsInstaller(directory: destination, archiveURL: archive)
        let installed = try await installer.install()
        #expect(installed.artwork["swift"] == svg)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("extension/code.js").path))
        let reloaded = try await VSCodeIconsInstaller(directory: destination).load()
        #expect(reloaded.artwork == installed.artwork)

        let invalid = root.appendingPathComponent("invalid.zip")
        try Data("not a zip".utf8).write(to: invalid)
        await #expect(throws: (any Error).self) {
            _ = try await VSCodeIconsInstaller(directory: destination, archiveURL: invalid).install()
        }
        let preserved = try await installer.load()
        #expect(preserved.artwork == installed.artwork)
    }
}
