extension TerminalScheme {
    public static let bloom = builtin(id: "bloom", title: "Bloom", background: PaletteInk.surfaceSunken)
    public static let charcoal = builtin(
        id: "charcoal", title: "Charcoal", background: ColourTheme.charcoalGlass.surfaces.sunken
    )

    private static func builtin(id: String, title: String, background: PaletteInk.Pair) -> Self {
        Self(id: id, title: title,
             light: palette(background: background, dark: false),
             dark: palette(background: background, dark: true))
    }

    private static func palette(background: PaletteInk.Pair, dark: Bool) -> GhosttyTheme {
        func colour(_ pair: PaletteInk.Pair) -> GhosttyColor {
            let rgb = pair.member(dark: dark)
            return GhosttyColor(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))
        }
        let green = PaletteInk.Pair(light: 0x2E7D32, dark: 0x6FCF7B)
        let purple = PaletteInk.Pair(light: 0x8945AB, dark: 0xCC8FE8)
        let cyan = PaletteInk.Pair(light: 0x007A82, dark: 0x65CFD4)
        let pairs: [PaletteInk.Pair] = [
            .init(light: 0x000000, dark: 0x1C1C1E),
            PaletteInk.negative, green, PaletteInk.warning, PaletteInk.accent, purple, cyan,
            .init(light: 0x8E8E93, dark: 0xAEAEB2),
            .init(light: 0x4D4D4D, dark: 0x636366),
            PaletteInk.negative, green, PaletteInk.warning, PaletteInk.accent, purple, cyan,
            .init(light: 0xB0B0B5, dark: 0xFFFFFF),
        ]
        var result = GhosttyTheme()
        result.background = colour(background)
        result.foreground = colour(.init(light: 0x202124, dark: 0xECECF1))
        result.cursorColor = result.foreground
        result.cursorTextColor = result.background
        result.selectionBackground = colour(.init(light: 0xC8DCF4, dark: 0x42454B))
        result.selectionForeground = result.foreground
        result.palette = Dictionary(uniqueKeysWithValues: pairs.enumerated().map { ($0.offset, colour($0.element)) })
        return result
    }
}
