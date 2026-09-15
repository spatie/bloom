import Foundation

/// The Changes tab narrowed to what somebody typed into its filter field.
///
/// **A filter over the files, not over the tree, and that is the whole difference from
/// `FileTreeFilter`.** The two tabs of this column look alike and their filters are not the same
/// function, so the reason is written down here rather than worked out again by whoever next
/// notices the resemblance.
///
/// `FileTreeFilter` prunes an index in place because the All files tree is a listing that exists
/// before anything is drawn: its nodes are the repository, its folders are shut until somebody
/// opens one, and pruning is the only way to reach a file three unopened folders down. The Changes
/// tab has neither property. Its tree is DERIVED from the changed file list every time that list
/// changes, and its folders are open unless the reader closed one, so there is nothing to open and
/// nothing to walk. The honest place to narrow it is the list it is derived from: `ChangedFileTree`
/// and `ChangedFileGroup` then answer for the survivors, and both shapes of the tab narrow through
/// one function instead of two that would eventually disagree about a file.
///
/// **Rebuilt rather than pruned, and the collapsing rule is why.** A folder whose only child is
/// another folder is drawn as one row, `app / Domain / CustomFields`. Which folders that describes
/// depends on which files are in the tree, so a tree pruned after the fact keeps chains that have
/// stopped branching: `app / Domain`, then a lone `CustomFields`, then one file, three rows saying
/// what a rebuild says in one. Handing the survivors back to the builder is not a shortcut here,
/// it is the only way the shape stays true.
public enum ChangedFileFilter {
    /// The diff narrowed to a needle.
    ///
    /// Nil when there is nothing to filter by, which is the caller's "draw the whole diff", for
    /// the reason `WorkspaceSearch` gives about an empty needle: "no filter" and "no matches" are
    /// different answers and only the caller knows which of the two its pane wants to draw. An
    /// empty array is the second of those, and the pane says it with a sentence.
    ///
    /// **Matched against the whole path, where `FileTreeFilter` matches the name unless a slash
    /// was typed.** That is the same divergence as above rather than a second one. Over there a
    /// folder is a node carrying a name of its own, so `migrations` finds the folder and its files
    /// come along with it, and testing fifty thousand sixty character paths on every keystroke is
    /// a cost worth not paying. Here there are no folder rows to find: they are built from the
    /// paths afterwards, so the path is the only thing a needle aimed at a directory can match. A
    /// diff of fifty files makes the cost question moot, and a filename is a suffix of its own
    /// path, so everything the other rule finds this one finds too.
    ///
    /// **The status letter is not searchable, and that is a decision rather than an omission.**
    /// `A` for added and `M` for modified are one character each, and one character handed to a
    /// subsequence matcher matches very nearly every path in a diff, so a field that claimed to
    /// filter by status would answer `A` with almost the whole list. It is a closed set of six
    /// values and it belongs on a control that can name them, beside the scope menu that already
    /// picks what the list is measured from, rather than as words a text field silently treats
    /// differently from every other word typed into it.
    public static func apply(to files: [ChangedFile], needle: String) -> [ChangedFile]? {
        guard !needle.isEmpty else { return nil }
        return files.filter { FileNeedle.matches($0.path, needle: needle) }
    }
}
