import Foundation

public struct ThemeOverrides: Codable, Equatable, Sendable {
    public var glass: ThemeGlass?
    public var codeScheme: String?
    public var terminalSource: TerminalSource?
    public var codeTypography = ThemeTypography()
    public var terminalTypography = ThemeTypography()
    public var chatFont: String?
    public var chatTextSize: ChatTextSize?
    public var chatLineHeight: ChatLineHeight?

    public init() {}

    public struct Archive: Codable, Equatable, Sendable {
        public var schemaVersion = 1
        public var themes: [String: ThemeOverrides]

        public init(themes: [String: ThemeOverrides]) { self.themes = themes }

        public static func decode(_ data: Data) throws -> Self {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.schemaVersion == 1 else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported theme settings version"))
            }
            return value
        }
    }

    public func codeScheme(for theme: ColourTheme) -> CodeScheme {
        CodeScheme.find(codeScheme, fallback: CodeScheme.find(theme.codeScheme))
    }

    public func terminalScheme(for theme: ColourTheme) -> TerminalScheme {
        let fallback = TerminalScheme.find(theme.terminalScheme)
        guard case .builtin(let key) = terminalSource else { return fallback }
        return TerminalScheme.find(key, fallback: fallback)
    }

    public static func migrating(from defaults: UserDefaults, theme: ColourTheme = .bloom) -> Self {
        var value = Self()
        value.glass = defaults.string(forKey: "sidebarGlassOverride").flatMap(ThemeGlass.init(rawValue:))
        value.chatFont = defaults.string(forKey: ChatFontCatalogue.defaultsKey).map(ChatFontCatalogue.canonicalID)
        value.chatTextSize = defaults.string(forKey: ChatTextSize.defaultsKey).flatMap(ChatTextSize.init(rawValue:))
        value.chatLineHeight = defaults.string(forKey: ChatLineHeight.defaultsKey).flatMap(ChatLineHeight.init(rawValue:))
        if defaults.object(forKey: "useGhosttyTerminalTheme") as? Bool ?? true {
            value.terminalSource = .ghostty
        }
        let size = defaults.double(forKey: "terminal.fontSize")
        if size > 0 { value.terminalTypography.fontSize = min(max(size, 9), 28) }
        if value.glass == theme.glass { value.glass = nil }
        if value.chatFont == theme.chatFont { value.chatFont = nil }
        if value.chatTextSize == theme.chatTextSize { value.chatTextSize = nil }
        if value.chatLineHeight == theme.chatLineHeight { value.chatLineHeight = nil }
        return value
    }
}
