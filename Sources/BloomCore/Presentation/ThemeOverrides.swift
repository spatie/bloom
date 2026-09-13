import Foundation

/// What a person changed about one preset's look: its glass and its colour schemes.
///
/// Fonts, sizes and line heights are deliberately not here. They are `TypographyOverrides`, kept
/// once for every theme, because a reading size is about the person and not about the colours:
/// held per preset, switching from Bloom to Charcoal Glass silently put the conversation back at
/// the default size and let go of the Ghostty font, and the old settings only ever migrated into
/// whichever preset happened to be selected on the first launch.
public struct ThemeOverrides: Codable, Equatable, Sendable {
    public var glass: ThemeGlass?
    public var codeScheme: String?
    public var terminalSource: TerminalSource?

    public init() {}

    public struct Archive: Codable, Equatable, Sendable {
        public var schemaVersion = 1
        public var themes: [String: ThemeOverrides]
        /// Absent in an archive written before typography stopped being per preset, which is
        /// read as "not migrated yet" rather than as an error.
        public var typography: TypographyOverrides?

        public init(themes: [String: ThemeOverrides], typography: TypographyOverrides? = nil) {
            self.themes = themes
            self.typography = typography
        }

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
        if defaults.object(forKey: "useGhosttyTerminalTheme") as? Bool ?? true {
            value.terminalSource = .ghostty
        }
        if value.glass == theme.glass { value.glass = nil }
        return value
    }
}
