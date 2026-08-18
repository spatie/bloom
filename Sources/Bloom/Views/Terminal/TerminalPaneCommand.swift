import AppKit
import BloomCore

/// What a keystroke inside a terminal asks the tab holding it to do with its panes.
///
/// The bindings are iTerm's, which are also Ghostty's, so a user of either has nothing to learn
/// here. They are recognised in the terminal rather than declared as menu shortcuts because that
/// is the only place that knows a shell has the keyboard: Cmd+W has to close a pane when it does
/// and a session when it does not.
enum TerminalPaneCommand: Sendable, Hashable {
    case split(SplitAxis)
    case focus(SplitDirection)
    case close
    case toggleZoom

    /// - Parameter key: `charactersIgnoringModifiers`, lowercased, so Shift is read from the flags
    ///   rather than from the character.
    init?(key: String, modifiers: NSEvent.ModifierFlags) {
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)

        if option, let direction = Self.direction(for: key) {
            self = .focus(direction)
            return
        }

        switch key {
        case "d" where !option:
            self = .split(shift ? .vertical : .horizontal)
        case "w" where !shift && !option:
            self = .close
        // Both Returns, because the one on the numeric keypad sends a different character and a
        // user pressing it means the same thing.
        case "\r", "\u{3}":
            guard shift, !option else { return nil }
            self = .toggleZoom
        default:
            return nil
        }
    }

    private static func direction(for key: String) -> SplitDirection? {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return .left
        case NSRightArrowFunctionKey: return .right
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        default: return nil
        }
    }
}
