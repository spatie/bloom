import Foundation

/// Downloads artwork only. The extension's executable code is never extracted or launched.
public actor VSCodeIconsInstaller {
    public static let version = "12.19.0"
    public static let defaultsKey = "useVSCodeIcons"
    public static let marketplaceURL = URL(string: "https://marketplace.visualstudio.com/items?itemName=vscode-icons-team.vscode-icons")!
    public static let downloadURL = URL(string: "https://github.com/vscode-icons/vscode-icons/releases/download/v\(version)/vscode-icons-\(version).vsix")!
    public static let manifestPath = "extension/dist/src/vsicons-icon-theme.json"

    public struct Pack: Sendable {
        public let theme: FileIconTheme
        public let artwork: [String: Data]
    }

    private let directory: URL
    private let archiveURL: URL

    public init(directory: URL, archiveURL: URL = VSCodeIconsInstaller.downloadURL) {
        self.directory = directory
        self.archiveURL = archiveURL
    }

    public func load() throws -> Pack {
        try Self.readPack(at: directory)
    }

    public func install() async throws -> Pack {
        let manager = FileManager.default
        let staging = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("icons.vsix")
        try await Shell.check("/usr/bin/curl", [
            "--fail", "--location", "--silent", "--show-error", "--max-time", "120",
            "--output", archive.path, archiveURL.absoluteString,
        ], timeout: .seconds(130))
        let listing = try await Shell.check("/usr/bin/unzip", ["-Z1", archive.path], timeout: .seconds(30))
        let entries = listing.lines.filter(Self.isArtworkEntry)
        guard entries.contains(Self.manifestPath), entries.contains("extension/LICENSE.txt") else {
            throw InstallError.invalidArchive
        }
        let extracted = staging.appendingPathComponent("unpacked")
        try await Shell.check("/usr/bin/unzip", ["-q", archive.path] + entries + ["-d", extracted.path], timeout: .seconds(30))
        let pack = try Self.readPack(at: extracted)
        try Task.checkCancellation()
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        try manager.moveItem(at: extracted, to: directory)
        return pack
    }

    public static func isArtworkEntry(_ path: String) -> Bool {
        if path == manifestPath || path == "extension/LICENSE.txt" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "extension" && parts[1] == "icons"
            && parts[2].hasSuffix(".svg") && !parts[2].contains("\\")
    }

    private static func readPack(at root: URL) throws -> Pack {
        let manifest = root.appendingPathComponent(manifestPath)
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(contentsOf: manifest))
        let icons = root.appendingPathComponent("extension/icons").resolvingSymlinksInPath().path + "/"
        var artwork: [String: Data] = [:]
        for (identifier, definition) in theme.iconDefinitions {
            guard !definition.iconPath.isEmpty else { continue }
            let url = manifest.deletingLastPathComponent().appendingPathComponent(definition.iconPath)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(icons), url.pathExtension == "svg" else { throw InstallError.invalidArchive }
            artwork[identifier] = try Data(contentsOf: url)
        }
        guard let file = theme.iconID(name: "unknown", isDirectory: false, expanded: false, isLight: false),
              artwork[file] != nil else { throw InstallError.invalidArchive }
        return Pack(theme: theme, artwork: artwork)
    }

    private enum InstallError: LocalizedError {
        case invalidArchive

        var errorDescription: String? { "The vscode-icons download does not contain a valid icon theme. Please try again." }
    }
}
