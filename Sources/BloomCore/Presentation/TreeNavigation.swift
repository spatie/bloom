import Foundation

/// One row of a tree, as much of it as its keyboard needs to know.
///
/// Not the node, and deliberately not: two different trees in this window ask these questions, one
/// of the changed files and one of the whole worktree, and they hold different types. What Left
/// and Right mean depends on the depth of a row and whether it is an open directory, and on
/// nothing else.
public struct TreeRow: Sendable, Equatable {
    public var depth: Int
    public var isDirectory: Bool
    public var isExpanded: Bool

    public init(depth: Int, isDirectory: Bool, isExpanded: Bool) {
        self.depth = depth
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
    }
}

/// What Left and Right do to the row the keyboard is on.
public enum TreeStep: Equatable, Sendable {
    case expand(Int)
    case collapse(Int)
    case move(Int)
    /// The key was this tree's and there was nowhere to go. Not the same as the tree ignoring it:
    /// see `ListKeyOutcome`.
    case none
}

/// Left and Right in a tree, as Finder's list view and Xcode's navigator have them.
///
/// Four rules, and the pair of them that people forget is the second half of each key. Right on a
/// directory that is **already** open steps into it rather than doing nothing, and Left on a file
/// steps out to the directory holding it rather than doing nothing. Without those two, walking a
/// tree from the keyboard means arrowing down through every sibling to get out of a folder, which
/// is what makes a keyboard tree feel like a list that happens to be indented.
///
/// The rows are the ones on screen, already flattened, which is how both of Bloom's trees hold
/// them: only the directories somebody opened produce rows at all, so a repository with fifty
/// thousand files is still a short array here.
public enum TreeNavigation {
    public static func step(_ key: ListKey, at index: Int?, in rows: [TreeRow]) -> TreeStep {
        guard let index, rows.indices.contains(index) else { return .none }
        let row = rows[index]

        switch key {
        case .right:
            guard row.isDirectory else { return .none }
            guard row.isExpanded else { return .expand(index) }
            // Into the first child, which is the next row only if it is deeper. An open directory
            // with nothing in it has no next row to step into.
            let child = index + 1
            guard rows.indices.contains(child), rows[child].depth > row.depth else { return .none }
            return .move(child)

        case .left:
            if row.isDirectory, row.isExpanded { return .collapse(index) }
            // Out to the parent: the nearest row above this one that is drawn a level shallower.
            guard let parent = rows[..<index].lastIndex(where: { $0.depth < row.depth }) else {
                return .none
            }
            return .move(parent)

        case .up, .down, .home, .end, .activate, .character:
            return .none
        }
    }
}
