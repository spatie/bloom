import Foundation

/// One entry in the worktree listing: a file, or a directory that has not been opened yet.
struct FileTreeNode: Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var isDirectory: Bool

    var id: String { path }

    /// One pass over `git ls-files` output builds every directory's children, which is what makes
    /// expanding a folder free later on. A repository with fifty thousand files costs one
    /// subprocess and this dictionary, rather than fifty thousand live nodes.
    static func index(_ paths: [String]) -> [String: [FileTreeNode]] {
        var children: [String: Set<FileTreeNode>] = [:]

        for path in paths where !path.isEmpty {
            let components = path.components(separatedBy: "/")
            var parent = ""
            for (offset, component) in components.enumerated() {
                let isLast = offset == components.count - 1
                let full = parent.isEmpty ? component : parent + "/" + component
                children[parent, default: []].insert(
                    FileTreeNode(name: component, path: full, isDirectory: !isLast)
                )
                if isLast { break }
                parent = full
            }
        }

        return children.mapValues { nodes in
            nodes.sorted {
                $0.isDirectory == $1.isDirectory
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.isDirectory
            }
        }
    }
}

/// A node at the depth it is currently drawn at. The flattened list the tree actually renders.
struct FileTreeRowItem: Identifiable {
    var node: FileTreeNode
    var depth: Int

    var id: String { node.path }

    /// Walks only the directories the user has opened, so the row list stays proportional to what
    /// is on screen rather than to the size of the repository.
    static func flatten(
        children: [String: [FileTreeNode]],
        expanded: Set<String>
    ) -> [FileTreeRowItem] {
        var result: [FileTreeRowItem] = []
        append(directory: "", depth: 0, children: children, expanded: expanded, into: &result)
        return result
    }

    private static func append(
        directory: String,
        depth: Int,
        children: [String: [FileTreeNode]],
        expanded: Set<String>,
        into result: inout [FileTreeRowItem]
    ) {
        for node in children[directory] ?? [] {
            result.append(FileTreeRowItem(node: node, depth: depth))
            if node.isDirectory, expanded.contains(node.path) {
                append(
                    directory: node.path,
                    depth: depth + 1,
                    children: children,
                    expanded: expanded,
                    into: &result
                )
            }
        }
    }
}
