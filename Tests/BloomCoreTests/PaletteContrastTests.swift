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
            ("running", PaletteInk.running),
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

    /// The accent stopped being only Bloom's business the day `NSAccentColorName` went into the
    /// bundle, and this is the floor that came with it.
    ///
    /// Before that the accent reached only what Bloom drew, so a wrong one was a wrong chip. Now
    /// AppKit derives the ground under selected text from it, and that ground sits behind a
    /// paragraph somebody is reading while they drag over it: `selectedTextBackgroundColor` is a
    /// fill with a label on it, in the one state where the reader cannot move the label out of the
    /// way. `PaletteInk.accentTextSelection` is what the system derived from `accentFill`, measured
    /// in both appearances, and this asks the question that matters about it.
    ///
    /// The floor is the text one rather than the non-text one, deliberately. The whole point of a
    /// selection is that the words under it stay words.
    @Test("selected text is still readable on the ground the accent derives")
    func selectedTextClearsItsFloor() {
        for (appearance, isDark) in Self.appearances {
            let ratio = Contrast.ratio(
                PaletteInk.selectedTextInk.member(dark: isDark),
                PaletteInk.accentTextSelection.member(dark: isDark)
            )
            #expect(
                ratio >= Contrast.textFloor,
                "selected text on the accent's selection fill, \(appearance): \(ratio.rounded(to: 2)) to 1"
            )
        }
    }

    /// The other half of the same question, and the one a retune is likelier to break. A selection
    /// nobody can see is a selection that has to be guessed at, and the fill is a pale wash on the
    /// light ramp: `#BAD6DF` on white is a step of 1.4, which is under any text floor and is not
    /// meant to clear one, but it has to be findable.
    @Test("a selection can be seen against the page it is on")
    func aSelectionIsFindable() {
        for (appearance, isDark) in Self.appearances {
            for (groundName, ground) in Self.grounds {
                let ratio = Contrast.ratio(
                    PaletteInk.accentTextSelection.member(dark: isDark), ground.member(dark: isDark)
                )
                #expect(
                    ratio >= 1.2,
                    "the selection fill on \(groundName), \(appearance): \(ratio.rounded(to: 2)) to 1"
                )
            }
        }
    }

    /// The tab strip's own two colours, which is the one control in the window whose fill and ink
    /// were chosen together rather than inherited from a list row.
    ///
    /// `PanelTabs` replaced a segmented picker whose selected cell drew in the system accent, and
    /// the replacement had to answer a question the picker never asked: what ink goes on
    /// `Palette.selected`. The obvious answer is the one the resting cells already carry, and it
    /// is wrong. `textTertiary` measures 3.76 to 1 on that fill in light and 3.64 in dark, under
    /// the 4.5 floor, which is why a chosen cell lifts to `Palette.textPrimary` instead of only
    /// changing what is behind it. That failure is asserted rather than described, so retuning
    /// either pair until it stops being true is something this suite says out loud.
    @Test("a chosen cell is findable, and cannot keep a resting cell's ink")
    func thePanelTabsHoldTheirOwnFloors() {
        for (appearance, isDark) in Self.appearances {
            let fill = PaletteInk.selected.member(dark: isDark)
            let track = PaletteInk.surfaceSunken.member(dark: isDark)
            let onTrack = Contrast.ratio(fill, track)
            #expect(
                onTrack >= 1.2,
                "the chosen cell on its track, \(appearance): \(onTrack.rounded(to: 2)) to 1"
            )

            let resting = Contrast.ratio(PaletteInk.textTertiary.member(dark: isDark), track)
            #expect(
                resting >= Contrast.textFloor,
                "a resting cell's ink on its track, \(appearance): \(resting.rounded(to: 2)) to 1"
            )

            let borrowed = Contrast.ratio(PaletteInk.textTertiary.member(dark: isDark), fill)
            #expect(
                borrowed < Contrast.textFloor,
                "a resting cell's ink now clears the chosen fill in \(appearance) at \(borrowed.rounded(to: 2)) to 1, so the lift to the primary label can go"
            )
        }
    }

    /// Why the browser bar's address is not drawn in Bloom's own tertiary ink.
    ///
    /// The pane's toolbar puts its arrow capsule and its address pill in `Glass.regular`, and over
    /// a flat backdrop that material is the backdrop lifted toward white. The backdrop is
    /// `surfaceSunken`, so how far the ink can be trusted is a question about how far the lift
    /// goes, and in dark the answer is: not far at all. The exact lift is the system's and cannot
    /// be read from here, which is the point of asking it as a range.
    ///
    /// Retuning the pair is the obvious escape and it is closed: an ink that still clears the text
    /// floor on a quarter-lifted ground is so near `labelColor` that the emphasised host and the
    /// dim scheme stop being two tones. So the address goes to AppKit's semantic labels instead,
    /// which resolve against the glass's own appearance. See `BrowserToolbarView.addressLabel`.
    @Test("a translucent ground costs Bloom's tertiary ink its floor in dark")
    func aLiftedGroundCostsTheTertiaryInk() {
        let ground = PaletteInk.surfaceSunken.dark
        let ink = PaletteInk.textTertiary.dark

        // Resting, on the opaque bar it was tuned against, it is comfortable.
        #expect(Contrast.ratio(ink, ground) >= Contrast.textFloor)

        // A tenth of the way to white and it is under the floor for text.
        let tenth = Contrast.composited(0xFFFFFF, over: ground, at: 0.10)
        #expect(Contrast.ratio(ink, tenth) < Contrast.textFloor)

        // A fifth, and it is under the floor a glyph holds, never mind a word.
        let fifth = Contrast.composited(0xFFFFFF, over: ground, at: 0.20)
        #expect(Contrast.ratio(ink, fifth) < Contrast.nonTextFloor)

        // The escape, closed. `#BACCD4` is about the darkest ink that still clears the text floor
        // a quarter of the way to white, and against the host beside it there is nothing left.
        let quarter = Contrast.composited(0xFFFFFF, over: ground, at: 0.25)
        let dim: UInt32 = 0xBACCD4
        #expect(Contrast.ratio(dim, quarter) >= Contrast.textFloor)
        let host = Contrast.composited(0xFFFFFF, over: ground, at: 0.85)
        #expect(Contrast.ratio(dim, host) < 1.5)
        #expect(Contrast.ratio(ink, host) > 2)

        // Light is a different question and the answer there is the opposite: glass over a bar
        // already all but white barely moves it, so the tuned ink keeps its floor and there is
        // nothing here to fix. This is why `Palette.textTertiaryOnGlass` has two different halves.
        let lit = Contrast.composited(0xFFFFFF, over: PaletteInk.surfaceSunken.light, at: 0.25)
        #expect(Contrast.ratio(PaletteInk.textTertiary.light, lit) >= Contrast.textFloor)
    }

    /// What `Palette.textTertiaryOnGlass` resolves to, on both sides, and why it is not one colour.
    ///
    /// `secondaryLabelColor` is semantic and cannot be read from here, so it is stated as the
    /// alphas AppKit composites it at: black at 50 percent in light, white at 55 in dark. Those
    /// two numbers are the whole of it, and measuring the composite rather than the alpha is the
    /// point `compositingIsTheThingMeasured` makes further up.
    ///
    /// The pair is asserted in both directions. In dark the semantic ink is the one that holds,
    /// and in light it is the one that fails, which is the fact that stops the two halves being
    /// tidied into one.
    @Test("the ink on glass takes the better half in each appearance, and they are different halves")
    func theInkOnGlassDiffersBecauseTheGroundDoes() {
        let secondaryInLight = 0.50
        let secondaryInDark = 0.55

        // Light: the ground barely moves, Bloom's own ink clears the floor, and AppKit's does not.
        let lit = Contrast.composited(0xFFFFFF, over: PaletteInk.surfaceSunken.light, at: 0.25)
        let semanticInLight = Contrast.composited(0x000000, over: lit, at: secondaryInLight)
        #expect(Contrast.ratio(PaletteInk.textTertiary.light, lit) >= Contrast.textFloor)
        #expect(Contrast.ratio(semanticInLight, lit) < Contrast.textFloor)

        // Dark: the ground moves a long way, and the two swap places. A 15 percent lift is the
        // semantic ink's own edge rather than comfort, at 4.51, so this is the recorded limit of
        // the arrangement: a `surfaceSunken` retuned any lighter and the browser bar says so here.
        for lift in [0.10, 0.15] {
            let ground = Contrast.composited(0xFFFFFF, over: PaletteInk.surfaceSunken.dark, at: lift)
            let semantic = Contrast.composited(0xFFFFFF, over: ground, at: secondaryInDark)
            #expect(Contrast.ratio(PaletteInk.textTertiary.dark, ground) < Contrast.textFloor)
            #expect(
                Contrast.ratio(semantic, ground) >= Contrast.textFloor,
                "the semantic ink on a \(lift) lift: \(Contrast.ratio(semantic, ground).rounded(to: 2)) to 1"
            )
        }

        // And it is one weight to look at, not two: each half lands in the same band against the
        // ground it is drawn on, so switching appearance does not change how dim the run reads.
        let inLight = Contrast.ratio(PaletteInk.textTertiary.light, lit)
        let darkGround = Contrast.composited(0xFFFFFF, over: PaletteInk.surfaceSunken.dark, at: 0.15)
        let inDark = Contrast.ratio(
            Contrast.composited(0xFFFFFF, over: darkGround, at: secondaryInDark), darkGround
        )
        #expect(
            abs(inLight - inDark) < 0.75,
            "light reads at \(inLight.rounded(to: 2)) and dark at \(inDark.rounded(to: 2))"
        )
    }

    /// The report this suite exists to keep answered: two roles resolving to one number.
    ///
    /// `Palette.running` was `Palette.positive` was `Palette.accent`, three names for `#0C7A6E` and
    /// `#4FD8C4`, and the report was that a green busy indicator is easily confused with another
    /// green icon status. A doc comment saying "these must differ" is the kind of claim
    /// `PaletteInk`'s own header says was wrong several times over, so it is a number here.
    ///
    /// **Equality is the floor and it is not the test**, and the blue is why that distinction had
    /// to be paid for. The busy mark was orange first, which sat in an empty quadrant of the wheel
    /// and was 46.9 from `positive`; the house blue it became is a near neighbour of the teal it
    /// has to be told from, so a test that only asked "are these two numbers different" would have
    /// passed on `accentFill` itself, at 17.9 in light, which is closer than `positive` is to the
    /// tertiary ink and is the reported bug wearing another hue.
    ///
    /// So the bars are this app's own separations rather than numbers invented for the occasion,
    /// and there are two of them because the neighbours are of two kinds. `warning` and `negative`
    /// are the closest pair of meaning colours Bloom deliberately draws apart, at 27.9 in light and
    /// 28.8 in dark, and `positive` is what running was confused with, so that is the bar it is
    /// held to in full. `warning`, `negative` and `merged` are further round and are held to half
    /// of it, which is all an ink squeezed between two hues can promise. `negative` and `stop` are
    /// deliberately 7.0 apart and are not a counter-example: they are one meaning at two volumes.
    @Test("running is a hue of its own, and far enough from the four it is read beside")
    func runningIsNotAnyoneElse() {
        for (appearance, isDark) in Self.appearances {
            let running = PaletteInk.running.member(dark: isDark)
            let positive = PaletteInk.accent.member(dark: isDark)
            let warning = PaletteInk.warning.member(dark: isDark)
            let negative = PaletteInk.negative.member(dark: isDark)

            #expect(running != positive, "running is \(appearance)'s positive again")

            // The one the report was actually about, held to the full bar.
            let confusable = Contrast.deltaE(running, positive)
            let bar = Contrast.deltaE(warning, negative)
            #expect(
                confusable >= bar,
                "running against positive, \(appearance): \(confusable.rounded(to: 1)) against \(bar.rounded(to: 1))"
            )

            let others: [(String, UInt32)] = [
                ("warning", warning),
                ("negative", negative),
                ("merged", PaletteInk.merged.member(dark: isDark)),
            ]
            for (name, other) in others {
                let measured = Contrast.deltaE(running, other)
                #expect(
                    measured >= bar / 2,
                    "running against \(name), \(appearance): \(measured.rounded(to: 1)) against \(bar.rounded(to: 1) / 2)"
                )
            }
        }
    }

    /// The neighbour a blue busy mark has that an orange one did not: Bloom's own tertiary ink.
    ///
    /// `textTertiary` is `#69757B` and `#769AAA`, and the dark member is a blue-grey at hue 198,
    /// eight degrees off `accentFill`. The status column draws greys in it, so a running dot that
    /// drifted toward it would read as a workspace with nothing happening, which is the opposite of
    /// what it says. This is not a floor anybody chose either: `merged` and `textTertiary` already
    /// sit 14.2 and 14.9 apart in this window, so that is what running has to beat, and it is the
    /// pair that decides how light the dark member is allowed to be.
    @Test("the busy mark cannot be mistaken for a dim one")
    func runningIsNotTheQuietInk() {
        for (appearance, isDark) in Self.appearances {
            let running = PaletteInk.running.member(dark: isDark)
            let quiet = PaletteInk.textTertiary.member(dark: isDark)
            let bar = Contrast.deltaE(PaletteInk.merged.member(dark: isDark), quiet)
            let measured = Contrast.deltaE(running, quiet)
            #expect(
                measured >= bar,
                "running against textTertiary, \(appearance): \(measured.rounded(to: 1)) against \(bar.rounded(to: 1))"
            )
        }
    }

    /// Why the busy mark is not `accentFill`, which is the colour anybody asking for "the house
    /// blue" means, and which this palette cannot spend here.
    ///
    /// Written as a failing measurement rather than as a sentence, because "we tried the obvious
    /// thing and it did not work" is exactly the note that gets deleted by the next person who
    /// thinks they have a tidier idea. Two things are wrong with it and only one is about hue.
    ///
    /// In dark it is not an ink. `accentFill` is one value in both appearances by design, a fill
    /// with white text on it, and `#197593` on the raised surface a card is drawn on measures under
    /// the floor a mark holds without even being read. In light it is legible and still wrong: it
    /// is nearer `positive` than the app's own quiet ink is, which is the reported confusion with
    /// the green swapped for a blue.
    @Test("the house blue is a fill, and cannot be the busy mark itself")
    func theHouseBlueCannotDoThisJob() {
        let fill = PaletteInk.accentFill.dark
        let raised = PaletteInk.surfaceRaised.dark
        #expect(
            Contrast.ratio(fill, raised) < Contrast.nonTextFloor,
            "accentFill on the raised surface in dark: \(Contrast.ratio(fill, raised).rounded(to: 2)) to 1"
        )

        let toPositive = Contrast.deltaE(PaletteInk.accentFill.light, PaletteInk.accent.light)
        let quiet = Contrast.deltaE(PaletteInk.accent.light, PaletteInk.textTertiary.light)
        #expect(
            toPositive < quiet,
            "accentFill sits \(toPositive.rounded(to: 1)) from positive, the tertiary ink \(quiet.rounded(to: 1))"
        )

        // And the blue that was drawn instead is still recognisably it: nearer the house fill than
        // Bloom's own accent is, which is the whole of "the same family, moved off the teal".
        let running = PaletteInk.running.light
        #expect(
            Contrast.deltaE(running, PaletteInk.accentFill.light) < quiet,
            "running sits \(Contrast.deltaE(running, PaletteInk.accentFill.light).rounded(to: 1)) from the house fill"
        )
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

