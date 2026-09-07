/// Editing keys claimed before the application menu sees them. The caller must first establish
/// that this terminal is the first responder, so an unfocused pane cannot steal Archive.
public enum TerminalEditingShortcut {
    public enum Input: Equatable, Sendable {
        case text(String)
        case keyEvent
    }

    /// SwiftTerm's legacy text interpreter does not implement deleteToBeginningOfLine. Ordinary
    /// shells therefore need Ctrl+U, while an application which negotiated enhanced keyboard
    /// reporting must receive the original key and its modifiers through SwiftTerm's encoder.
    public static func input(
        key: String,
        isPlainCommand: Bool,
        usesEnhancedKeyboard: Bool
    ) -> Input? {
        guard isPlainCommand, key == "\u{7f}" || key == "\u{8}" else { return nil }
        return usesEnhancedKeyboard ? .keyEvent : .text("\u{15}")
    }
}
