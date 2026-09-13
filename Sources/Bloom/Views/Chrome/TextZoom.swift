import AppKit
import Foundation
import BloomCore

/// What the View menu's Zoom In, Zoom Out and Actual Size act on.
///
/// Bloom has three independent text sizes: the conversation, which is a named step on a scale of
/// rungs, and the code editor and a terminal, which are point sizes. A workspace can show them
/// side by side, so none of them is "the" text and there is no answer that holds all the time.
///
/// The items follow the keyboard. A code editor or terminal holding first responder is what
/// grows; anything else means the conversation. That is the only reading under which Cmd+Plus
/// enlarges the thing the user was just looking at, and it is what every editor with a console
/// pane already does. The conversation is the fallback rather than a do-nothing state, because a
/// window whose keyboard is in the sidebar is still a window whose reading matter is the
/// transcript, and a greyed-out size control with nothing focused would be a dead end nobody could
/// explain.
///
/// Focus is read the moment an item fires rather than cached, so it can never be stale: both a
/// menu click and a key equivalent run with the responder chain already settled.
@MainActor
enum TextZoom {
    static func zoomIn() { adjust(by: 1) }

    static func zoomOut() { adjust(by: -1) }

    /// Home for each is no override, which is how a shell goes back to following the size in the
    /// user's Ghostty config, and code and conversation to their defaults, rather than to some
    /// number Bloom picked.
    static func actualSize() {
        if focusedTerminal != nil {
            TerminalTextSize.override = nil
        } else if focusedCode != nil {
            ColourThemePreference.shared.typographyOverrides.codeTypography.fontSize = nil
        } else {
            ColourThemePreference.shared.typographyOverrides.chatTextSize = nil
        }
    }

    static var canZoomIn: Bool { canAdjust(by: 1) }

    static var canZoomOut: Bool { canAdjust(by: -1) }

    static var canResetSize: Bool {
        if focusedTerminal != nil { return TerminalTextSize.override != nil }
        if focusedCode != nil { return ColourThemePreference.shared.typographyOverrides.codeTypography.fontSize != nil }
        return ColourThemePreference.shared.typographyOverrides.chatTextSize != nil
    }

    private static func adjust(by steps: Int) {
        if let terminal = focusedTerminal {
            TerminalTextSize.adjust(from: terminal.fontSize, by: TerminalTextSize.step * CGFloat(steps))
        } else if focusedCode != nil {
            let next = Double(CodeMetrics.font.pointSize) + Double(steps)
            ColourThemePreference.shared.typographyOverrides.codeTypography.fontSize = min(max(next, 9), 28)
        } else if let next = ColourThemePreference.shared.chatTextSize.stepped(by: steps) {
            ColourThemePreference.shared.chatTextSize = next
        }
    }

    private static func canAdjust(by steps: Int) -> Bool {
        if let terminal = focusedTerminal {
            return TerminalTextSize.canAdjust(
                from: terminal.fontSize, by: TerminalTextSize.step * CGFloat(steps)
            )
        }
        if focusedCode != nil {
            let current = Double(CodeMetrics.font.pointSize)
            return min(max(current + Double(steps), 9), 28) != current
        }
        return ColourThemePreference.shared.chatTextSize.stepped(by: steps) != nil
    }

    private static var focusedCode: CodeTextView? { focusedView(CodeTextView.self) }

    private static var focusedTerminal: BloomTerminalView? { focusedView(BloomTerminalView.self) }

    /// The view of that type holding the keyboard, if one is.
    ///
    /// Walked up the responder chain rather than compared against first responder once, so a view
    /// SwiftTerm may put in front of its own remains a terminal. Nothing else in the window has a
    /// terminal or editor above it in the chain, so a caret in the composer or a row in the sidebar
    /// answers nil and the conversation is what grows.
    ///
    /// `keyWindow` and not `mainWindow`: while the menu bar is tracking, the menu's own panel is
    /// neither, and the window underneath is still the key one.
    private static func focusedView<T: NSView>(_ type: T.Type) -> T? {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if let view = current as? T { return view }
            responder = current.nextResponder
        }
        return nil
    }
}
