/// Whether the pane under the header bar is showing what changed or the file itself.
enum FileViewMode: String, Hashable, CaseIterable {
    case diff = "Diff"
    case edit = "Edit"
}
