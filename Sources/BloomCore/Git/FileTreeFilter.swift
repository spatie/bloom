import Foundation

/// What survives what somebody typed into the worktree tree's filter field, and which folders have
/// to be open for the survivors to be reachable.
///
/// **The answer is a second index, not a predicate over the rows.** The tree draws one opened
/// folder at a time, so the row a filter is looking for usually is not drawn at all: `usercon`
/// means a file three folders down, and none of the three folders holding it matches anything.
/// Hiding rows that fail a test would hide the folders as well and answer with nothing. So this
/// prunes the whole listing into a smaller one of the same shape, `FileTreeRowItem.flatten` walks
/// that exactly as it walks the real one, and the view draws what it is handed.
///
/// **The reader's own expansion is never written to.** The folders below are reported separately
/// so the caller can keep them in a set of the filter's own and throw it away when the field is
/// cleared. Losing where somebody had got to in a fifty thousand file repository because they
/// typed a character and deleted it again is worse than not having the field at all.
public enum FileTreeFilter {
    /// Trimmed and lowercased, so a caller passes what was typed and nothing else.
    ///
    /// Lowercasing changes no answer, because `FuzzyMatch` folds both sides anyway. It is here so
    /// that "is there a filter" is one comparison against one canonical value rather than a
    /// question each caller trims for itself.
    public static func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The listing narrowed to a needle.
    public struct Outcome: Equatable, Sendable {
        /// Every surviving directory's surviving children, in the shape the real index has.
        public var children: [String: [FileTreeNode]]
        /// The folders to draw open: an ancestor of a match, because a file cannot be shown
        /// without the folders it lives in, and a folder that matched by its own name, opened one
        /// level so the reader sees what is in the thing they just named.
        public var open: Set<String>

        public init(children: [String: [FileTreeNode]], open: Set<String>) {
            self.children = children
            self.open = open
        }

        /// True when the needle matched nothing at all. A different answer from "there is no
        /// filter", and the pane says the two differently: one needs a sentence, the other is just
        /// the tree.
        public var isEmpty: Bool { children[""]?.isEmpty ?? true }
    }

    /// Nil when there is nothing to filter by, which is the caller's "draw the real listing".
    ///
    /// Nil rather than an outcome carrying the whole index back, for the reason `WorkspaceSearch`
    /// gives about an empty needle: "no filter" and "no matches" are different answers and only
    /// the caller knows which of the two its pane wants to draw.
    public static func apply(
        to children: [String: [FileTreeNode]], needle: String
    ) -> Outcome? {
        guard !needle.isEmpty else { return nil }

        var outcome = Outcome(children: [:], open: [])
        prune(directory: "", of: children, needle: needle, into: &outcome)
        return outcome
    }

    /// Whether anything at or under `directory` survived, which is what tells the caller above
    /// whether to keep the folder and open it.
    @discardableResult
    private static func prune(
        directory: String,
        of children: [String: [FileTreeNode]],
        needle: String,
        into outcome: inout Outcome
    ) -> Bool {
        var survivors: [FileTreeNode] = []

        for node in children[directory] ?? [] {
            guard node.isDirectory else {
                if matches(node, needle: needle) { survivors.append(node) }
                continue
            }

            if matches(node, needle: needle) {
                // The folder itself is the answer, so what is in it is kept whole and unjudged:
                // somebody who typed `app/mod` is asking what lives under `app/models`, and
                // testing those files against the same needle would throw most of them away.
                //
                // Opened one level and no further. Opening every folder underneath as well would
                // answer `sources` with a flat dump of the whole repository, which is the listing
                // the reader was typing to escape.
                copy(subtreeOf: node.path, of: children, into: &outcome)
                outcome.open.insert(node.path)
                survivors.append(node)
                continue
            }

            if prune(directory: node.path, of: children, needle: needle, into: &outcome) {
                outcome.open.insert(node.path)
                survivors.append(node)
            }
        }

        // A directory nothing survived in is left out of the index rather than written as an empty
        // entry, so a needle that matches one file costs one chain of directories instead of a
        // second copy of every directory in the repository. The root is always written, because a
        // walk has to start somewhere and `isEmpty` is asked of it.
        if !survivors.isEmpty || directory.isEmpty { outcome.children[directory] = survivors }
        return !survivors.isEmpty
    }

    private static func copy(
        subtreeOf directory: String,
        of children: [String: [FileTreeNode]],
        into outcome: inout Outcome
    ) {
        guard let nodes = children[directory] else { return }
        outcome.children[directory] = nodes
        for node in nodes where node.isDirectory {
            copy(subtreeOf: node.path, of: children, into: &outcome)
        }
    }

    /// Case insensitive, and a subsequence rather than a prefix, which is `FuzzyMatch` and is
    /// already what typing at a list of files means in this app: the composer's `@mention` menu
    /// ranks every tracked path with the same function, so `usercon` finding `UserController.php`
    /// behaves the same in both places rather than being a second idea of what typing does.
    ///
    /// **Matched against the name, unless what was typed carries a slash, and then against the
    /// path.** `app/mod` is somebody saying where a file lives rather than what it is called, and
    /// there is no name to find that in. Going the other way and always matching the path would
    /// make every needle match on folder names it was never aimed at, and it costs more per node:
    /// a name is a dozen characters where a path in this repository is sixty.
    ///
    /// Only whether there is a score is read, never its value. The tree is ordered by the
    /// repository and not by rank, because a tree that reordered itself on every keystroke would
    /// stop being a tree.
    private static func matches(_ node: FileTreeNode, needle: String) -> Bool {
        FuzzyMatch.score(needle.contains("/") ? node.path : node.name, query: needle) != nil
    }
}
