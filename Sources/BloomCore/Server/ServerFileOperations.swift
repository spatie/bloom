import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// File mutations resolve against the server worktree and use an optimistic revision check.
/// The UI never hands a server path to a local file writer.
public enum ServerFileOperations {
    public static let transferLimit = 8_388_608

    public static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func contained(_ path: String, workspace: Workspace) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(".."),
              let url = ContainedPath.relative(path, inside: workspace.path) else {
            throw ServerFailure("Use a relative path inside this workspace.")
        }
        return url
    }

    public static func write(workspace: Workspace, path: String, text: String, revision expected: String) throws -> ServerTextFile {
        guard text.utf8.count <= ServerReview.fileLimit else { throw ServerFailure("Text files larger than 2 MB cannot be edited here.") }
        try WorkspaceFileAccess(workspace: workspace, path: path).replace(Data(text.utf8), expectedRevision: expected, limit: ServerReview.fileLimit)
        return ServerTextFile(path: path, text: text)
    }

    public static func download(workspace: Workspace, path: String) throws -> ServerDownload {
        let data = try WorkspaceFileAccess(workspace: workspace, path: path).read(limit: transferLimit)
        return ServerDownload(path: path, data: data)
    }

    static func validateUpload(name: String, data: Data) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 240, data.count <= transferLimit else {
            throw ServerFailure("Choose a file up to 8 MB with a valid filename.")
        }
    }

    public static func upload(workspace: Workspace, name: String, data: Data) throws -> String {
        try validateUpload(name: name, data: data)
        let path = ".bloom/attachments/\(UUID().uuidString)/\(name)"
        try WorkspaceFileAccess(workspace: workspace, path: WorktreeScratch.attachments + "/.gitignore", creatingParents: true)
            .create(Data(WorktreeScratch.ignoreContents.utf8), allowExisting: true)
        try WorkspaceFileAccess(workspace: workspace, path: path, creatingParents: true).create(data)
        return path
    }
}
