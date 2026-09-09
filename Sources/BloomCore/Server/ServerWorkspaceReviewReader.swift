import Foundation
import BloomClient

/// Maps the native server API into the portable review boundary without serialising a patch to
/// JSON again. The Mac's existing transport, authentication and request timeout stay in place.
public struct ServerWorkspaceReviewReader: WorkspaceReviewReading {
    private let request: @Sendable (ServerOperation) async throws -> ServerResult

    public init(client: ServerClient) {
        request = { try await client.request(ServerRequest($0), timeout: .seconds(25)).result }
    }

    public init(request: @escaping @Sendable (ServerOperation) async throws -> ServerResult) { self.request = request }

    public func changes(workspaceID: WorkspaceID, scope: RemoteDiffScope, knownRevision: String?, wait: Bool) async throws -> RemoteReviewSnapshot {
        guard case .reviewSnapshot(let value) = try await request(.reviewSnapshot(workspaceID: workspaceID,
            scope: scope == .branch ? .branch : .uncommitted, knownRevision: knownRevision, wait: wait)) else {
            throw ServerFailure("The server did not return the changed files. Refresh to try again.")
        }
        return .init(revision: value.revision, files: value.files)
    }

    public func diff(workspaceID: WorkspaceID, path: String, scope: RemoteDiffScope, knownRevision: String?) async throws -> RemotePatchSnapshot {
        guard case .reviewPatch(let value) = try await request(.reviewPatch(workspaceID: workspaceID, path: path,
            scope: scope == .branch ? .branch : .uncommitted, knownRevision: knownRevision)) else {
            throw ServerFailure("The server did not return the diff. Retry this file.")
        }
        return .init(revision: value.revision, patch: value.patch)
    }

    public func files(workspaceID: WorkspaceID) async throws -> [String] {
        guard case .files(let paths) = try await request(.workspace(workspaceID: workspaceID, action: .files)) else {
            throw ServerFailure("The server did not return the workspace files. Refresh to try again.")
        }
        return paths
    }

    public func readFile(workspaceID: WorkspaceID, path: String) async throws -> RemoteTextFile {
        guard case .file(let file) = try await request(.file(workspaceID: workspaceID, path: path)), file.path == path else {
            throw ServerFailure("The server did not return the requested file. Refresh to try again.")
        }
        return .init(path: file.path, text: file.text, revision: file.revision)
    }
}
