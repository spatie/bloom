/// Only visible destinations belong here, so navigation cannot retain removed panes.
enum SettingsTab: String, Hashable, CaseIterable {
    case general
    case appearance
    case menuBar
    case notifications
    case agents
    case sessions
    case presets
    case permissions
    case prompts
    case terminal
    case browserAccess
    case passwords
    case commandLine
    case mail

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .menuBar: "Menu Bar"
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .sessions: "Sessions"
        case .presets: "Model Presets"
        case .permissions: "Permissions"
        case .prompts: "Prompts"
        case .terminal: "Terminal"
        case .browserAccess: "Browser Access"
        case .passwords: "Passwords"
        case .commandLine: "Command Line"
        case .mail: "Incoming mails"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .appearance: "paintbrush"
        case .menuBar: "menubar.rectangle"
        case .notifications: "bell"
        case .agents: "person.2"
        case .sessions: "bubble.left.and.bubble.right"
        case .presets: "slider.horizontal.3"
        case .permissions: "hand.raised"
        case .prompts: "text.bubble"
        case .terminal: "terminal"
        case .browserAccess: "network"
        case .passwords: "key"
        case .commandLine: "link"
        case .mail: "envelope"
        }
    }
}
