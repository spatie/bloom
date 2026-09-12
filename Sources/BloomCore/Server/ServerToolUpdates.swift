import Foundation

/// Tool maintenance uses the existing verified service-user SSH connection, independently of
/// the server protocol. Only recognised user-owned installations can be updated.
public enum ServerToolUpdates {
    public enum Tool: String, Codable, CaseIterable, Sendable, Identifiable {
        case claude, codex
        public var id: String { rawValue }
        public var title: String { self == .claude ? "Claude Code" : "Codex" }
    }

    public struct Installation: Decodable, Sendable, Identifiable {
        public let tool: Tool
        public let version: String?
        public let path: String?
        public let method: String?
        public let detail: String
        public var id: Tool { tool }
        public var canUpdate: Bool { method != nil }
    }

    public static func inspect(connection: ServerSetupConnection) async throws -> [Installation] {
        let result = try await connection.run(command("inspect"), timeout: .seconds(40))
        guard let line = result.stdout.split(separator: "\n").last,
              let values = try? JSONDecoder().decode([Installation].self, from: Data(line.utf8)),
              values.count == Tool.allCases.count, Set(values.map(\.tool)).count == values.count else {
            throw ServerFailure("The server did not return a valid list of installed tools.")
        }
        return values
    }

    public static func update(_ tool: Tool, connection: ServerSetupConnection,
                              progress: @escaping @Sendable (ServerInstallEvent) async -> Void) async throws -> ServerInstallEvent {
        let process = StreamingProcess(executable: "/usr/bin/ssh",
            arguments: try connection.arguments(command: command(tool.rawValue)), mergeStderr: false)
        return try await ServerSetupStream.run(process, input: "", timeout: .seconds(420),
            commandLabel: "Update " + tool.title, progress: progress)
    }

    private static func command(_ action: String) -> String {
        ["python3", "-c", script, action].map(ServerSetupSSH.shellQuote).joined(separator: " ")
    }
}
