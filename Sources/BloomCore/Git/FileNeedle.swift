import Foundation

/// What typing at a list of files means in this app, in the one place both of the inspector's
/// lists read it from.
///
/// **The two filters over that column are not one function and deliberately do not share one.**
/// `FileTreeFilter` prunes a lazily opened index of the whole worktree and reports which folders
/// have to be opened to reach a survivor; `ChangedFileFilter` narrows a flat list of changed files
/// and lets both shapes of the Changes tab rebuild from what is left. Each of those files says why
/// its own walk is the wrong shape for the other tree.
///
/// What they must never disagree about is what a needle IS, because that is the half a reader
/// feels: a field that matched by subsequence in one tab and by prefix in the next would be two
/// features wearing one control. That much is here.
public enum FileNeedle {
    /// Trimmed and lowercased, so a caller passes what was typed and nothing else.
    ///
    /// Lowercasing changes no answer, because `FuzzyMatch` folds both sides anyway. It is here so
    /// that "is there a filter" is one comparison against one canonical value rather than a
    /// question each caller trims for itself.
    public static func canonical(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Case insensitive, and a subsequence rather than a prefix, which is `FuzzyMatch` and is
    /// already what typing at a list of files means elsewhere in this window: the composer's
    /// `@mention` menu ranks every tracked path with the same function, so `usercon` finding
    /// `UserController.php` behaves the same wherever it is typed.
    ///
    /// Only whether there is a score is read, never its value. Both callers draw a tree ordered by
    /// the repository rather than by rank, because a tree that reordered itself on every keystroke
    /// would stop being a tree. `FileMatch` is the caller that wants the number.
    public static func matches(_ candidate: String, needle: String) -> Bool {
        FuzzyMatch.score(candidate, query: needle) != nil
    }
}
