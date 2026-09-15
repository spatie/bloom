import Foundation

/// Linked worktrees store their index and HEAD beside the original repository, not under
/// the worktree's `.git` pointer file. Shared refs have a separate directory again.
public struct GitRepositoryPaths: Sendable, Equatable {
    public let gitDirectory: String
    public let commonDirectory: String
}

extension Git {
    public static func repositoryPaths(in worktree: String) -> GitRepositoryPaths? {
        let dotGit = (worktree as NSString).appendingPathComponent(".git")
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &directory) else { return nil }
        let gitDirectory: String
        if directory.boolValue {
            gitDirectory = dotGit
        } else {
            guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  pointer.hasPrefix("gitdir: ") else { return nil }
            gitDirectory = resolveGitPath(String(pointer.dropFirst(8)), relativeTo: worktree)
        }
        let commonFile = (gitDirectory as NSString).appendingPathComponent("commondir")
        let common = (try? String(contentsOfFile: commonFile, encoding: .utf8))
            .map { resolveGitPath($0, relativeTo: gitDirectory) } ?? gitDirectory
        return GitRepositoryPaths(
            gitDirectory: URL(fileURLWithPath: gitDirectory).resolvingSymlinksInPath().standardized.path,
            commonDirectory: URL(fileURLWithPath: common).resolvingSymlinksInPath().standardized.path
        )
    }

    private static func resolveGitPath(_ text: String, relativeTo directory: String) -> String {
        var path = text
        if path.hasSuffix("\n") { path.removeLast() }
        if path.hasSuffix("\r") { path.removeLast() }
        if (path as NSString).isAbsolutePath { return path }
        return (directory as NSString).appendingPathComponent(path)
    }
}
