import Foundation

/// How far apart two colours are, by the one definition anybody can be held to.
///
/// This exists because the project had no way to ask. `Palette` carries measured ratios in its doc
/// comments, several of them wrong and one of them admitting it, and nothing re-checked any of
/// them: a `grep` for "contrast" across the tests returned a single hit and it was about
/// animation. So every colour decision was a number somebody worked out once, wrote down, and
/// could not be reminded of again.
///
/// The maths is WCAG 2.1's, unchanged: channels linearised out of sRGB, weighted 0.2126, 0.7152
/// and 0.0722, and the ratio taken as `(lighter + 0.05) / (darker + 0.05)`. There is nothing here
/// worth inventing, and using the standard's own formula is what makes the numbers comparable to
/// every other tool anybody would check them with.
///
/// Colours are plain `0xRRGGBB`, which is how `Palette` already states them, so this stays in the
/// core and needs no UI framework to answer. Alpha is deliberately absent: text drawn at reduced
/// opacity is a composite, and `composited(_:over:at:)` is how you ask about one, because a
/// ratio taken against an unblended colour is the mistake that made "white at 0.75 on the accent
/// fill" look like it passed.
public enum Contrast {
    /// The floor for text, which is WCAG AA at ordinary sizes.
    public static let textFloor = 4.5
    /// The floor for large text, at 24pt or 19pt bold and above.
    public static let largeTextFloor = 3.0
    /// The floor for a control's boundary, an icon, or anything else that carries meaning without
    /// being read. AA's non-text contrast rule.
    public static let nonTextFloor = 3.0

    /// WCAG relative luminance, 0 for black and 1 for white.
    public static func relativeLuminance(of colour: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((colour >> 16) & 0xFF)
            + 0.7152 * linear((colour >> 8) & 0xFF)
            + 0.0722 * linear(colour & 0xFF)
    }

    /// The ratio between two colours, from 1 (identical) to 21 (black on white).
    ///
    /// Order does not matter: the lighter of the two is always the numerator, which is what stops
    /// a pair being reported as passing simply because it was stated the other way round.
    public static func ratio(_ one: UInt32, _ other: UInt32) -> Double {
        let a = relativeLuminance(of: one)
        let b = relativeLuminance(of: other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// What a colour drawn at less than full opacity actually becomes over a known background.
    ///
    /// Source-over compositing, per channel, which is what the window is doing anyway. It is here
    /// because the interesting failures in this app are all of this shape: white at 0.75 on the
    /// accent fill, a word-level diff emphasis over a wash, a 20 percent rim. Measuring the
    /// unblended colour says those pass and looking at them says otherwise.
    public static func composited(_ colour: UInt32, over background: UInt32, at alpha: Double) -> UInt32 {
        let alpha = min(max(alpha, 0), 1)
        var result: UInt32 = 0
        for shift in [16, 8, 0] as [UInt32] {
            let front = Double((colour >> shift) & 0xFF)
            let back = Double((background >> shift) & 0xFF)
            let mixed = UInt32((front * alpha + back * (1 - alpha)).rounded())
            result |= min(mixed, 255) << shift
        }
        return result
    }
}
