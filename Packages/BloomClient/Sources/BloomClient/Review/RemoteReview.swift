import Foundation

public enum RemoteDiffScope: String, Codable, Sendable, CaseIterable {
    case branch
    case uncommitted
}

/// A nil list means the caller already holds this revision, not that the workspace is clean.
public struct RemoteReviewSnapshot: Decodable, Sendable {
    public let revision: String
    public let files: [ChangedFile]?

    public init(revision: String, files: [ChangedFile]?) { self.revision = revision; self.files = files }
}

/// A nil patch leaves the caller's matching revision intact.
public struct RemotePatchSnapshot: Decodable, Sendable {
    public let revision: String
    public let patch: String?

    public init(revision: String, patch: String?) { self.revision = revision; self.patch = patch }
}

public struct RemoteTextFile: Decodable, Sendable {
    public let path: String
    public let text: String
    public let revision: String

    public init(path: String, text: String, revision: String) { self.path = path; self.text = text; self.revision = revision }
}

public extension RemoteWorkspaceService {
    func changes(
        workspaceID: WorkspaceID, scope: RemoteDiffScope = .branch,
        knownRevision: String? = nil, wait: Bool = false
    ) async throws -> RemoteReviewSnapshot {
        let result = try await client.request(.call("reviewSnapshot", [
            "workspaceID": .string(workspaceID.rawValue), "scope": .string(scope.rawValue),
            "knownRevision": knownRevision.map(JSONValue.string) ?? .null, "wait": .bool(wait),
        ]))
        return try reviewValue(result, named: "reviewSnapshot", failure: "The server did not return the changed files.")
    }

    func diff(
        workspaceID: WorkspaceID, path: String, scope: RemoteDiffScope = .branch,
        knownRevision: String? = nil
    ) async throws -> RemotePatchSnapshot {
        let result = try await client.request(.call("reviewPatch", [
            "workspaceID": .string(workspaceID.rawValue), "path": .string(path),
            "scope": .string(scope.rawValue), "knownRevision": knownRevision.map(JSONValue.string) ?? .null,
        ]))
        return try reviewValue(result, named: "reviewPatch", failure: "The server did not return this file's changes.")
    }

    func files(workspaceID: WorkspaceID) async throws -> [String] {
        let result = try await client.request(.call("workspace", [
            "workspaceID": .string(workspaceID.rawValue), "action": .object(["files": .object([:])]),
        ]))
        return try reviewValue(result, named: "files", failure: "The server did not return the workspace files.")
    }

    func fileTree(workspaceID: WorkspaceID) async throws -> [String: [FileTreeNode]] {
        FileTreeNode.index(try await files(workspaceID: workspaceID))
    }

    func readFile(workspaceID: WorkspaceID, path: String) async throws -> RemoteTextFile {
        let result = try await client.request(.call("file", [
            "workspaceID": .string(workspaceID.rawValue), "path": .string(path),
        ]))
        let file: RemoteTextFile = try reviewValue(result, named: "file", failure: "The server did not return this file.")
        guard file.path == path else { throw ConnectionFailure("The server returned a different file. Refresh the file list and try again.") }
        return file
    }
}

private func reviewValue<Value: Decodable>(_ result: JSONValue, named name: String, failure: String) throws -> Value {
    guard let payload = result[name]?["_0"] else { throw ConnectionFailure(failure + " Reconnect and try again.") }
    do {
        return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(payload))
    } catch {
        throw ConnectionFailure(failure + " Its response was incomplete or invalid. Reconnect and try again.")
    }
}
