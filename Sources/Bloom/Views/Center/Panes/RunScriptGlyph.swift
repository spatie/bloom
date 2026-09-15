import AppKit
import BloomCore

/// What a run script wears in the `+` menu and on its tab.
///
/// The settings file may name any SF Symbol, and the core cannot ask whether a name exists, so the
/// question is asked here: a name that resolves is used, and anything else, a typo or a symbol
/// from a newer system, falls back to the glyph every terminal wears rather than drawing a blank.
@MainActor
enum RunScriptGlyph {
    /// Answers already looked up, because the strip asks on every redraw and the symbol catalogue
    /// does not change while the app is running.
    private static var resolved: [String: Bool] = [:]

    static func symbol(for icon: String?) -> String {
        guard let icon = icon?.trimmingCharacters(in: .whitespaces), !icon.isEmpty else {
            return PaneGlyph.terminal
        }
        if let known = resolved[icon] { return known ? icon : PaneGlyph.terminal }
        let exists = NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil
        resolved[icon] = exists
        return exists ? icon : PaneGlyph.terminal
    }
}
