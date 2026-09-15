import Foundation
import BloomCore

@MainActor
enum RemoteFileEditing {
    static func make(server: ServerWindowModel, workspace: Workspace, endpoint: ServerEndpoint) -> FileEditSession {
        return FileEditSession(remoteRead: { [weak server] absolute in
            guard let server, server.endpoint == endpoint else { throw ServerFailure("Reconnect to this file's server.") }
            let path = try relative(absolute, in: workspace)
            guard case .file(let file) = try await server.read(.file(workspaceID: workspace.id, path: path)) else {
                throw ServerFailure("The server did not return this file.")
            }
            return try FileEditor.remoteSnapshot(path: absolute, text: file.text, revision: file.revision)
        }, remoteWrite: { [weak server] absolute, text, baseline in
            guard let server, server.endpoint == endpoint else { throw ServerFailure("Reconnect to this file's server.") }
            let path = try relative(absolute, in: workspace)
            guard let revision = baseline.remoteRevision else {
                throw ServerFailure("Reload this file from the server before saving.")
            }
            guard case .file(let file) = try await server.read(.workspace(workspaceID: workspace.id,
                action: .writeFile(path: path, text: text, revision: revision))) else {
                throw ServerFailure("The server did not confirm saving this file.")
            }
            return try FileEditor.remoteSnapshot(path: absolute, text: file.text, revision: file.revision)
        })
    }

    private static func relative(_ absolute: String, in workspace: Workspace) throws -> String {
        let prefix = workspace.path + "/"
        guard absolute.hasPrefix(prefix) else { throw ServerFailure("This file belongs to another workspace.") }
        let path = String(absolute.dropFirst(prefix.count))
        guard !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw ServerFailure("Invalid file path.") }
        return path
    }

}
