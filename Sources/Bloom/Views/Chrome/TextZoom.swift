import AppKit
import Foundation

/// What the View menu's Zoom In, Zoom Out and Actual Size act on.
///
/// Bloom has two independent text sizes: the conversation, which is a named step on a scale of
/// rungs, and a terminal, which is a point size. A workspace can show a chat pane and a terminal
/// side by side, so neither of them is "the" text and there is no answer that holds all the time.
///
/// The items follow the keyboard. A terminal holding first responder is what grows; anything else
/// means the conversation. That is the only reading under which Cmd+Plus enlarges the thing the
/// user was just looking at, and it is what every editor with a console pane already does. The
/// conversation is the fallback rather than a third do-nothing state, because a window whose
/// keyboard is in the sidebar is still a window whose reading matter is the transcript, and a
/// greyed-out size control with nothing focused would be a dead end nobody could explain.
///
/// Focus is read the moment an item fires rather than cached, so it can never be stale: both a
/// menu click and a key equivalent run with the responder chain already settled.
@MainActor
enum TextZoom {
    static func zoomIn() { adjust(by: 1) }

    static func zoomOut() { adjust(by: -1) }

    /// Home for each: `standard` for the conversation, no override at all for a terminal, which is
    /// how a shell goes back to following the size in the user's Ghostty config rather than to
    /// some number Bloom picked.
    static func actualSize() {
        if focusedTerminal != nil {
            TerminalTextSize.override = nil
        } else {
            ChatTextSize.current = .standard
        }
    }

    static var canZoomIn: Bool { canAdjust(by: 1) }

    static var canZoomOut: Bool { canAdjust(by: -1) }

    static var canResetSize: Bool {
        if focusedTerminal != nil { return TerminalTextSize.override != nil }
        return ChatTextSize.current != .standard
    }

    private static func adjust(by steps: Int) {
        if let terminal = focusedTerminal {
            TerminalTextSize.adjust(from: terminal.fontSize, by: TerminalTextSize.step * CGFloat(steps))
        } else if let next = ChatTextSize.current.stepped(by: steps) {
            ChatTextSize.current = next
        }
    }

    private static func canAdjust(by steps: Int) -> Bool {
        if let terminal = focusedTerminal {
            return TerminalTextSize.canAdjust(
                from: terminal.fontSize, by: TerminalTextSize.step * CGFloat(steps)
            )
        }
        return ChatTextSize.current.stepped(by: steps) != nil
    }

    /// The terminal holding the keyboard, if one is.
    ///
    /// Walked up the responder chain rather than compared against first responder once, so a view
    /// SwiftTerm may put in front of its own remains a terminal. Nothing else in the window has a
    /// terminal above it in the chain, so a caret in the composer or a row in the sidebar answers
    /// nil and the conversation is what grows.
    ///
    /// `keyWindow` and not `mainWindow`: while the menu bar is tracking, the menu's own panel is
    /// neither, and the window underneath is still the key one.
    private static var focusedTerminal: BloomTerminalView? {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if let terminal = current as? BloomTerminalView { return terminal }
            responder = current.nextResponder
        }
        return nil
    }
}
