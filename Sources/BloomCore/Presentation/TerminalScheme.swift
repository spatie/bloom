import Foundation

public struct TerminalScheme: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var light: GhosttyTheme
    public var dark: GhosttyTheme

    public static let all: [Self] = [.bloom, .charcoal, .lagoon, .sakura, .matcha, .synthwave, .dune]
    public static func find(_ key: String?, fallback: Self = .bloom) -> Self {
        all.first { $0.id == key } ?? fallback
    }
}
