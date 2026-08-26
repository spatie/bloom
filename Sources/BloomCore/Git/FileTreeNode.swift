import Foundation

/// One entry in the worktree listing: a file, or a directory that has not been opened yet.
///
/// Beside `ChangedFileTree` rather than beside the view that draws it, because everything here is
/// a rule about a listing and a rule taken inside a view is a rule nothing can test. The index and
/// the flattening below shipped in the app target for weeks with no suite able to reach either;
/// `FileTreeFilter`, which is the third rule over the same nodes, is what made that cost real.
public struct FileTreeNode: Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    /// One pass over `git ls-files` output builds every directory's children, which is what makes
    /// expanding a folder free later on. A repository with fifty thousand files costs one
    /// subprocess and this dictionary, rather than fifty thousand live nodes.
    public static func index(_ paths: [String]) -> [String: [FileTreeNode]] {
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
public struct FileTreeRowItem: Identifiable, Equatable, Sendable {
    public var node: FileTreeNode
    public var depth: Int

    public var id: String { node.path }

    public init(node: FileTreeNode, depth: Int) {
        self.node = node
        self.depth = depth
    }

    /// Walks only the directories the user has opened, so the row list stays proportional to what
    /// is on screen rather than to the size of the repository.
    ///
    /// `children` is the index to walk and is not always the real one: under a live filter it is
    /// the pruned index `FileTreeFilter` returns, which has the same shape and is walked the same
    /// way. That is the whole reason the filter answers with an index rather than with a predicate.
    public static func flatten(
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
