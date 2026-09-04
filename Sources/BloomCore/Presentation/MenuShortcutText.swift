import Foundation

/// A key equivalent written the way the menu bar writes it, for a surface that has to print one
/// itself.
///
/// The menu bar never needs this: `keyboardShortcut` hands `MenuShortcut` to AppKit and AppKit
/// draws the glyphs. The search panel does, because it prints the key beside every command row so
/// the reader learns the shortcut for next time. That is Superhuman's argument, taken with
/// Linear's correction: a palette teaches only the shortcuts somebody already went looking for,
/// which is why the menus keep theirs.
///
/// It is here rather than beside the panel because it is a spelling of the same table
/// `MenuBarCatalogue` holds, and a second spelling of a shortcut is how one surface ends up
/// teaching a key the bar does not have.
extension MenuShortcut {
    /// The modifiers in the order macOS draws them, then the key.
    ///
    /// Control, Option, Shift, Command, which is the order in every menu on the platform and is
    /// not the order the `OptionSet` happens to be declared in.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        return text + Self.glyph(for: trigger)
    }

    /// The key itself. The five that are not characters get the glyph a menu draws for them, and a
    /// letter is drawn in upper case, which is what a menu does whether or not Shift is in the
    /// combination.
    static func glyph(for trigger: Trigger) -> String {
        switch trigger {
        case .character(let character): String(character).uppercased()
        case .upArrow: "\u{2191}"
        case .downArrow: "\u{2193}"
        case .leftArrow: "\u{2190}"
        case .rightArrow: "\u{2192}"
        // Backspace, which is what Archive Workspace takes. The forward delete glyph is a
        // different character and would be a different key.
        case .delete: "\u{232B}"
        case .return: "\u{21A9}"
        case .comma: ","
        }
    }
}

extension MenuBarItem {
    /// What the panel prints on this row's trailing edge, which is the key or the words "no key".
    ///
    /// A blank slot would say nothing about which of the two a row is, and nineteen items in the
    /// bar carry no shortcut at all. See `SearchPanelCommands.noKey`.
    public var keyText: String { key?.display ?? SearchPanelCommands.noKey }
}
