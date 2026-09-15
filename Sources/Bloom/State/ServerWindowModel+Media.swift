import Foundation
import BloomCore

/// Remote media always passes through the server's confined download API. A server path must
/// never fall through to local filesystem resolution, even when both machines use the same path.
extension ServerWindowModel {
    func downloadMedia(_ path: String, workspaceID: WorkspaceID) async throws -> WorkspaceMedia {
        guard let capturedEndpoint = endpoint,
              let workspace = catalogue?.workspaces.first(where: { $0.id == workspaceID }) else {
            throw ServerFailure("Connect to this workspace's server to load its media.")
        }
        let prefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        let relative: String
        if path.hasPrefix("/") {
            guard path.hasPrefix(prefix) else {
                throw ServerFailure("Save remote media inside the workspace before showing it.")
            }
            relative = String(path.dropFirst(prefix.count))
        } else {
            relative = path
        }
        let file = try await download(relative, workspaceID: workspaceID)
        do {
            try Task.checkCancellation()
            guard endpoint == capturedEndpoint else { throw ServerFailure("The server connection changed while loading media.") }
            guard let media = WorkspaceMedia.resolve(path: file.path, in: file.deletingLastPathComponent().path) else {
                throw ServerFailure("That remote file is not a supported image or video.")
            }
            return WorkspaceMedia(url: media.url, relativePath: relative, kind: media.kind)
        } catch {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            throw error
        }
    }
}