/// The states this app draws as a colour and nothing else, and what they say instead.
///
/// Every one of these was a hue on its own: the quota ramp had no word, no glyph and not one
/// accessibility modifier in the whole panel file, and a subagent that failed was a red cross with
/// no label beside a row that said only its name. A hue is the one channel somebody colour blind,
/// somebody on a bad projector and somebody using VoiceOver all miss at once.
@Suite("A state says itself in more than a colour")
struct SeverityVocabularyTests {
    @Test("calm is the only quota step with nothing to say")
    func calmIsSilent() {
        #expect(QuotaSeverity.calm.word == nil)
        #expect(QuotaSeverity.calm.symbol == nil)
        for severity in [QuotaSeverity.warning, .critical, .spent] {
            #expect(severity.word != nil, "\(severity) has no word")
            #expect(severity.symbol != nil, "\(severity) has no shape")
        }
    }

    /// Distinct shapes rather than one glyph in three colours, which is the rule the workspace
    /// status marks and the check runs already follow.
    @Test("no two quota steps share a word or a shape")
    func stepsAreToldApart() {
        let words = QuotaSeverity.allCases.compactMap(\.word)
        let symbols = QuotaSeverity.allCases.compactMap(\.symbol)
        #expect(Set(words).count == words.count)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("no two subagent outcomes share a word")
    func outcomesAreToldApart() {
        let marks: [SubagentRow.Mark] = [.working, .done, .failed, .stopped]
        let words = marks.map(\.word)
        #expect(Set(words).count == words.count)
        #expect(!words.contains(""))
    }

    /// The row is the lane for a sighted reader, and a lane reaches VoiceOver as nothing.
    @Test("a quota row says its severity out loud")
    func aRowSaysItsSeverity() {
        let line = QuotaLine(
            provider: .claudeCode,
            windowKey: "five-hour",
            title: "Claude Code, 5 hours",
            figure: "84%",
            fill: 0.84,
            severity: .warning,
            footnote: "Lifts in 40m"
        )
        #expect(line.spoken.contains("Claude Code, 5 hours"))
        #expect(line.spoken.contains("84%"))
        #expect(line.spoken.contains("Running low"))
        #expect(line.spoken.contains("Lifts in 40m"))
    }

    /// Calm says nothing, so a calm row is the title, the figure and the footnote and no verdict.
    @Test("a calm row does not invent a verdict")
    func aCalmRowIsQuiet() {
        let line = QuotaLine(
            provider: .codex,
            windowKey: "weekly",
            title: "Codex, weekly",
            figure: "12%",
            fill: 0.12,
            severity: .calm,
            footnote: ""
        )
        #expect(line.spoken == "Codex, weekly, 12%")
    }

    /// The sentence `QuotaBoard.headline`'s own comment promised and nothing ever wrote.
    @Test("an empty board still says something over the panel")
    func anEmptyBoardSpeaks() {
        let summary = QuotaBoard(providers: []).spokenSummary()
        #expect(summary.contains("Agent limits"))
        #expect(summary.contains("Nothing has reported"))
    }
}
