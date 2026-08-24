import Foundation

/// Every colour Bloom states as a number, in the one place a test can read them.
///
/// `Palette` in the app target is what the window draws with, and it is `Color` and `NSColor`,
/// which is exactly why the values could not be checked: `Tests/BloomCoreTests` depends on
/// `BloomCore` alone, so a ratio written in a doc comment beside a `Color` was a claim nothing
/// could ever contradict. Several of those claims were wrong and one of them said so.
///
/// So the numbers live here and `Palette` reads them. Nothing about how a colour is resolved
/// moved: the light and dark members, the appearance switch, and every doc comment explaining why
/// a hue was chosen are all still next to the `Color` in `Theme.swift`. What is here is the pair
/// of integers and nothing else, which is all `Contrast` needs and all a table test can assert.
///
/// See `PaletteContrastTests`, which is the point of this file: it walks every pair against every
/// ground it is drawn on and fails the build when one of them stops clearing its floor.
public enum PaletteInk {
    /// A colour's two members. There is no third: `Palette.dynamicNSColor` picks between exactly
    /// these two, and a value that is one colour in both appearances says so by repeating itself,
    /// the way `accentFill` and `mergedFill` do.
    public struct Pair: Sendable, Hashable {
        public let light: UInt32
        public let dark: UInt32

        public init(light: UInt32, dark: UInt32) {
            self.light = light
            self.dark = dark
        }

        /// The member drawn in one appearance, so a test can walk both without a switch at every
        /// call site.
        public func member(dark isDark: Bool) -> UInt32 { isDark ? dark : light }
    }

    public static let windowBackground = Pair(light: 0xFFFFFF, dark: 0x0A1A25)
    public static let surface = Pair(light: 0xFFFFFF, dark: 0x0A1A25)
    public static let surfaceRaised = Pair(light: 0xFFFFFF, dark: 0x16303F)
    public static let surfaceSunken = Pair(light: 0xF7FAFA, dark: 0x0C1E2A)
    public static let selected = Pair(light: 0xDCE7EA, dark: 0x1D4054)
    public static let border = Pair(light: 0xD6E0E4, dark: 0x1E3F53)
    public static let textTertiary = Pair(light: 0x69757B, dark: 0x769AAA)
    public static let accent = Pair(light: 0x0C7A6E, dark: 0x4FD8C4)
    public static let accentFill = Pair(light: 0x197593, dark: 0x197593)
    public static let negative = Pair(light: 0xB23A2E, dark: 0xEC6D61)
    public static let stop = Pair(light: 0x994842, dark: 0xD07D78)
    public static let warning = Pair(light: 0x9A6A00, dark: 0xE8A33D)
    public static let merged = Pair(light: 0x8250DF, dark: 0xAA7BF8)
    public static let mergedFill = Pair(light: 0x8250DF, dark: 0x8250DF)
    public static let diffPositive = Pair(light: 0x28CD41, dark: 0x30D158)
    public static let synKeyword = Pair(light: 0x9B2393, dark: 0xD08EE0)
    public static let synType = Pair(light: 0x0B7285, dark: 0x5BC8DB)
    public static let synString = Pair(light: 0xC0392B, dark: 0xE8846E)
    public static let synNumber = Pair(light: 0x1C6FBB, dark: 0x7FB3F0)
    public static let synComment = Pair(light: 0x6D7879, dark: 0x818189)
    public static let synFunction = Pair(light: 0x2F5FD0, dark: 0x89AFF5)
    public static let synVariable = Pair(light: 0x6A3FB5, dark: 0xB49BF0)
    public static let synAttribute = Pair(light: 0x8A6A00, dark: 0xD9B65C)
    public static let synOperator = Pair(light: 0x5A5A60, dark: 0xA8A8B0)
}
