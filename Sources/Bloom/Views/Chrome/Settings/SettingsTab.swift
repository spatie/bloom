/// The settings window's tabs.
///
/// A named value rather than the position a tab happens to sit in, so a reordering cannot silently
/// change which pane the window opens on.
enum SettingsTab: String, Hashable {
    case general
    case appearance
    case notifications
    case projects
    case models
    case agents
    case prompts
    case approvals
    case tools
    /// Coupling a client the owner runs themselves. See `TerminalSettingsView`.
    case terminal
    /// What the archived work costs and how to get the space back. It was a sidebar screen. See
    /// `StorageSettingsView`.
    case storage
    case about
}
