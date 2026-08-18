/// The settings window's tabs.
///
/// A named value rather than the position a tab happens to sit in, so a reordering cannot silently
/// change which pane the window opens on.
enum SettingsTab: Hashable {
    case general
    case appearance
    case notifications
    case projects
    case models
    case agents
    case prompts
    case tools
    case about
}
