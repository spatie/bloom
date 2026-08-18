/// Where the flat versus tree choice for the changed files lives. Shared by the toggle in the tab
/// row and the list itself, which is why it is a named key rather than a literal in two files.
enum ChangedFilePresentation {
    static let storageKey = "inspector.changedFilesAsTree"
}
