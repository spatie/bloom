/// Where the flat versus tree choice for the changed files lives. Shared by the toggle in the tab
/// row and the list itself, which is why it is a named key rather than a literal in two files.
enum ChangedFilePresentation {
    static let storageKey = "inspector.changedFilesAsTree"

    /// A tree by default. A flat list only reads well when a change touches a handful of files in
    /// one place; the moment it spans `app/` and `tests/` the folder each file lives in is the
    /// first thing you need, and the tree collapses single-child chains so that costs no depth.
    ///
    /// Named here rather than written at both call sites, which each carried their own literal and
    /// so were free to disagree about what the default was.
    static let defaultsToTree = true
}
