extension ColourTheme {
    public static let bloom = ColourTheme(
        id: "bloom",
        title: "Bloom",
        glass: .thick,
        surfaces: ThemeSurfaces(
            surface: PaletteInk.surface,
            raised: PaletteInk.surfaceRaised,
            sunken: PaletteInk.surfaceSunken,
            sidebar: PaletteInk.sidebar,
            border: PaletteInk.border,
            selected: PaletteInk.selected,
            glassTint: PaletteInk.sidebar,
            glassTintOpacity: 0.8
        )
    )

    public static let charcoalGlass = ColourTheme(
        id: "neutral",
        title: "Charcoal Glass",
        glass: .thick,
        surfaces: ThemeSurfaces(
            surface: .init(light: 0xFFFFFF, dark: 0x292C33),
            raised: .init(light: 0xFFFFFF, dark: 0x2A2D34),
            sunken: .init(light: 0xFAFAFA, dark: 0x25282F),
            sidebar: .init(light: 0xF5F5F5, dark: 0x30343B),
            border: .init(light: 0xDEDEDE, dark: 0x4F535C),
            selected: .init(light: 0xE5E5E5, dark: 0x42454B),
            glassTint: .init(light: 0xFAFAFA, dark: 0x212938),
            glassTintOpacity: 0.4
        ),
        codeScheme: "charcoal", terminalScheme: "charcoal"
    )
}
