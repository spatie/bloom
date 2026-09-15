import Foundation
import BloomClient

public typealias CodexSpeed = BloomClient.CodexSpeed
public typealias CodexSpeedReading = BloomClient.CodexSpeedReading

public extension CodexSpeed {
    /// Read through the server so profiles and project configuration use Codex's own precedence.
    /// No thread or model turn is started, and no configuration is written.
    static func read(cwd: String, modelID: String) async throws -> CodexSpeed {
        let resolvedModel = ModelIdentifier.resolve(modelID).model
        guard let speed = try await readAll(cwd: cwd)[resolvedModel] else {
            throw CodexClientError.unexpectedResult(method: "model/list")
        }
        return speed
    }

    /// Every model at once, from one app-server, because a remote composer is sent the lot and
    /// starting Codex once per model would put seconds in front of every composer read.
    static func readAll(cwd: String) async throws -> [String: CodexSpeed] {
        let client = CodexClient(configuration: .init(cwd: cwd))
        do {
            try await client.start()
            let config = try await client.readConfiguration(cwd: cwd)
            let models = try await client.listModels()
            await client.stop()
            return speeds(config: config, models: models)
        } catch {
            await client.stop()
            throw error
        }
    }
}
