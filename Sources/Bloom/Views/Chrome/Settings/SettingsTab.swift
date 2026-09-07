/// Only visible destinations belong here, so navigation cannot retain removed panes.
enum SettingsTab: String, Hashable, CaseIterable {
    case general
    case appearance
    case notifications
    case agents
    case sessions
    case permissions
    case prompts
    case terminal
    case commandLine

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .sessions: "Sessions"
        case .permissions: "Permissions"
        case .prompts: "Prompts"
        case .terminal: "Terminal"
        case .commandLine: "Command Line"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .appearance: "paintbrush"
        case .notifications: "bell"
        case .agents: "person.2"
        case .sessions: "bubble.left.and.bubble.right"
        case .permissions: "hand.raised"
        case .prompts: "text.bubble"
        case .terminal: "terminal"
        case .commandLine: "link"
        }
    }
}
