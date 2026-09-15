import Foundation

public extension RemoteWorkspaceService {
    func notes(workspaceID: WorkspaceID) async throws -> String {
        let result = try await client.request(.call("workspace", ["workspaceID": .string(workspaceID.rawValue),
            "action": .object(["notes": .object([:])])]))
        guard let text = result["text"]?["_0"]?.stringValue else {
            throw ConnectionFailure("The server did not return workspace notes. Try loading them again.")
        }
        return text
    }

    func saveNotes(_ text: String, workspaceID: WorkspaceID) async throws {
        let result = try await client.request(.call("workspace", ["workspaceID": .string(workspaceID.rawValue),
            "action": .object(["saveNotes": .object(["_0": .string(text)])])]))
        guard result["accepted"]?.objectValue != nil else {
            throw ConnectionFailure("The server did not confirm these notes were saved. Your device draft is still available.")
        }
    }
}
