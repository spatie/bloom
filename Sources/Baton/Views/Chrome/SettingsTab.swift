/// The settings window's tabs.
///
/// A named value rather than the position a tab happens to sit in, so a reordering cannot silently
/// change which pane the window opens on.
enum SettingsTab: Hashable {
    case general
    case projects
    case models
    case agents
    case tools
    case about
}
