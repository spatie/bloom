public struct ThemeSurfaces: Codable, Sendable, Hashable {
    public let surface: PaletteInk.Pair
    public let raised: PaletteInk.Pair
    public let sunken: PaletteInk.Pair
    public let sidebar: PaletteInk.Pair
    public let border: PaletteInk.Pair
    public let selected: PaletteInk.Pair
    public var glassTint: PaletteInk.Pair?
    public var glassTintOpacity: Double?
}
