public enum TerminalSource: Codable, Hashable, Sendable {
    case builtin(String)
    case ghostty
}
