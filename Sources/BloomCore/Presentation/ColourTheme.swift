import Foundation

public struct ColourTheme: Codable, Hashable, Sendable, Identifiable, CaseIterable {
    public let schemaVersion: Int
    public let codeScheme: String
    public let terminalScheme: String
    public let codeTypography: ThemeTypography
    public let terminalTypography: ThemeTypography
    public let chatFont: String
    public let chatTextSize: ChatTextSize
    public let chatLineHeight: ChatLineHeight
    public let id: String
    public let title: String
    public let glass: ThemeGlass
    public let surfaces: ThemeSurfaces

    public static let defaultsKey = "colourTheme"
    public static let allCases: [ColourTheme] = [.bloom, .charcoalGlass]

    public init(
        id: String, title: String, glass: ThemeGlass, surfaces: ThemeSurfaces,
        codeScheme: String = "bloom", terminalScheme: String = "bloom",
        codeTypography: ThemeTypography = .init(fontSize: 13, lineHeight: 1.2),
        terminalTypography: ThemeTypography = .init(lineHeight: 1),
        chatFont: String = ChatFontCatalogue.standardID,
        chatTextSize: ChatTextSize = .defaultChoice,
        chatLineHeight: ChatLineHeight = .defaultChoice
    ) {
        self.schemaVersion = 1
        self.codeScheme = codeScheme
        self.terminalScheme = terminalScheme
        self.codeTypography = codeTypography
        self.terminalTypography = terminalTypography
        self.chatFont = chatFont
        self.chatTextSize = chatTextSize
        self.chatLineHeight = chatLineHeight
        self.id = id
        self.title = title
        self.glass = glass
        self.surfaces = surfaces
    }

    public init(storedValue: String?) {
        self = Self.allCases.first { $0.id == storedValue } ?? .bloom
    }
}
