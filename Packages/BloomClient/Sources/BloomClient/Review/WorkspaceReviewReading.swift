import Foundation

/// Both local execution and network transports supply the same review facts. The store owns
/// presentation lifetime; the execution host owns paths, Git and content revisions.
public protocol WorkspaceReviewReading: Sendable {
    func changes(workspaceID: WorkspaceID, scope: RemoteDiffScope, knownRevision: String?, wait: Bool) async throws -> RemoteReviewSnapshot
    func diff(workspaceID: WorkspaceID, path: String, scope: RemoteDiffScope, knownRevision: String?) async throws -> RemotePatchSnapshot
    func files(workspaceID: WorkspaceID) async throws -> [String]
    func readFile(workspaceID: WorkspaceID, path: String) async throws -> RemoteTextFile
}

extension RemoteWorkspaceService: WorkspaceReviewReading {}
