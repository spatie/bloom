import Foundation
import BloomCore

@MainActor
enum RemoteFileEditing {
    static func make(server: ServerWindowModel, workspace: Workspace, endpoint: ServerEndpoint) -> FileEditSession {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-file-editing/\(UUID().uuidString)")
        return FileEditSession(remoteRead: { [weak server] absolute in
            guard let server, server.endpoint == endpoint else { throw ServerFailure("Reconnect to this file's server.") }
            let path = try relative(absolute, in: workspace)
            guard case .file(let file) = try await server.read(.file(workspaceID: workspace.id, path: path)) else {
                throw ServerFailure("The server did not return this file.")
            }
            return try await snapshot(file, in: cache)
        }, remoteWrite: { [weak server] absolute, text, baseline in
            guard let server, server.endpoint == endpoint else { throw ServerFailure("Reconnect to this file's server.") }
            let path = try relative(absolute, in: workspace)
            let revision = ServerFileOperations.revision(Data(baseline.text.utf8))
            guard case .file(let file) = try await server.read(.workspace(workspaceID: workspace.id,
                action: .writeFile(path: path, text: text, revision: revision))) else {
                throw ServerFailure("The server did not confirm saving this file.")
            }
            return try await snapshot(file, in: cache)
        })
    }

    private static func relative(_ absolute: String, in workspace: Workspace) throws -> String {
        let prefix = workspace.path + "/"
        guard absolute.hasPrefix(prefix) else { throw ServerFailure("This file belongs to another workspace.") }
        let path = String(absolute.dropFirst(prefix.count))
        guard !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw ServerFailure("Invalid file path.") }
        return path
    }

    private static func snapshot(_ file: ServerTextFile, in cache: URL) async throws -> EditableFile {
        // Only an opaque filename is used locally; the remote path never becomes a Mac path.
        let path = cache.appendingPathComponent(UUID().uuidString).path
        return try await Task.detached {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(file.text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return try FileEditor.read(path)
        }.value
    }
}
