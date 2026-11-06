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

    // The light reading grounds of the five below (surface, raised, sunken) sit on Bloom's own
    // luminance steps and carry their colour in hue alone, because `textTertiary` and the syntax
    // comment clear 4.5 to 1 on white by a few hundredths and a darker ground fails
    // `ColourThemeTests`. Cyan and green hold so much luminance that a tint at Bloom's step is
    // invisible, so Lagoon and Matcha take their sidebar, selection and rule a step darker than
    // Bloom's. The dark members have room, which is why these themes are louder at night.

    public static let lagoon = tinted(id: "lagoon", title: "Lagoon", surfaces: ThemeSurfaces(
        surface: .init(light: 0xFBFFFF, dark: 0x052422),
        raised: .init(light: 0xFFFFFF, dark: 0x10312F),
        sunken: .init(light: 0xE6FFFE, dark: 0x062725),
        sidebar: .init(light: 0xD6F4F0, dark: 0x072B29),
        border: .init(light: 0x99D8D0, dark: 0x174543),
        selected: .init(light: 0xBDEAE4, dark: 0x134240)
    ))

    public static let sakura = tinted(id: "sakura", title: "Sakura", surfaces: ThemeSurfaces(
        surface: .init(light: 0xFFFEFE, dark: 0x2F0C17),
        raised: .init(light: 0xFFFFFF, dark: 0x4C1D2C),
        sunken: .init(light: 0xFFF9FB, dark: 0x360D1B),
        sidebar: .init(light: 0xFDF2F5, dark: 0x38101D),
        border: .init(light: 0xF2D8E0, dark: 0x60293B),
        selected: .init(light: 0xF7DFE7, dark: 0x63283C)
    ))

    public static let matcha = tinted(id: "matcha", title: "Matcha", surfaces: ThemeSurfaces(
        surface: .init(light: 0xFDFFFA, dark: 0x152405),
        raised: .init(light: 0xFFFFFF, dark: 0x213110),
        sunken: .init(light: 0xF0FFE0, dark: 0x172605),
        sidebar: .init(light: 0xE5F3CD, dark: 0x1A2B07),
        border: .init(light: 0xBCD996, dark: 0x2F4517),
        selected: .init(light: 0xD5EBB6, dark: 0x2C4213)
    ))

    public static let synthwave = tinted(id: "synthwave", title: "Synthwave", surfaces: ThemeSurfaces(
        surface: .init(light: 0xFFFEFF, dark: 0x210E38),
        raised: .init(light: 0xFFFFFF, dark: 0x392156),
        sunken: .init(light: 0xFBF9FF, dark: 0x261040),
        sidebar: .init(light: 0xF8F3FD, dark: 0x281341),
        border: .init(light: 0xE5DAF3, dark: 0x4A2D6A),
        selected: .init(light: 0xECE1F8, dark: 0x4B2D6D)
    ))

    public static let dune = tinted(id: "dune", title: "Dune", surfaces: ThemeSurfaces(
        surface: .init(light: 0xFFFEFD, dark: 0x201708),
        raised: .init(light: 0xFFFFFF, dark: 0x372914),
        sunken: .init(light: 0xFEFAF2, dark: 0x251A09),
        sidebar: .init(light: 0xFCF4E7, dark: 0x281C0B),
        border: .init(light: 0xECDDC6, dark: 0x49391F),
        selected: .init(light: 0xF3E4CD, dark: 0x4B391E)
    ))

    /// A theme whose code and terminal schemes share its id, so the editor and the shell stand
    /// on its own ground rather than on Bloom's navy.
    private static func tinted(id: String, title: String, surfaces: ThemeSurfaces) -> ColourTheme {
        var surfaces = surfaces
        surfaces.glassTint = surfaces.sidebar
        surfaces.glassTintOpacity = 0.8
        return ColourTheme(
            id: id, title: title, glass: .thick, surfaces: surfaces, codeScheme: id, terminalScheme: id
        )
    }
}
