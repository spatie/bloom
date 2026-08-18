/// Where the unified versus side by side choice lives. Shared with the toggle in the tab row,
/// which is why it is a named key rather than a literal in two files.
enum DiffLayoutSetting {
    static let storageKey = "inspector.diffSideBySide"
}
