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
        let current = try ServerReview.file(workspace: workspace, path: path)
        guard current.revision == expected else {
            throw ServerFailure("This file changed on the server. Reload it before saving your edits.")
        }
        let url = try contained(path, workspace: workspace)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try Data(text.utf8).write(to: url, options: .atomic)
        if let mode = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        return ServerTextFile(path: path, text: text)
    }

    public static func download(workspace: Workspace, path: String) throws -> ServerDownload {
        let url = try contained(path, workspace: workspace)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= transferLimit else {
            throw ServerFailure("Only regular files up to 8 MB can be downloaded.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: transferLimit + 1) ?? Data()
        guard data.count <= transferLimit else { throw ServerFailure("The file grew beyond the download limit.") }
        return ServerDownload(path: path, data: data)
    }

    public static func upload(workspace: Workspace, name: String, data: Data) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 240, data.count <= transferLimit else {
            throw ServerFailure("Choose a file up to 8 MB with a valid filename.")
        }
        let path = ".bloom/attachments/\(UUID().uuidString)/\(name)"
        let url = try contained(path, workspace: workspace)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        WorktreeScratch.shield(in: workspace.path)
        try data.write(to: url, options: .atomic)
        return path
    }
}
