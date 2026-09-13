extension CodeScheme {
    public static let bloom = builtin(id: "bloom", title: "Bloom", background: PaletteInk.surface)
    public static let charcoal = builtin(
        id: "charcoal", title: "Charcoal", background: .init(light: 0xFFFFFF, dark: 0x292C33)
    )

    /// A constant is a number as far as these schemes are concerned, and saying so is cheaper than
    /// keeping two copies of one pair in step.
    private static func builtin(id: String, title: String, background: PaletteInk.Pair) -> Self {
        Self(
            id: id, title: title, background: background,
            foreground: .init(light: 0x202124, dark: 0xECECF1),
            gutter: PaletteInk.textTertiary,
            caret: PaletteInk.accent,
            selection: .init(light: 0xC8DCF4, dark: 0x42454B),
            diffAdd: PaletteInk.diffPositive,
            diffDelete: PaletteInk.negative,
            tokens: [
                .keyword: PaletteInk.synKeyword, .type: PaletteInk.synType,
                .string: PaletteInk.synString, .number: PaletteInk.synNumber,
                .comment: PaletteInk.synComment, .function: PaletteInk.synFunction,
                .variable: PaletteInk.synVariable, .attribute: PaletteInk.synAttribute,
                .operator: PaletteInk.synOperator, .punctuation: PaletteInk.synOperator,
                .regex: PaletteInk.synString, .constant: PaletteInk.synNumber,
            ]
        )
    }
}
