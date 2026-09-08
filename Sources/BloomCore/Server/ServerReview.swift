import Foundation
#if os(Linux)
import Glibc
#endif

/// Review commands operate on paths belonging to the selected server workspace. Clients cannot
/// supply a git revision, pretend a tracked file is untracked, or resolve a path on their Mac.
public enum ServerReview {
    public static let fileLimit = 2_097_152

    public static func changes(workspace: Workspace, scope: ServerDiffScope) async throws -> [ChangedFile] {
        try await Git.changedFiles(worktree: workspace.path, base: workspace.baseBranch, scope: scope.gitScope)
    }

    public static func patch(workspace: Workspace, path: String, scope: ServerDiffScope) async throws -> String {
        try validateRelativePath(path)
        let files = try await changes(workspace: workspace, scope: scope)
        guard let file = files.first(where: { $0.path == path }) else {
            throw ServerFailure("This file has no changes in the selected scope. Refresh the file list.")
        }
        try validatePatchFile(path, workspace: workspace)
        let arguments: [String]
        if file.change == .untracked {
            // Git reads symlinks as links. The text-file endpoint separately refuses escapes.
            arguments = ["--literal-pathspecs", "diff", "--no-index", "--no-ext-diff", "--no-textconv",
                         "--no-color", "--", "/dev/null", path]
        } else {
            let base = scope == .branch ? try await Git.baseline(workspace.baseBranch, in: workspace.path) : "HEAD"
            let oldPath = file.oldPath ?? path
            try validateRelativePath(oldPath)
            let oldSize = try await Git.run(["cat-file", "-s", "\(base):\(oldPath)"], in: workspace.path, timeout: .seconds(10))
            if oldSize.ok, let bytes = Int(oldSize.trimmed), bytes > fileLimit {
                throw ServerFailure("The original file is larger than 2 MB. Review it on the server.")
            }
            arguments = ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                         "-M", base, "--"] + (file.oldPath.map { [$0, path] } ?? [path])
        }
        let result = try await Git.run(arguments, in: workspace.path, timeout: .seconds(20))
        guard result.ok || (file.change == .untracked && result.status == 1) else {
            throw Git.error(arguments, result.status, result.stderr, result.stdout)
        }
        guard result.stdout.utf8.count <= fileLimit else {
            throw ServerFailure("This diff is larger than 2 MB. Review it on the server.")
        }
        return result.stdout
    }

    public static func file(workspace: Workspace, path: String) throws -> ServerTextFile {
        try validateRelativePath(path)
        guard let url = ContainedPath.relative(path, inside: workspace.path) else {
            throw ServerFailure("This file is outside the workspace.")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ServerFailure("This file could not be opened. It may have been moved or deleted.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ServerFailure("Only regular text files can be viewed.")
        }
        guard info.st_size <= fileLimit else { throw ServerFailure("This file is larger than 2 MB. Open it on the server.") }
        var data = Data()
        while data.count <= fileLimit {
            let chunk = try handle.read(upToCount: min(65_536, fileLimit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= fileLimit else { throw ServerFailure("This file is larger than 2 MB. Open it on the server.") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw ServerFailure("This file is binary or is not UTF-8 text.")
        }
        return ServerTextFile(path: path, text: text)
    }

    private static func validatePatchFile(_ path: String, workspace: Workspace) throws {
        let url = URL(fileURLWithPath: workspace.path).appendingPathComponent(path)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { return }
        guard let contained = ContainedPath.relative(path, inside: workspace.path) else {
            throw ServerFailure("This file is outside the workspace.")
        }
        // Deleted files have no current contents. Their old blob is checked separately.
        guard FileManager.default.fileExists(atPath: contained.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: contained.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ServerFailure("Only regular files and symbolic links can be compared.")
        }
        if let size = attributes[.size] as? NSNumber, size.int64Value > fileLimit {
            throw ServerFailure("This file is larger than 2 MB. Review it on the server.")
        }
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else {
            throw ServerFailure("Use a relative path inside this workspace.")
        }
    }
}
