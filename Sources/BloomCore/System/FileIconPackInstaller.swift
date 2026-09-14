import Foundation

/// Downloads artwork only. The extension's executable code is never extracted or launched.
public actor FileIconPackInstaller {
    public struct Pack: Sendable {
        public let theme: FileIconTheme
        public let artwork: [String: Data]
    }

    private let directory: URL
    private let archiveURL: URL
    private let choice: FileIconPack
    private let download: FileIconPack.Download

    public init(choice: FileIconPack, directory: URL, archiveURL: URL? = nil) throws {
        guard let download = choice.download else { throw InstallError.builtInPack }
        self.directory = directory
        self.choice = choice
        self.download = download
        self.archiveURL = archiveURL ?? download.archiveURL
    }

    public func load() throws -> Pack {
        try readPack(at: directory)
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
        let entries = listing.lines.filter { Self.isArtworkEntry($0, for: choice) }
        guard entries.contains(download.manifestPath), entries.contains(download.licencePath) else {
            throw InstallError.invalidArchive
        }
        let extracted = staging.appendingPathComponent("unpacked")
        try await Shell.check("/usr/bin/unzip", ["-q", archive.path] + entries + ["-d", extracted.path], timeout: .seconds(30))
        let pack = try readPack(at: extracted)
        try Task.checkCancellation()
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        try manager.moveItem(at: extracted, to: directory)
        return pack
    }

    public static func isArtworkEntry(_ path: String, for choice: FileIconPack) -> Bool {
        guard let download = choice.download else { return false }
        if path == download.manifestPath || path == download.licencePath { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix(download.artworkDirectory + "/") && path.hasSuffix(".svg")
            && !path.contains("\\") && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func readPack(at root: URL) throws -> Pack {
        let manifest = root.appendingPathComponent(download.manifestPath)
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(contentsOf: manifest))
        let icons = root.appendingPathComponent(download.artworkDirectory).resolvingSymlinksInPath().path + "/"
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
        case builtInPack

        var errorDescription: String? {
            switch self {
            case .invalidArchive: "The download does not contain a valid icon theme. Please try again."
            case .builtInPack: "Bloom's default icons do not need to be downloaded."
            }
        }
    }
}
