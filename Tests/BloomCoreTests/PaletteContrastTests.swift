import Foundation
import Testing
@testable import BloomCore

/// Every colour in the window, against every ground it is drawn on.
///
/// **This suite is the point of `PaletteInk` and `Contrast`.** Before it there was no way to ask:
/// a `grep` for "contrast" across the tests returned one hit and it was about animation, there was
/// no luminance helper anywhere in the core, and every ratio in the app was a number written into
/// a doc comment once and never re-checked. Several were wrong. `Palette.textTertiary` measured
/// 2.77 to 1 on the sunken surface, against a floor of 4.5, and it is the ink for diff gutter
/// numbers, check-run durations and about sixty other things meant to be read.
///
/// The floors are WCAG AA: 4.5 for text, 3 for anything that carries meaning without being read.
/// Nothing here is aspirational. A pair that cannot clear its floor is retuned along its own hue
/// until it does, which is what happened to `textTertiary` and `synComment`.
@Suite("Palette contrast")
struct PaletteContrastTests {
    /// The two grounds text sits on, per appearance. `surfaceRaised` is the worst of them in dark
    /// and `surfaceSunken` the worst in light, which is why both are walked rather than assuming
    /// the window background is the hard case.
    private static let grounds: [(name: String, ink: PaletteInk.Pair)] = [
        ("surface", PaletteInk.surface),
        ("surfaceRaised", PaletteInk.surfaceRaised),
        ("surfaceSunken", PaletteInk.surfaceSunken),
    ]

    private static let appearances: [(name: String, isDark: Bool)] = [
        ("light", false), ("dark", true),
    ]

    // MARK: - The maths

    /// Checked against the standard's own anchors rather than against this app, so a mistake in
    /// the formula cannot be absorbed by retuning a colour until the test agrees with it.
    @Test("the ratio is WCAG's, at the two ends everybody knows")
    func theFormulaIsTheStandardOne() {
        #expect(Contrast.relativeLuminance(of: 0x000000) == 0)
        #expect(abs(Contrast.relativeLuminance(of: 0xFFFFFF) - 1) < 0.0001)
        #expect(abs(Contrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(Contrast.ratio(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        // Order cannot change the answer, which is what stops a pair passing because it was
        // stated the other way round.
        #expect(Contrast.ratio(0x8A9AA2, 0xFFFFFF) == Contrast.ratio(0xFFFFFF, 0x8A9AA2))
        #expect(Contrast.ratio(0x123456, 0x123456) == 1)
    }

    /// The failures that matter in this app are all composites, and measuring the unblended colour
    /// says they pass.
    @Test("a colour drawn at reduced opacity is measured as what it becomes")
    func compositingIsTheThingMeasured() {
        #expect(Contrast.composited(0xFFFFFF, over: 0x000000, at: 1) == 0xFFFFFF)
        #expect(Contrast.composited(0xFFFFFF, over: 0x000000, at: 0) == 0x000000)
        #expect(Contrast.composited(0xFFFFFF, over: 0x000000, at: 0.5) == 0x808080)
        // White at 0.75 on the accent fill: 21 to 1 if you ask about white, and this if you ask
        // about what is actually on screen.
        let onAccent = Contrast.composited(0xFFFFFF, over: PaletteInk.accentFill.light, at: 0.75)
        #expect(Contrast.ratio(onAccent, PaletteInk.accentFill.light) < Contrast.textFloor)
    }

    // MARK: - The table

    @Test("every ink that is read clears the text floor on every ground it is drawn on")
    func textClearsItsFloor() {
        let inks: [(String, PaletteInk.Pair)] = [
            ("textTertiary", PaletteInk.textTertiary),
            ("accent", PaletteInk.accent),
            ("negative", PaletteInk.negative),
            ("stop", PaletteInk.stop),
            ("warning", PaletteInk.warning),
            ("merged", PaletteInk.merged),
        ]

        for (inkName, ink) in inks {
            for (appearance, isDark) in Self.appearances {
                for (groundName, ground) in Self.grounds {
                    let ratio = Contrast.ratio(ink.member(dark: isDark), ground.member(dark: isDark))
                    #expect(
                        ratio >= Contrast.textFloor,
                        "\(inkName) on \(groundName), \(appearance): \(ratio.rounded(to: 2)) to 1"
                    )
                }
            }
        }
    }

    /// The syntax ramp, which is read at 12 point in a monospaced face and is therefore text by
    /// any reading. Eight of the nine always passed; `synComment` was never tuned and sat at 3.48.
    @Test("every syntax colour clears the text floor on the surface code is drawn on")
    func syntaxClearsItsFloor() {
        let ramp: [(String, PaletteInk.Pair)] = [
            ("synKeyword", PaletteInk.synKeyword),
            ("synType", PaletteInk.synType),
            ("synString", PaletteInk.synString),
            ("synNumber", PaletteInk.synNumber),
            ("synComment", PaletteInk.synComment),
            ("synFunction", PaletteInk.synFunction),
            ("synVariable", PaletteInk.synVariable),
            ("synAttribute", PaletteInk.synAttribute),
            ("synOperator", PaletteInk.synOperator),
        ]

        for (name, ink) in ramp {
            for (appearance, isDark) in Self.appearances {
                let ratio = Contrast.ratio(
                    ink.member(dark: isDark), PaletteInk.surface.member(dark: isDark)
                )
                #expect(
                    ratio >= Contrast.textFloor,
                    "\(name), \(appearance): \(ratio.rounded(to: 2)) to 1"
                )
            }
        }
    }

    /// A fill exists to carry light text, which is a different question from whether the same hue
    /// works as ink. `accentFill` and `mergedFill` are both one value in both appearances for
    /// exactly this reason, and the doc comments on them state ratios this now re-checks.
    @Test("white on a fill clears the text floor")
    func fillsCarryTheirLabel() {
        for (name, ink) in [("accentFill", PaletteInk.accentFill), ("mergedFill", PaletteInk.mergedFill)] {
            for (appearance, isDark) in Self.appearances {
                let ratio = Contrast.ratio(0xFFFFFF, ink.member(dark: isDark))
                #expect(
                    ratio >= Contrast.textFloor,
                    "white on \(name), \(appearance): \(ratio.rounded(to: 2)) to 1"
                )
            }
        }
    }

    /// A boundary is not read, so it holds the non-text floor rather than the text one. `border`
    /// is the case the window used to have none of: `separatorColor` composites to a 25 unit step
    /// on white, which the eye reads as nothing.
    @Test("a border separates the panes it divides")
    func bordersAreFindable() {
        for (appearance, isDark) in Self.appearances {
            for (groundName, ground) in Self.grounds {
                let ratio = Contrast.ratio(
                    PaletteInk.border.member(dark: isDark), ground.member(dark: isDark)
                )
                #expect(
                    ratio >= 1.2,
                    "border on \(groundName), \(appearance): \(ratio.rounded(to: 2)) to 1"
                )
            }
        }
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
