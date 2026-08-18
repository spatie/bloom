import Foundation

/// One row of the changed files tree: a folder, or a file the agent touched.
public struct ChangedFileTreeNode: Identifiable, Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        case folder([ChangedFileTreeNode])
        case file(ChangedFile)
    }

    /// What the row says. For a folder this can be a whole chain, `app / Domain / CustomFields`,
    /// because a directory nobody branched in carries no information as its own row.
    public var name: String
    /// The deepest directory the row stands for, or the file's path. Unique, so it doubles as the
    /// identity the expansion state is keyed by.
    public var path: String
    public var content: Content

    public var id: String { path }

    public var isFolder: Bool {
        if case .folder = content { return true }
        return false
    }

    public var children: [ChangedFileTreeNode] {
        if case .folder(let children) = content { return children }
        return []
    }

    public var file: ChangedFile? {
        if case .file(let file) = content { return file }
        return nil
    }
}

/// A node at the depth it is drawn at. The flat list the tree actually renders.
public struct ChangedFileTreeRow: Identifiable, Sendable {
    public var node: ChangedFileTreeNode
    public var depth: Int

    public var id: String { node.path }
}

/// Turns a flat list of changed paths into the directory tree the inspector draws.
///
/// Pure and free of SwiftUI on purpose: the collapsing rule below is the whole reason the tree is
/// readable in a 380pt column, and it is far easier to hold to that in tests than in a view body.
public enum ChangedFileTree {
    /// One entry mid-walk: what is left of its path, and the file it will end up as.
    private struct Entry {
        var components: ArraySlice<String>
        var file: ChangedFile
    }

    public static func build(from files: [ChangedFile]) -> [ChangedFileTreeNode] {
        let entries = files.compactMap { file -> Entry? in
            let components = file.path
                .components(separatedBy: "/")
                .filter { !$0.isEmpty }
            guard !components.isEmpty else { return nil }
            return Entry(components: components[...], file: file)
        }

        return nodes(from: entries, prefix: "")
    }

    /// Walks only the folders the user has closed out of, so first open shows everything and the
    /// row count still stays proportional to what is on screen.
    public static func rows(
        from nodes: [ChangedFileTreeNode],
        collapsed: Set<String>
    ) -> [ChangedFileTreeRow] {
        var result: [ChangedFileTreeRow] = []
        append(nodes, depth: 0, collapsed: collapsed, into: &result)
        return result
    }

    private static func append(
        _ nodes: [ChangedFileTreeNode],
        depth: Int,
        collapsed: Set<String>,
        into result: inout [ChangedFileTreeRow]
    ) {
        for node in nodes {
            result.append(ChangedFileTreeRow(node: node, depth: depth))
            guard node.isFolder, !collapsed.contains(node.path) else { continue }
            append(node.children, depth: depth + 1, collapsed: collapsed, into: &result)
        }
    }

    private static func nodes(from entries: [Entry], prefix: String) -> [ChangedFileTreeNode] {
        var files: [ChangedFileTreeNode] = []
        var folders: [String: [Entry]] = [:]
        /// Dictionary order is not stable across runs, and the sort below cannot recover the order
        /// two folders that compare equal were first seen in.
        var folderOrder: [String] = []

        for entry in entries {
            guard let first = entry.components.first else { continue }
            if entry.components.count == 1 {
                files.append(
                    ChangedFileTreeNode(name: first, path: entry.file.path, content: .file(entry.file))
                )
            } else {
                if folders[first] == nil { folderOrder.append(first) }
                folders[first, default: []].append(
                    Entry(components: entry.components.dropFirst(), file: entry.file)
                )
            }
        }

        let folderNodes = folderOrder.map { name -> ChangedFileTreeNode in
            let path = prefix.isEmpty ? name : prefix + "/" + name
            return collapsing(
                ChangedFileTreeNode(
                    name: name,
                    path: path,
                    content: .folder(nodes(from: folders[name] ?? [], prefix: path))
                )
            )
        }

        return sorted(folderNodes) + sorted(files)
    }

    /// A folder whose only child is another folder says nothing on its own row, so the two are
    /// said together. Applied bottom up, which is what turns `app/Domain/CustomFields` into a
    /// single row rather than three nested ones.
    private static func collapsing(_ node: ChangedFileTreeNode) -> ChangedFileTreeNode {
        guard node.children.count == 1, let only = node.children.first, only.isFolder else {
            return node
        }

        return ChangedFileTreeNode(
            name: node.name + " / " + only.name,
            path: only.path,
            content: only.content
        )
    }

    private static func sorted(_ nodes: [ChangedFileTreeNode]) -> [ChangedFileTreeNode] {
        nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
