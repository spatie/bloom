extension TerminalScheme {
    /// On the panel's own surface, so the shell sits on the same colour as the setup and run logs
    /// it shares a tab strip with.
    public static let bloom = builtin(id: "bloom", title: "Bloom", background: PaletteInk.surfaceSunken)
    public static let charcoal = builtin(
        id: "charcoal", title: "Charcoal", background: ColourTheme.charcoalGlass.surfaces.sunken
    )

    private static func builtin(id: String, title: String, background: PaletteInk.Pair) -> Self {
        Self(id: id, title: title,
             light: palette(background: background, dark: false),
             dark: palette(background: background, dark: true))
    }

    /// The sixteen ANSI slots, and the colours around them.
    ///
    /// Red, yellow and blue are Bloom's, so a failing test's red in the terminal is the same red
    /// as a failed step everywhere else in the window. Green is NOT, and that is the one to
    /// understand: the app's `positive` is the accent, because the brand ramp says to reuse the
    /// accent rather than invent a green. That is right for a tick beside a passing check, and
    /// wrong here, because ANSI green and ANSI blue are two different slots and a program that
    /// prints both would print them in one colour. So this palette keeps a green of its own,
    /// which is what every terminal theme does. It is tuned to sit beside `negative` and `warning`
    /// at the same volume they do, rather than to be `systemGreen`, which is a step brighter than
    /// everything else this terminal prints.
    ///
    /// The four greyscale slots cannot be the label colours either: those differ from each other
    /// in alpha and in nothing else, and SwiftTerm stores a colour as three opaque bytes.
    /// Dropping the alpha collapsed black, white, bright black and bright white to one identical
    /// value, so black-on-white, which is most of what a Powerline prompt draws, came out as a
    /// solid block with nothing legible inside it. They are per appearance for the same reason
    /// the background is: a fixed `#FFFFFF` for bright white would be invisible on a light panel,
    /// and a fixed `#000000` black unreadable on a dark one.
    ///
    /// They stay ordered dark to light within each appearance, because every program that colours
    /// its own output assumes slot 8 is a lighter slot 0 and slot 15 a lighter slot 7.
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
