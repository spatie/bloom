/// The terminal's opaque ANSI ramp is shared across Apple clients. Green stays distinct from
/// Bloom's accent, and each grey has its own RGB value rather than relying on label opacity.
public enum TerminalPalette {
    public static let green = PaletteInk.Pair(light: 0x2E7D32, dark: 0x6FCF7B)
    public static let black = PaletteInk.Pair(light: 0x000000, dark: 0x1C1C1E)
    public static let brightBlack = PaletteInk.Pair(light: 0x4D4D4D, dark: 0x636366)
    public static let white = PaletteInk.Pair(light: 0x8E8E93, dark: 0xAEAEB2)
    public static let brightWhite = PaletteInk.Pair(light: 0xB0B0B5, dark: 0xFFFFFF)

    /// Purple and cyan remain native system colours supplied by each platform adapter.
    public static func ansi<Color>(resolve: (PaletteInk.Pair) -> Color, purple: Color, cyan: Color) -> [Color] {
        [resolve(black), resolve(PaletteInk.negative), resolve(green), resolve(PaletteInk.warning),
         resolve(PaletteInk.accent), purple, cyan, resolve(white),
         resolve(brightBlack), resolve(PaletteInk.negative), resolve(green), resolve(PaletteInk.warning),
         resolve(PaletteInk.accent), purple, cyan, resolve(brightWhite)]
    }
}
