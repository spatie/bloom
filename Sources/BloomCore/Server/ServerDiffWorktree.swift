import Foundation

/// Git keeps its existing object database/index and diff formatter, but reads current contents
/// only from a private bounded snapshot. No git subprocess reopens mutable workspace paths.
final class ServerDiffWorktree {
    let path: String
    private let root: URL

    init(workspace: Workspace, paths: [String], limit: Int = ServerReview.fileLimit) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-diff-" + UUID().uuidString)
        path = root.path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var files: [String: WorkspaceFileSnapshot] = [:]
            var bytes = 0
            for file in paths {
                let snapshot = try WorkspaceFileAccess(workspace: workspace, path: file, followingFinalSymlink: false, allowingMissing: true).snapshot(limit: limit)
                files[file] = snapshot
                bytes += snapshot.byteCount
            }
            // Keep per-path binary/text and diff attributes. Git ignores symlink attributes;
            // copying their targets would widen this snapshot's read boundary.
            let attributes = Set(paths.flatMap(Self.attributePaths))
            for file in attributes.sorted() where files[file] == nil {
                let snapshot = try WorkspaceFileAccess(workspace: workspace, path: file, followingFinalSymlink: false, allowingMissing: true).snapshot(limit: limit)
                if case .symbolicLink = snapshot { continue }
                files[file] = snapshot
                bytes += snapshot.byteCount
                guard bytes <= limit * 3 else { throw ServerFailure("This file's diff attributes are too large. Review it on the server.") }
            }
            for (file, snapshot) in files.sorted(by: { $0.key < $1.key }) {
                switch snapshot {
                case .missing: continue
                case .file(let data, let mode):
                    try WorkspaceFileAccess(root: path, path: file, creatingParents: true).create(data, mode: mode)
                case .symbolicLink(let target):
                    try WorkspaceFileAccess(root: path, path: file, creatingParents: true).createSymbolicLink(target)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func arguments(_ arguments: [String], workspace: Workspace) -> [String] {
        // --git-dir accepts either a directory or a linked worktree's .git file. Keeping cwd in
        // the snapshot is essential: --no-index resolves paths from cwd, not --work-tree.
        ["--git-dir=" + URL(fileURLWithPath: workspace.path).appendingPathComponent(".git").path,
         "--work-tree=" + path] + arguments
    }

    private static func attributePaths(_ file: String) -> [String] {
        var paths = [".gitattributes"]
        var directory = ""
        for component in file.split(separator: "/").dropLast() {
            directory += String(component) + "/"
            paths.append(directory + ".gitattributes")
        }
        return paths
    }
}
