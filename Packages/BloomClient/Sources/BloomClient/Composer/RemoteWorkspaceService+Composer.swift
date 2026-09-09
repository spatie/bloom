import Foundation

public extension RemoteWorkspaceService {
    func composer(sessionID: SessionID) async throws -> RemoteComposerState {
        try await RemoteComposerState.decode(client.request(.call("composer", ["sessionID": .string(sessionID.rawValue)])))
    }

    /// A backend change can fork a conversation. The caller must open that returned session.
    func setComposer(sessionID: SessionID, controls: ComposerControls, commandID: UUID = UUID()) async throws -> RemoteSession? {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(controls))
        let command = RemoteCommand(.object(["setComposer": .object([
            "sessionID": .string(sessionID.rawValue), "controls": value
        ])]), id: commandID)
        let result = try await client.request(command)
        if result["accepted"] != nil { return nil }
        guard let session = result["created"]?["session"] else {
            throw ConnectionFailure("The server did not confirm the composer changes. Reconnect before retrying.")
        }
        return try JSONDecoder().decode(RemoteSession.self, from: JSONEncoder().encode(session))
    }
}
