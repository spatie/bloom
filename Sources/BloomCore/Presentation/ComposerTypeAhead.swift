import Foundation

/// Which presses, made while nothing takes typing, move the keyboard to the composer: printable
/// characters and Command+V. Everything else keeps its own meaning.
public enum ComposerTypeAhead {
    /// - Parameter characters: the characters ignoring modifiers for a dead key, so the accent
    ///   starts in the composer.
    public static func belongsToComposer(characters: String?, modifiers: MenuShortcut.Modifiers) -> Bool {
        guard let characters, let first = characters.unicodeScalars.first else { return false }
        if modifiers == .command { return isPaste(characters: characters, modifiers: modifiers) }
        guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
        // Not Space: over a file it opens the preview.
        return !CharacterSet.whitespacesAndNewlines.contains(first)
            && characters.unicodeScalars.allSatisfy(isTyped)
    }

    /// A selected passage in read-only text keeps typed characters, because R quotes it, but not
    /// Command+V: nothing there can paste, so the press would otherwise be swallowed.
    public static func isPaste(characters: String?, modifiers: MenuShortcut.Modifiers) -> Bool {
        modifiers == .command && characters?.lowercased() == "v"
    }

    /// Arrows and function keys are private use characters in AppKit.
    private static func isTyped(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && !functionKeys.contains(scalar.value)
    }

    private static let functionKeys: ClosedRange<UInt32> = 0xF700...0xF8FF
}
