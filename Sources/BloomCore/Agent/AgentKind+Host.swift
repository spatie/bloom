import Foundation

public extension AgentKind {
    /// Absolute path to the file the settings screen offers to open.
    ///
    /// Claude Code and Codex point at a real config file. Cursor and OpenCode point at their
    /// config directory instead, because their file layout is not verified and guessing a
    /// filename would send the user to something that does not exist.
    var configPath: String {
        let home = NSHomeDirectory()
        switch self {
        case .claudeCode: return "\(home)/.claude/settings.json"
        case .codex: return "\(home)/.codex/config.toml"
        case .grok: return "\(home)/.grok/config.toml"
        case .cursor: return "\(home)/.cursor"
        case .openCode: return "\(home)/.opencode"
        }
    }

}
