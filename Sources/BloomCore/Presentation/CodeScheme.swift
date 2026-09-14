import Foundation

public struct CodeScheme: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var background: PaletteInk.Pair
    public var foreground: PaletteInk.Pair
    public var gutter: PaletteInk.Pair
    public var caret: PaletteInk.Pair
    public var selection: PaletteInk.Pair
    public var diffAdd: PaletteInk.Pair
    public var diffDelete: PaletteInk.Pair
    public var tokens: [TokenKind: PaletteInk.Pair]

    public func colour(for kind: TokenKind) -> PaletteInk.Pair {
        tokens[kind] ?? foreground
    }

    public static let all: [Self] = [.bloom, .charcoal]
    public static func find(_ key: String?, fallback: Self = .bloom) -> Self {
        all.first { $0.id == key } ?? fallback
    }
}
