import Foundation

/// The fonts, sizes and line heights a person chose, applied under whichever preset is selected.
///
/// A nil field follows the selected preset's default. See `ThemeOverrides` for why this is kept
/// once rather than per preset.
public struct TypographyOverrides: Codable, Equatable, Sendable {
    public var codeTypography = ThemeTypography()
    public var terminalTypography = ThemeTypography()
    public var chatFont: String?
    public var chatTextSize: ChatTextSize?
    public var chatLineHeight: ChatLineHeight?

    public init() {}

    public static func migrating(from defaults: UserDefaults, theme: ColourTheme = .bloom) -> Self {
        var value = Self()
        // Canonicalised on the way in. A setting made before the font list existed is still
        // spelled `book` or `legible`, and the font menu's rows are tagged with the family names
        // those two became, so the raw string would leave no row selected. See
        // `ChatFontCatalogue.canonicalID`.
        value.chatFont = defaults.string(forKey: ChatFontCatalogue.defaultsKey).map(ChatFontCatalogue.canonicalID)
        value.chatTextSize = defaults.string(forKey: ChatTextSize.defaultsKey).flatMap(ChatTextSize.init(rawValue:))
        value.chatLineHeight = defaults.string(forKey: ChatLineHeight.defaultsKey).flatMap(ChatLineHeight.init(rawValue:))
        let size = defaults.double(forKey: "terminal.fontSize")
        if size > 0 { value.terminalTypography.fontSize = min(max(size, 9), 28) }
        if value.chatFont == theme.chatFont { value.chatFont = nil }
        if value.chatTextSize == theme.chatTextSize { value.chatTextSize = nil }
        if value.chatLineHeight == theme.chatLineHeight { value.chatLineHeight = nil }
        return value
    }
}
