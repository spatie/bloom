import Foundation
#if os(Linux)
import Glibc
#endif

/// Review commands operate on paths belonging to the selected server workspace. Clients cannot
/// supply a git revision, pretend a tracked file is untracked, or resolve a path on their Mac.
public enum ServerReview {
    public static let fileLimit = 2_097_152

    public static func changes(workspace: Workspace, scope: ServerDiffScope) async throws -> [ChangedFile] {
        try await Git.changedFiles(
            worktree: workspace.path, base: workspace.baseBranch, scope: scope.gitScope,
            maximumUntrackedFileBytes: fileLimit
        )
    }

    public static func patch(workspace: Workspace, path: String, scope: ServerDiffScope) async throws -> String {
        try validateRelativePath(path)
        let files = try await changes(workspace: workspace, scope: scope)
        guard let file = files.first(where: { $0.path == path }) else {
            throw ServerFailure("This file has no changes in the selected scope. Refresh the file list.")
        }
        let base = scope == .branch ? try await Git.baseline(workspace.baseBranch, in: workspace.path) : try await Git.check(["rev-parse", "HEAD"], in: workspace.path).trimmed
        return try await patch(workspace: workspace, file: file, base: base)
    }

    static func patch(workspace: Workspace, file: ChangedFile, base: String) async throws -> String {
        let path = file.path
        try validateRelativePath(path)
        let arguments: [String]
        if file.change == .untracked {
            // Git reads symlinks as links. The text-file endpoint separately refuses escapes.
            arguments = ["--literal-pathspecs", "diff", "--no-index", "--no-ext-diff", "--no-textconv",
                         "--no-color", "--", "/dev/null", path]
        } else {
            let oldPath = file.oldPath ?? path
            try validateRelativePath(oldPath)
            let oldSize = try await Git.run(["cat-file", "-s", "\(base):\(oldPath)"], in: workspace.path, timeout: .seconds(10))
            if oldSize.ok, let bytes = Int(oldSize.trimmed), bytes > fileLimit {
                throw ServerFailure("The original file is larger than 2 MB. Review it on the server.")
            }
            arguments = ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                         "-M", base, "--"] + (file.oldPath.map { [$0, path] } ?? [path])
        }
        let paths = file.oldPath.map { [$0, path] } ?? [path]
        let snapshot = try ServerDiffWorktree(workspace: workspace, paths: paths)
        defer { snapshot.remove() }
        let result = try await Git.run(snapshot.arguments(arguments, workspace: workspace), in: snapshot.path, timeout: .seconds(20))
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
        let data = try WorkspaceFileAccess(workspace: workspace, path: path).read(limit: fileLimit)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw ServerFailure("This file is binary or is not UTF-8 text.")
        }
        return ServerTextFile(path: path, text: text)
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else {
            throw ServerFailure("Use a relative path inside this workspace.")
        }
    }
}
