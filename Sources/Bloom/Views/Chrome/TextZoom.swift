import AppKit
import Foundation
import BloomCore

// Zoom follows the focused code editor or terminal, with conversation as the fallback.
@MainActor
enum TextZoom {
    static func zoomIn() { adjust(by: 1) }

    static func zoomOut() { adjust(by: -1) }

    static func actualSize() {
        if focusedTerminal != nil {
            TerminalTextSize.override = nil
        } else if focusedCode != nil {
            ColourThemePreference.shared.overrides.codeTypography.fontSize = nil
        } else {
            ColourThemePreference.shared.overrides.chatTextSize = nil
        }
    }

    static var canZoomIn: Bool { canAdjust(by: 1) }

    static var canZoomOut: Bool { canAdjust(by: -1) }

    static var canResetSize: Bool {
        if focusedTerminal != nil { return TerminalTextSize.override != nil }
        if focusedCode != nil { return ColourThemePreference.shared.overrides.codeTypography.fontSize != nil }
        return ColourThemePreference.shared.overrides.chatTextSize != nil
    }

    private static func adjust(by steps: Int) {
        if let terminal = focusedTerminal {
            TerminalTextSize.adjust(from: terminal.fontSize, by: TerminalTextSize.step * CGFloat(steps))
        } else if focusedCode != nil {
            let next = Double(CodeMetrics.font.pointSize) + Double(steps)
            ColourThemePreference.shared.overrides.codeTypography.fontSize = min(max(next, 9), 28)
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

    private static func focusedView<T: NSView>(_ type: T.Type) -> T? {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if let view = current as? T { return view }
            responder = current.nextResponder
        }
        return nil
    }
}
