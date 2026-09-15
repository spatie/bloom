import Foundation

/// The existing settings editor reads the server's effective settings and provenance, so saving
/// uses the same writer and destination rules as a local project. Paths are resolved on the server.
public struct ServerProjectSettings: Codable, Sendable {
    public var settings: RepoSettings
    public var instructionFiles: [ProjectInstructions.Subject: String]
    public var savedPaths: [String]

    static func load(repo: String, savedPaths: [String] = []) -> Self {
        Self(settings: SettingsLoader.load(repo: repo), instructionFiles: ProjectInstructions.files(in: repo), savedPaths: savedPaths)
    }
}
