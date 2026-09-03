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
/// `deltaE` answers the other half, and it was bought by a report the ratio could not have caught:
/// the busy indicator and the passing tick were one value, so they measured 1.0 against each other
/// and 5.22 against the page, which is a pair of numbers saying nothing is wrong. What a glance
/// actually does with two marks is a question about hue and chroma as well as lightness, and
/// CIEDE2000 is the CIE's own answer to it. See `Palette.running`.
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

    /// The three channels of a colour, in the order they are written.
    ///
    /// `(colour >> 16) & 0xFF` and its two siblings were spelled out in both functions below. It is
    /// the same unpack each time, and it is the sort of line every reader has to check character by
    /// character.
    static func channels(of colour: UInt32) -> (r: UInt32, g: UInt32, b: UInt32) {
        ((colour >> 16) & 0xFF, (colour >> 8) & 0xFF, colour & 0xFF)
    }

    /// One channel taken off the sRGB transfer curve, which is what both questions below open with.
    ///
    /// **It was written twice, in `relativeLuminance` and in `lab`, with two different thresholds,
    /// and neither said why.** WCAG 2.x prints the knee at 0.03928 and the sRGB standard prints it
    /// at 0.04045, so each function carried the number its own standard states, which reads as a
    /// bug in one of them and is not one.
    ///
    /// The two agree on every colour this can ever be asked about. A channel here is always an
    /// integer 0 to 255, because a colour is `0xRRGGBB` and `composited` rounds before it returns,
    /// and both knees fall between 10/255 = 0.0392 and 11/255 = 0.0431, so all 256 values land on
    /// the same side of both. `ContrastTests` walks all 256 and asserts that rather than leaving it
    /// as arithmetic in a comment, so the day somebody moves this number the suite says which
    /// channel it moved.
    ///
    /// The sRGB number is the one kept, because that is the standard defining the curve; WCAG's is
    /// a rounding of it that predates the correction.
    private static func linear(_ channel: UInt32) -> Double {
        let value = Double(channel) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance, 0 for black and 1 for white.
    public static func relativeLuminance(of colour: UInt32) -> Double {
        let (r, g, b) = channels(of: colour)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
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

    // MARK: - How far apart two colours look

    /// A colour in CIELAB, which is where "how different do these look" is a question with an
    /// answer. D65, the white point sRGB is defined against.
    public static func lab(of colour: UInt32) -> (l: Double, a: Double, b: Double) {
        let channels = channels(of: colour)
        let r = linear(channels.r)
        let g = linear(channels.g)
        let b = linear(channels.b)

        let x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047
        let y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        let z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883

        func f(_ t: Double) -> Double {
            t > 216.0 / 24389 ? cbrt(t) : (841.0 / 108) * t + 4.0 / 29
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000, the CIE's own answer to how far apart two colours look.
    ///
    /// `ratio` cannot answer this and is not meant to: it is a question about lightness alone, so
    /// two colours a glance can never confuse can share a ratio, and two that are the same hue at
    /// the same weight measure 1.0 whether they are one colour or two. Bloom needs both questions
    /// asked, because its meaning colours are read as an index down one narrow column: each has to
    /// be legible on its ground, which is `ratio`, and each has to be tellable from the three next
    /// to it, which is this.
    ///
    /// The formula is the standard one, including the terms it is easy to leave out: the `G`
    /// stretch of the a axis that pulls near-neutrals apart, the mean-hue rule for the case where
    /// the two hues straddle 360, and the `Rt` rotation that stops blues being over-counted.
    /// Checked against Sharma, Wu and Dalal's published test pairs in `ContrastTests`, because a
    /// colour-difference formula written from memory is the kind of thing that is subtly wrong and
    /// still looks plausible.
    public static func deltaE(_ one: UInt32, _ other: UInt32) -> Double {
        deltaE(lab(of: one), lab(of: other))
    }

    /// The same, for two colours already in Lab. Public so the published test pairs, which are
    /// stated in Lab and have no sRGB form, can be put to exactly the code the app uses.
    public static func deltaE(
        _ one: (l: Double, a: Double, b: Double), _ other: (l: Double, a: Double, b: Double)
    ) -> Double {
        func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
        func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
        /// atan2 in 0..<360, and zero for a neutral, where the angle is undefined.
        func hue(_ a: Double, _ b: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let value = degrees(atan2(b, a))
            return value < 0 ? value + 360 : value
        }

        let chroma1 = (one.a * one.a + one.b * one.b).squareRoot()
        let chroma2 = (other.a * other.a + other.b * other.b).squareRoot()
        let meanChroma = (chroma1 + chroma2) / 2
        let seventh = pow(meanChroma, 7)
        let stretch = 0.5 * (1 - (seventh / (seventh + pow(25, 7))).squareRoot())

        let a1 = (1 + stretch) * one.a
        let a2 = (1 + stretch) * other.a
        let c1 = (a1 * a1 + one.b * one.b).squareRoot()
        let c2 = (a2 * a2 + other.b * other.b).squareRoot()
        let h1 = hue(a1, one.b)
        let h2 = hue(a2, other.b)

        let deltaL = other.l - one.l
        let deltaC = c2 - c1
        var deltah = 0.0
        if c1 * c2 != 0 {
            deltah = h2 - h1
            if deltah > 180 { deltah -= 360 } else if deltah < -180 { deltah += 360 }
        }
        let deltaH = 2 * (c1 * c2).squareRoot() * sin(radians(deltah) / 2)

        let meanL = (one.l + other.l) / 2
        let meanC = (c1 + c2) / 2
        var meanH = h1 + h2
        if c1 * c2 != 0 {
            let sum = h1 + h2
            if abs(h1 - h2) <= 180 {
                meanH = sum / 2
            } else {
                meanH = sum < 360 ? (sum + 360) / 2 : (sum - 360) / 2
            }
        }

        let t = 1
            - 0.17 * cos(radians(meanH - 30))
            + 0.24 * cos(radians(2 * meanH))
            + 0.32 * cos(radians(3 * meanH + 6))
            - 0.20 * cos(radians(4 * meanH - 63))
        let meanSeventh = pow(meanC, 7)
        let rotationChroma = 2 * (meanSeventh / (meanSeventh + pow(25, 7))).squareRoot()
        let rotation = -sin(radians(2 * (30 * exp(-pow((meanH - 275) / 25, 2))))) * rotationChroma

        let weightL = 1 + (0.015 * pow(meanL - 50, 2)) / (20 + pow(meanL - 50, 2)).squareRoot()
        let weightC = 1 + 0.045 * meanC
        let weightH = 1 + 0.015 * meanC * t

        let lightness = deltaL / weightL
        let chroma = deltaC / weightC
        let hueTerm = deltaH / weightH
        return (
            lightness * lightness + chroma * chroma + hueTerm * hueTerm
                + rotation * chroma * hueTerm
        ).squareRoot()
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
