import SwiftUI
import AppKit
import BloomCore

/// Bloom's colours.
///
/// Two kinds of colour live here, and the split is the whole design.
///
/// **Ink stays semantic.** Text, the focus ring, the caret and the text selection resolve to an
/// AppKit semantic colour, because those already track Increase Contrast, Differentiate Without
/// Colour and the keyboard access setting. Hard-coding them is what made the first version of
/// this app look like a web page pretending to be a Mac.
///
/// **The accent and the meaning colours no longer do.** They were semantic once, and the reason
/// they stopped is written out on `accent` and on `negative`: an app whose accent is whatever the
/// user last picked in System Settings cannot be part of a brand built on one ramp, and the
/// system reds are tuned to be the one saturated thing on a screen rather than one of a dozen
/// small marks in a narrow column. Read those two before adding a third exception.
///
/// **Ground is Bloom's own.** The five surfaces and the rule between them are named colours, not
/// `windowBackgroundColor` and friends. On macOS 26 every one of those semantic grounds resolves
/// to the same value: window, text and control backgrounds are all pure white in light and all
/// `#1E1E1E` in dark. An app built on them has exactly one surface wearing five names, so nothing
/// separates from anything and the only thing left to divide a pane from its neighbour is a
/// separator at ten percent ink, which on white is very nearly nothing at all. That is the
/// "everything is white and it feels heavy" complaint, stated in numbers.
///
/// The ramp below is a small, deliberate set instead: a body, a panel one step off it, a sidebar
/// one step the other way, and a raised control. In light they carry a slight cool cast so the
/// greys read as one family rather than as camera noise. In dark they are a deep blue rather than
/// a neutral charcoal, which is the appearance this app was designed in and the reason its dark
/// mode does not read as an unlit light mode.
///
/// Every value is a step of a single ramp, so the relationships hold: body to panel is small,
/// body to sidebar is small, and the rule carries the actual separation. Adding a sixth surface
/// is how this gets heavy again, so do not.
enum Palette {
    // MARK: Surfaces
    //
    // Four values and one rule. Measured light: FFFFFF / F7FAFA / F1F5F6 / FFFFFF, rule D6E0E4.
    // Measured dark: 0A1A25 / 0C1E2A / 0E202D / 16303F, rule 1E3F53.

    /// The ground the centre column stands on: the transcript, Home, Search, Settings.
    ///
    /// Identical to `surface` on purpose. They are two names for the reading ground because the
    /// call sites mean different things by them, not because the colour differs; if they ever
    /// diverge the window has grown a surface it does not need.
    static let windowBackground = dynamic(light: 0xFFFFFF, dark: 0x0A1A25)

    /// The chrome: the sidebar column, the title bar, and every strip of small controls.
    ///
    /// One value for all of them, which is what macOS itself does. A unified toolbar and a sidebar
    /// are the same material on a real Mac window, and giving each strip a step of its own is how
    /// a window ends up with seven grounds and no shape.
    ///
    /// A named colour rather than a translucent material. A material samples the desktop, so the
    /// sidebar's colour is whatever wallpaper is behind the window: measured on this machine it
    /// came out `#232833` in dark, a blue nobody chose, and it moves when the wallpaper does. A
    /// themed ramp cannot survive that.
    static let sidebar = Color(nsColor: sidebarNSColor)

    /// The same colour as an `NSColor`, because the window's own background is set in AppKit and
    /// has to keep tracking the appearance after it is set. See `WindowChrome`.
    static let sidebarNSColor = dynamicNSColor(light: 0xF1F5F6, dark: 0x0E202D)

    /// Content areas: the transcript, the inspector, anything holding text.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x0A1A25)

    /// A raised control: a segmented control's selected cell, a bordered button, a browser chip.
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x16303F)

    /// A recessed strip: gutters, hunk headers, tool detail blocks, the composer box, the panel.
    ///
    /// The step off `surface` is deliberately small, five units at most. It reads as recessed
    /// because it has a rule under it, not because it is a different colour, which is what keeps
    /// a window holding a dozen of these from looking like a stack of cards.
    static let surfaceSunken = dynamic(light: 0xF7FAFA, dark: 0x0C1E2A)

    // MARK: Overlays
    //
    // `hover` is a tint painted over whatever is underneath, so it is an alpha on white or black
    // rather than a colour of its own. The two selection fills below are not: they are opaque
    // steps of Bloom's ramp, for the reasons written on each. Never write any of the three as
    // 0xRRGGBBAA, which was the original bug behind the solid black selection bar: 0x00000014 is
    // the number 20, indistinguishable from an opaque dark blue, so the alpha was never applied.

    /// Measured off the mockup: four percent ink in light, five and a half in dark. It was six in
    /// both, and six percent black on white is a visibly grey slab under the pointer where the
    /// same figure in dark is barely a lift.
    static let hover = Color(nsColor: hoverNSColor)

    /// The same wash as an `NSColor`, for the transcript's text views. One definition, read two
    /// ways, so a span of inline code sits on the same ground whichever renderer drew it.
    static let hoverNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.055)
            : NSColor(white: 0, alpha: 0.04)
    }

    /// A selected row in a list that is not the key window's focus.
    ///
    /// Named rather than `unemphasizedSelectedContentBackgroundColor`, which is a neutral grey:
    /// `#DCDCDC` on the light ramp and `#464646` on the dark one. On the deep blue ground that
    /// grey is the one thing in the window with no blue in it at all, so a resting selection read
    /// as a smudge. These are the same two steps, taken along Bloom's ramp instead.
    static let selected = dynamic(light: 0xDCE7EA, dark: 0x1D4054)
    /// Selection in a focused list inside the key window, where macOS uses the accent colour.
    ///
    /// Bloom's accent rather than the system's, for the reason spelled out on `accent`. This is the
    /// most visible of the surfaces that now ignore System Settings: the selected sidebar row and
    /// the selected changed file are brand blue on a Mac set to Graphite.
    static let selectedEmphasized = accentFill
    static let selectedEmphasizedText = Color(nsColor: .alternateSelectedControlTextColor)

    // MARK: Lines

    /// The rule between two panes, and under every strip.
    ///
    /// `separatorColor` is ten percent ink, which composites to `#E6E6E6` on white: a 25 unit step
    /// that the eye reads as nothing, drawn at half a point. That is why the window used to have
    /// no edges. This is a 40 unit step in light and a 30 unit step in dark, and `Metrics.hairline`
    /// draws it at a full point, which is what AppKit's own split view divider has always been.
    static let border = dynamic(light: 0xD6E0E4, dark: 0x1E3F53)

    // MARK: Text

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    /// Named rather than `tertiaryLabelColor`.
    ///
    /// The system's third rung is 26 percent ink, which is `#BDBDBD` on white: a contrast ratio of
    /// 1.9 to 1, below anything readable, and it is used sixty times in this app for content that
    /// is meant to be read rather than ignored. The system means it for a disabled control. This
    /// is the rung the interface actually wanted, measured off the mockup and sitting between the
    /// system's second and third.
    static let textTertiary = dynamic(light: 0x8A9AA2, dark: 0x62808E)

    static let textInverted = Color(nsColor: .alternateSelectedControlTextColor)

    /// What a field says before anything is typed into it. Half ink, where the tertiary label is
    /// a quarter, which is why a placeholder written as `textTertiary` reads as disabled.
    static let textPlaceholder = Color(nsColor: .placeholderTextColor)

    // MARK: Text editing
    //
    // The three colours AppKit uses inside a text view. Each of them tracks something the accent
    // colour alone does not: the focus ring follows the Full Keyboard Access setting, the caret
    // follows the text colour on high contrast, and the selection is the paler fill a text run
    // gets rather than the solid one a list row gets.

    /// The focus ring around the control that has keyboard focus.
    static let focusRing = Color(nsColor: .keyboardFocusIndicatorColor)
    /// The caret.
    static let caret = Color(nsColor: .textInsertionPointColor)
    /// Selected text inside an editable or selectable text view.
    static let textSelection = Color(nsColor: .selectedTextBackgroundColor)

    // MARK: Meaning

    /// Bloom's accent, and deliberately not the user's.
    ///
    /// This is the one place the app overrides a system preference on purpose. `controlAccentColor`
    /// follows System Settings, so on a machine set to Graphite every tinted glyph, chip and
    /// selected segment in Bloom came out grey, and on one set to Pink they came out pink. Bloom
    /// has a mark and a site built on one ramp, and an app whose accent is whatever the user last
    /// picked cannot be part of it. See `PALETTE.md` in the brand folder.
    ///
    /// A pair, not a colour, because the ramp is explicit that its bottom half is for dark grounds
    /// and its top half for light. Bloom `#4FD8C4` measures 10.6 to 1 on the dark surface and 1.7
    /// to 1 on the light one, so it can never be text on light; the ramp's answer for that is Bloom
    /// Ink `#0C7A6E`, which measures 5.1. Both are the same hue, so a glyph that is teal in dark is
    /// recognisably the same glyph in light.
    ///
    /// This is for ink and for strokes. A filled control that has to carry white text uses
    /// `accentFill`, which is a different member of the ramp for exactly that reason.
    static let accent = dynamic(light: 0x0C7A6E, dark: 0x4FD8C4)

    /// The accent as a fill with light text on it: a selected row, a prominent button.
    ///
    /// Spatie Blue, the ramp's anchor and the only colour in it that works on both grounds. White
    /// on it measures 5.2 to 1, which is where macOS's own selection fill sits (4.9 to 1), so a
    /// selected row reads exactly as firmly as it did. Bloom itself cannot do this job: white on
    /// `#4FD8C4` is 1.6 to 1, an unreadable row.
    static let accentFill = dynamic(light: 0x197593, dark: 0x197593)

    /// An address in running text: underlined, and this colour.
    ///
    /// The accent, deliberately and not a blue of its own. A link is the app pointing at
    /// somewhere else, which is the same thing every tinted glyph in the window is doing, and a
    /// system blue here would be the one colour in Bloom that came from somewhere else. It is
    /// named rather than spelled `accent` at the call site so that the day a link needs to stop
    /// looking like a chip's tick, there is one line to change. Measured 5.2 to 1 on the light
    /// page and 10.1 to 1 on the dark one, both AA for body text.
    ///
    /// The underline is not decoration and is not optional: it is what makes the link findable
    /// without colour vision, and `linkInverted` below leans on it almost entirely.
    static let link = accent

    /// The same ink as an `NSFont`-side colour, for the transcript's text views. Built from the
    /// same pair rather than converted from `link`, so the two can never drift apart and the
    /// dynamic pair survives: an `NSTextView` resolves it against the window it is in.
    static let linkNSColor = dynamicNSColor(light: 0x0C7A6E, dark: 0x4FD8C4)

    /// An address inside a filled bubble, which in practice means the user's own turn.
    ///
    /// `accent` cannot do this job. Bloom `#4FD8C4` on Spatie Blue measures 3.0 to 1, under AA for
    /// body text, and the bubble sets `colorScheme` to dark so that is the value it would resolve
    /// to. This is the same hue taken up the ramp until it clears the fill: `#CCF9F2` measures
    /// 4.6 to 1 on `#197593`, against 5.2 for the white text around it.
    ///
    /// That closeness to white is the honest cost of a fill this saturated. There is no colour
    /// that both clears AA on Spatie Blue and reads as obviously not-white beside it, so the
    /// underline carries the affordance here and the tint only confirms it. One value rather than
    /// a pair, because `accentFill` is one value in both appearances and this sits on that fill,
    /// not on the page.
    static let linkInverted = Color(nsColor: NSColor(rgb: 0xCCF9F2))
    /// Healthy, done, passed. The accent, not a green of its own.
    ///
    /// The ramp says so in as many words, and the reference render of this window agrees: its
    /// "checks passed" tick and its `+214` are both the same value as its accent, in both
    /// appearances. Sampled from it: `#0C7A6E` light, `#4FD8C4` dark, which is exactly `accent`.
    ///
    /// Merged used to be on this list and is not any more: it has `merged` below, because a merge
    /// is the one outcome that is neither good news nor bad and the app now says so in a colour
    /// rather than in a shape alone.
    ///
    /// This means passing checks and an unread turn still differ in shape rather than in colour.
    /// That is fine and deliberate: `WorkspaceStatusGlyph` already draws every state as a
    /// different shape, so the column can be read by someone who cannot tell the red one from the
    /// green one, and the reference collapses the same two the same way.
    static let positive = accent

    /// The wash and the rule of the agent's question card while it is holding the turn open.
    ///
    /// A named pair rather than an opacity at each call site, because the card paints the same
    /// tint twice, as its fill and as its border, and two literals in one view is how the two
    /// drift apart. The wash is deliberately faint: the card sits in the transcript for as long
    /// as the person thinks, so it has to mark itself out without shouting over the prose it
    /// interrupted.
    static let questionWash = accent.opacity(0.06)
    static let questionBorder = accent.opacity(0.4)
    /// The same card once the question is settled: barely off the page, behind the plain border,
    /// so a finished question reads as part of the record rather than as something still waiting.
    static let questionWashSettled = accent.opacity(0.03)

    /// Something went wrong: a failed check, an error row, a deletion count.
    ///
    /// Not `systemRed`. The system reds are tuned to be the one saturated thing on their screen,
    /// and this app puts a dozen small meaning marks in one narrow column: at that volume they
    /// read as a warning light panel rather than as an index. Measured off the reference render,
    /// which is a step darker on the light ground and a step paler and less saturated on the dark
    /// one. `#B23A2E` measures 6.0 to 1 on white, `#E4695E` 5.2 to 1 on the dark sidebar.
    static let negative = dynamic(light: 0xB23A2E, dark: 0xE4695E)

    /// The stop control, which is a quieter red than a failure is.
    ///
    /// `negative` is right for something that went wrong. The stop button is not a failure: it sits
    /// in the composer for the whole length of a turn, and at full saturation it reads as an alarm
    /// about work that is going perfectly well. This keeps the meaning and drops the volume.
    ///
    /// Two hex values rather than a blend of `negative`, so retuning that does not carry across to
    /// this: the pair has to be moved with it by hand.
    static let stop = dynamic(light: 0x994842, dark: 0xCC7B76)

    /// Something needs attention but nothing is broken: setup that failed and can be run again,
    /// checks still going, a rate limit. Quieter than `systemOrange`, for the reason written on
    /// `negative`.
    ///
    /// The light member is amber rather than brown, and that took a hue rather than a step up the
    /// ramp. It was `#9A6410`, hue 37 at 81 percent saturation, and at that lightness an orange
    /// reads as brown: the strip's wash came out `#EDE3D4`, a tan, with a tan headline and a tan
    /// badge sitting in it, and "Checks running" looked like a stain rather than a state. Simply
    /// lifting it does not fix that and cannot be afforded either, because the same value carries
    /// white text on the strip's filled button and every step up the ramp is spent there: white on
    /// `#9A6410` measures 5.0 to 1 and the AA floor for a 13 point label is 4.5, so there is about
    /// one step of headroom in the whole colour.
    ///
    /// `#9C6C00` spends it on the hue instead. Hue 42 at full saturation, which is where amber
    /// stops being brown, and it lands slightly brighter as well. Sampled off the rendered strip:
    /// the wash is `#EDE4D1`, white on the fill measures 4.61 to 1, still AA for a label, and the
    /// headline measures 3.65 to 1 on its own wash against 3.93 before, which is AA for the 15
    /// point bold that headline is set in.
    ///
    /// The dark member is unchanged and is the reference the light one was aimed at: `#E8A33D` is
    /// what this state is supposed to feel like, and light is the appearance that was failing to.
    static let warning = dynamic(light: 0x9C6C00, dark: 0xE8A33D)
    /// An agent mid turn. The ramp is explicit that this is the accent rather than a green of its
    /// own: "Running, healthy, done. Reuse the accent, do not invent a green."
    static let running = accent

    /// A merge: one that has landed, and the button that lands one.
    ///
    /// The one meaning in the app that is neither good news nor bad and needed a colour of its
    /// own. Merging is the end of the workflow and the outcome everything else is aimed at, and
    /// the only two colours a system confirmation dialog can draw its confirm button in are red
    /// and grey. Red is what this app spends on losing work, so a red Merge button says the
    /// opposite of what merging means, and that is the whole reason `ConfirmationSheet` exists.
    ///
    /// Purple rather than a second green, because purple for a merge is not this app's idea:
    /// GitHub has drawn merged in it for a decade and Conductor draws it in `purple-500` on light
    /// and `purple-400` on dark. Those two were the reference and neither is the value here.
    /// Tailwind's purples are magenta-leaning and land badly beside a teal and blue ramp;
    /// GitHub's own pair is violet, a short step round the wheel from `accentFill` `#197593`, so
    /// it reads as a sibling of the accent rather than as a colour from another app.
    ///
    /// A pair, for the reason `accent` is a pair: `#8250DF` measures 5.0 to 1 on the light
    /// surface and `#A371F7` measures 5.3 to 1 on the dark one, and neither of them works on the
    /// other's ground.
    ///
    /// This is for ink, strokes and a wash of itself: the merge confirmation's button label, the
    /// strip's headline and badge on a landed pull request, the sidebar's merge mark, and the
    /// eight percent band behind all of it. A filled control that has to carry white text uses
    /// `mergedFill`, for the reason written there.
    ///
    /// It is now the colour of merged as well as the colour of merging. `PullRequestStatus.Tone`
    /// has a `merged` case, `PullRequestTint` resolves it here, and `WorkspaceStatusGlyph` draws
    /// the merge mark in it, so one landed pull request is one colour in every pane that reports
    /// it. Nothing else moved: passing checks, an open pull request and a closed one keep the
    /// tones they had.
    static let merged = dynamic(light: 0x8250DF, dark: 0xA371F7)

    /// A merge as a fill with light text on it: the Archive button on a landed pull request.
    ///
    /// One value in both appearances, exactly as `accentFill` is, and it is the LIGHT member of
    /// the pair above rather than a third colour. That is forced by the arithmetic: white on
    /// `#8250DF` measures 5.05 to 1, and white on `#A371F7` only 3.35, which is under the AA floor
    /// for the 13 point label a `.regular` button draws. A pair that is right for ink is wrong for
    /// a fill, and this is the same trap `accent` and `accentFill` document.
    ///
    /// It also has to separate from the band it stands in, which is the pair above at eight
    /// percent over the surface. Measured: 4.5 to 1 against the light band `#F5F1FC` and 3.2 to 1
    /// against the dark one `#162136`, both clear of the 3 to 1 a control has to hold to be
    /// findable at all.
    static let mergedFill = dynamic(light: 0x8250DF, dark: 0x8250DF)

    // MARK: Diffs
    //
    // Stated as an alpha over whatever the line is drawn on, rather than as an opaque hex per
    // appearance. That is the difference between a wash and a slab: a wash follows the surface,
    // so moving the dark ground from charcoal to deep blue leaves these correct, where the eight
    // opaque values they replaced each had to be retuned by hand or they drifted off the ground
    // and read as coloured tape stuck over the code.
    //
    // Thirteen and fourteen percent, because a deletion has to look as strong as an addition and
    // red carries further than green at the same alpha. The emphasis pair is roughly double, for
    // the run of characters inside a changed line.

    /// Added lines, and only added lines. The window's one green is `positive`, which is the
    /// accent, and a wash is the one place it cannot be used. At thirteen percent over the deep
    /// blue ground the ground wins: the result measures `#13333A`, whose dominant channel is
    /// blue, and on the light ground it comes out at three percent saturation, a neutral grey
    /// sitting next to a clearly pink deletion. A wash with no chroma cannot carry a meaning.
    ///
    /// Teal against red does separate better than green against red under deuteranopia, which is
    /// a real argument and was weighed. It loses to two things: green for an added line is close
    /// to universal across git tooling, and this is the diff the owner looked at and approved.
    static let diffPositive = dynamic(light: 0x28CD41, dark: 0x30D158)

    static let diffAddBackground = diffPositive.opacity(0.13)
    static let diffAddEmphasis = diffPositive.opacity(0.28)
    static let diffDeleteBackground = negative.opacity(0.14)
    static let diffDeleteEmphasis = negative.opacity(0.30)
    /// The line number column, which is the sunken step and nothing else.
    static let diffGutter = surfaceSunken

    /// A line under review, and the band holding its comment. The one amber wash in the window,
    /// on `warning`'s hue, because the diff's own washes have already spent green and red: a
    /// comment is neither an addition nor a problem, and either of those colours would claim it
    /// is. Two steps of the same wash rather than two hues, so a commented line and its band read
    /// as one annotation instead of a line with a strip stuck under it. Both are translucent for
    /// the reason the diff washes are: the ground shows through, so neither needs a dark twin.
    static let reviewLine = warning.opacity(0.14)
    static let reviewBand = warning.opacity(0.07)

    // MARK: Syntax

    static let synKeyword = dynamic(light: 0x9B2393, dark: 0xD08EE0)
    static let synType = dynamic(light: 0x0B7285, dark: 0x5BC8DB)
    static let synString = dynamic(light: 0xC0392B, dark: 0xE8846E)
    static let synNumber = dynamic(light: 0x1C6FBB, dark: 0x7FB3F0)
    static let synComment = dynamic(light: 0x7F8C8D, dark: 0x76767E)
    static let synFunction = dynamic(light: 0x2F5FD0, dark: 0x89AFF5)
    static let synVariable = dynamic(light: 0x6A3FB5, dark: 0xB49BF0)
    static let synAttribute = dynamic(light: 0x8A6A00, dark: 0xD9B65C)
    static let synOperator = dynamic(light: 0x5A5A60, dark: 0xA8A8B0)
    static let synConstant = dynamic(light: 0x1C6FBB, dark: 0x7FB3F0)

    /// A colour that differs between appearances, for the few cases where no semantic colour
    /// means the right thing. Both arguments are plain 0xRRGGBB.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    /// The same thing as an `NSColor`, for the handful of places that talk to AppKit directly.
    static func dynamicNSColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
    }
}

extension NSColor {
    /// Plain 0xRRGGBB. There is deliberately no packed-alpha form: alpha belongs in
    /// `Color.opacity`, where it cannot be mistaken for part of the colour.
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// Repo accent colours are stored as plain hex strings in SQLite.
    ///
    /// Read by `HexColor`, in the core and unit tested, rather than by a second rule here: this
    /// used to hand the string to `UInt32(_:radix:)`, which reads `abc` as the number `0x000ABC`
    /// and paints a project near black where every other tool reads `#AABBCC`.
    init(hexString: String) {
        guard let parsed = HexColor(hex: hexString) else {
            self.init(nsColor: NSColor(rgb: 0x4C8DF6))
            return
        }
        self.init(nsColor: NSColor(
            srgbRed: CGFloat(parsed.red) / 255,
            green: CGFloat(parsed.green) / 255,
            blue: CGFloat(parsed.blue) / 255,
            alpha: 1
        ))
    }

    /// The way back, for a colour the user picked in a colour well.
    ///
    /// Lives here rather than in whichever feature view happens to need it, because the two
    /// directions have to agree about the colour space and about upper case, and they can only be
    /// held to that if they can be read together. Two feature views had a copy each.
    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return [color.redComponent, color.greenComponent, color.blueComponent]
            .map { component in
                let byte = String(Int((component * 255).rounded()), radix: 16, uppercase: true)
                return byte.count == 1 ? "0" + byte : byte
            }
            .joined()
    }
}

/// Type scale, built on the system text styles so it follows the user's text size rather than
/// pinning everything to a point size we happened to like.
///
/// The rungs are `ScaledFont` rather than `Font` so that a subtree can be set larger without every
/// call site being rewritten; see that type for why macOS forces the question. Outside a
/// conversation the scale is one and each rung resolves to the same `Font` it always was.
///
/// Five rungs, and every name lands on one of them: 15 / 13 / 12 / 11 / 10, where 15 only ever
/// appears inside prose. There used to be three, because on macOS `.caption`, `.caption2` and
/// `.footnote` all resolve to 10 points: `caption` and `micro` were one size wearing two names,
/// `codeSmall` and `codeTiny` likewise, `title` was a hand-rolled `.headline`, and 11, the one
/// step the app actually wanted, was never used at all. `.subheadline` is that step, and it is
/// where everything that sat at 10 for want of anywhere else has moved to.
enum Typo {
    /// 15. The only rung above reading size, for the two places something has to read as a heading
    /// rather than as a bold sentence: a heading inside agent prose, and the state of the pull
    /// request at the top of the inspector.
    ///
    /// The second one is here rather than local to the inspector because it is the same judgement,
    /// not a second one. A heading set at body size with a weight on it is a bold sentence, and
    /// the inspector's state line was a rung BELOW the file names it heads, which is worse again.
    /// Anything that has to sit above reading size belongs on this rung; a sixth rung invented for
    /// one strip is how a five rung scale stops being one.
    static let heading = ScaledFont(.title3, weight: .bold)
    /// 13 bold. `.headline` is the system's own heading style at reading size, so saying so lets
    /// macOS treat it as a heading rather than as body with a weight bolted on.
    static let title = ScaledFont(.headline)
    /// 13. Reading size: prose, and anything the user is meant to read rather than scan.
    static let body = ScaledFont(.body)
    static let bodyEmphasis = ScaledFont(.body, weight: .medium)
    /// 12. The workhorse: row labels, controls, anything scanned rather than read.
    static let label = ScaledFont(.callout)
    static let labelEmphasis = ScaledFont(.callout, weight: .medium)
    /// 11. Supporting text that still has to be legible: a hint under a field, a link out of a
    /// block, the name on a chip.
    static let caption = ScaledFont(.subheadline)
    static let captionEmphasis = ScaledFont(.subheadline, weight: .medium)
    /// 10, the floor, and the reason it is medium rather than regular. Only for something that is
    /// read off the thing beside it: a count, a duration, a unit.
    static let micro = ScaledFont(.footnote, weight: .medium)

    /// The letterspacing an uppercased `micro` label is set with: the question card's header
    /// chip. Capitals at ten points set nearly solid, and the scale carries no uppercase rung of
    /// its own, so the air has to be given by hand. Named so the next uppercased label cannot
    /// pick a second value.
    static let microTracking: CGFloat = 0.6

    /// The same rungs in monospace, for anything whose columns have to line up: code, a path, a
    /// diff stat. They step with their proportional twins so a filename set beside a label does
    /// not read as a size apart from it.
    static let code = ScaledFont(.callout, design: .monospaced)
    static let codeSmall = ScaledFont(.subheadline, design: .monospaced)
    static let codeTiny = ScaledFont(.footnote, design: .monospaced)
}

enum Metrics {
    static let sidebarWidth: CGFloat = 260
    static let inspectorWidth: CGFloat = 380
    /// Matches the row height AppKit uses for a source list.
    static let rowHeight: CGFloat = 28
    /// Corner radii. Radii only: a gap between two views comes from the spacing scale below, even
    /// where the number happens to match.
    static let corner: CGFloat = 6
    static let cornerSmall: CGFloat = 4

    static let gutter: CGFloat = 12

    /// The box a small button at the trailing edge of a header is drawn and hit in: the project's
    /// `+`, the button that adds a project, the project settings window's own header control.
    ///
    /// Fifteen points tall, not the twenty four an icon in a sixteen point frame with four points
    /// of padding comes to. A sidebar section header is drawn in a band of nineteen points, and it
    /// clips: a list row holds its 32 point pitch until the header's content passes nineteen and
    /// then sizes to the content, so a twenty four point button put five points of extra air above
    /// every project header, which read as a gap in the column rather than as the top of the next
    /// project.
    ///
    /// The last four of those nineteen points are what this number spends. The button is drawn and
    /// hit in the same box, and that box is also its hover plate, so an eighteen point plate filled
    /// the band to within half a point of the bottom of the row. The list's selection fill takes
    /// the WHOLE of the row under it, top edge included, so a hovered header above a selected
    /// workspace put a grey plate and a grey pill half a point apart and the two read as one smear.
    /// Fifteen leaves two points of ground above and below the plate, which is the tight rung of
    /// the spacing scale and enough to see daylight at both edges. Measured off a window capture:
    /// plate 24 by 15 at two points clear, selection fill the full 32 point row beneath it.
    ///
    /// Three points smaller is three points of click target gone, out of a row that is only
    /// nineteen tall to begin with. Wider than it is tall, which is the shape of every small button
    /// in a Mac toolbar, and still enough to hit without hunting.
    ///
    /// Here rather than in `SidebarMetrics`, where it started, because the project settings window
    /// reads it and that window is not the sidebar: a constant named after one pane and used from
    /// another is how the two drift.
    static let headerButton = CGSize(width: 24, height: 15)
    /// One point, which on Retina is two physical pixels.
    ///
    /// It was one physical pixel, which is an iOS and web idea rather than a Mac one: AppKit's own
    /// split view divider, the rule under a table header and the line under a toolbar are all a
    /// full point. At half a point, drawn in a separator colour that is already only a 25 unit
    /// step, the rules in this window were not so much subtle as absent, and every pane floated.
    /// The name stays because a one point rule is still what everyone calls a hairline.
    static let hairline: CGFloat = 1

    // MARK: Spacing
    //
    // One scale for the whole window. These used to be literals at every call site, so the
    // sidebar and the inspector drifted a point or two apart on every row they both draw, and
    // where there was no literal a corner radius was borrowed instead, which tied a gap to a
    // rounding for no reason other than the two numbers happening to match.

    /// Between two things that read as one thing, such as a glyph and its count.
    /// Two lines that are one thing: a title and the line under it, set closer than a gap.
    ///
    /// One point rather than none, because none lets the two baselines collide at large text
    /// sizes. It is a hairline of air rather than a spacing choice, which is why it has a name of
    /// its own instead of being `spacingTight` used loosely.
    static let spacingHair: CGFloat = 1

    static let spacingTight: CGFloat = 2
    /// Between a label and the number beside it.
    static let spacingSmall: CGFloat = 4
    /// Between controls in a row.
    static let spacing: CGFloat = 6
    /// Between the groups a row falls into.
    static let spacingWide: CGFloat = 8
    /// What a row keeps from the edge of its pane.
    static let inset: CGFloat = 10
    /// What a full-width pane of content keeps from the window edge. Larger than `inset`, which
    /// is a row's margin inside a narrow column.
    static let pane: CGFloat = 24

    // MARK: Marks

    /// The project's mark: `RepoIcon`, in the sidebar header, on Home, in search results and in
    /// the toolbar title. It was a 9 point dot, which is the size of a bullet and could only ever
    /// carry a colour; at source list icon size it carries the project's initials as well.
    static let repoIcon: CGFloat = 16
    /// The same mark set inline in a line of caption text, where the full size outweighs the
    /// words beside it.
    static let repoIconSmall: CGFloat = 13
    /// The box a sidebar row's state glyph sits in, matching the cap height of the text beside
    /// it so the glyphs line up down the column whichever state each row is in.
    static let glyph: CGFloat = 13
    /// A status dot, sized to sit on a text baseline rather than to be noticed on its own.
    static let dot: CGFloat = 6
    /// What a `Chip` keeps inside its fill. Named because the transcript footer draws a two colour
    /// chip by hand next to a real one, and the two have to be the same shape.
    static let chipInsetH: CGFloat = 5
    static let chipInsetV: CGFloat = 2
    /// A strip of small controls along the edge of a pane: the sidebar's status bar, the
    /// inspector's pull request strip and its tab row.
    static let barHeight: CGFloat = 32
}

/// How a pane arrives and leaves.
///
/// One curve for the inspector and for the terminal panel, because two panes that move at
/// different speeds read as two apps. Short and without overshoot: a pane is furniture, and
/// furniture that springs is a toy. Call sites drop it for Reduce Motion rather than substituting
/// a slower one, because the setting is about movement, not about speed.
enum Motion {
    static let pane: Animation = .easeOut(duration: 0.18)

    /// A hover state fading in, and a disclosure settling. See the sidebar rows.
    ///
    /// Shorter than `pane`, and the only speed in this file that is: a hover has to be under way
    /// before the cursor has finished arriving, or the row reads as lagging rather than as
    /// responding. Named because five call sites had grown their own literals (0.12 twice, 0.15,
    /// 0.2 once) and a file that argues one window has one speed cannot also hold four of them.
    static let hover: Animation = .easeInOut(duration: 0.12)

    /// A pane's own length, borrowed by anything that settles at the same speed.
    ///
    /// It used to be the row settle, and `RowArrival` no longer reads it: what a row arriving is
    /// owed is opacity paired with a small rise, which is two numbers rather than a curve, and two
    /// numbers describing what the transcript is allowed to animate belong in `TranscriptMotion`
    /// where there is something to test them. What is left here are the three call sites that
    /// wanted the length alone.
    ///
    /// The same curve and the same length as `pane`, deliberately and not by accident: a window
    /// with one speed is the whole argument above, and a row arriving is if anything a smaller
    /// event than a pane travelling, so it has no case for being the slower of the two. It is
    /// named separately because it answers a different question and a later answer to one of them
    /// should not silently become the answer to both.
    ///
    /// Opacity only, with no movement under it. A row that slid or grew into place would be
    /// announcing itself, and what is wanted is the opposite: something that reads as the row
    /// having settled rather than as anything having been played. `easeOut` is what makes the
    /// short length carry, because it puts most of the opacity in the first third and spends the
    /// rest arriving.
    static let arrival: Animation = .easeOut(duration: 0.18)

    /// One crossing of the window's shared rule by the light, out or back. See `RuleSweep`.
    ///
    /// Deliberately nothing like `pane`, and this is the one place in the file where that is the
    /// right answer. Everything else here is a response: something was pressed and the window
    /// answers in a fifth of a second. This is a background signal that runs for as long as an
    /// agent works, which can be hours, and at a pane's speed a light crossing the whole window
    /// would be a flick rather than a pass. Three seconds is slow enough to read as texture from
    /// the far edge of vision and never fast enough to pull the eye off the transcript.
    ///
    /// `easeInOut` rather than `linear` because the light does not leave the rule at the end of a
    /// crossing any more, it turns round on it, and this curve is what the turn is made of: it
    /// puts the light's speed at zero on the frame it reaches an end and takes it back up from
    /// there, so the two legs are the halves of one movement rather than two crossings stitched
    /// together. The same shape macOS gives its own indeterminate bar, measured off one rather
    /// than assumed. See `RuleSweep`.
    ///
    /// Three seconds is a crossing, and out and back is six. Nothing waits any more: the light
    /// used to travel for three seconds of every four and a half and be parked off the far edge
    /// for the rest, so a crossing now begins every three seconds where one began every four and
    /// a half.
    static let sweep: Animation = .easeInOut(duration: 3)

}

// MARK: - Materials

/// A real AppKit material, so the sidebar is translucent and vibrant the way every other Mac
/// sidebar is, and so it dims correctly when the window is not key.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = emphasized
    }
}

extension View {
    /// The sidebar's ground.
    ///
    /// A named colour rather than `NSVisualEffectView(.sidebar)`, and this is the one place where
    /// dropping a system material is the right call. Sidebar vibrancy blends with the desktop
    /// behind the window, so the column's colour is set by whatever wallpaper the user happens to
    /// have: measured on this machine it rendered `#232833` in dark, a blue nobody picked, and it
    /// would render green over a green wallpaper. A themed ramp cannot survive that. Everything
    /// vibrancy was buying beyond the tint, the rounded window corner and the toolbar unification,
    /// belongs to the window rather than to this view and is unaffected.
    func sidebarMaterial() -> some View {
        background(Palette.sidebar)
    }

    /// The ground under a strip of small controls: a panel's tab bar, a run script's header.
    ///
    /// `NSVisualEffectView(.headerView)` measured `#292C33` over a `#0A1A25` pane, a neutral grey
    /// with nothing to do with what was behind it, so every strip in the window read as a piece of
    /// a different app laid on top. The chrome colour is what the material was standing in for.
    func headerMaterial() -> some View {
        background(Palette.sidebar)
    }

    /// The strip a tab bar sits in: the header material with the pane's top edge already on it.
    ///
    /// The rule belongs here, behind the tabs, rather than in an overlay over them. Drawn over the
    /// top it crosses the selected tab as well, which boxes that tab in and leaves the strip
    /// reading as a row of buttons; drawn behind, the selected tab's own opaque fill breaks it, and
    /// that break is what joins the tab to the content below.
    ///
    /// `sweeping` puts the busy signal on that rule, and it goes in this background rather than in
    /// an overlay for exactly the reason the rule does. The light has to be broken by the selected
    /// tab on the same pixels the rule is broken on, or it reads as a stutter instead of as
    /// something passing behind the tab. See `RuleSweep`.
    func tabStripMaterial(sweeping: Bool = false) -> some View {
        background {
            ZStack(alignment: .bottom) {
                Palette.sidebar
                Hairline()
                if sweeping { RuleSweep(segment: .tabStrip) }
            }
        }
    }
}

// MARK: - Reusable chrome

/// A separator drawn at `Metrics.hairline`: one point, which is two physical pixels on Retina and
/// what AppKit's own split view divider has always been. See that constant for why it is not half
/// a point.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(
                width: axis == .vertical ? Metrics.hairline : nil,
                height: axis == .horizontal ? Metrics.hairline : nil
            )
    }
}

/// The small rounded label used for tool names, file chips, counts and states.
struct Chip: View {
    var text: String
    var systemImage: String?
    var tint: Color = Palette.textSecondary
    var background: Color = Palette.hover
    var monospaced: Bool = false

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        // A chip carries content, not metadata: the file a tool read, the model a session started
        // on. At 10 it was the smallest thing in the window while saying the most, and it was the
        // one place drawing a raw `.caption2` rather than a rung of the scale.
        HStack(spacing: Metrics.spacingSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Typo.micro)
                    .imageScale(.small)
            }
            Text(text)
                .font(monospaced ? Typo.codeSmall : Typo.caption)
                .lineLimit(1)
        }
        .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : tint)
        .padding(.horizontal, Metrics.chipInsetH)
        .padding(.vertical, Metrics.chipInsetV)
        .background(
            isOnSelection ? Palette.selectedEmphasizedText.opacity(0.2) : background,
            in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
        )
    }
}

/// `+118 -4` as seen next to a workspace in the sidebar.
struct DiffStatLabel: View {
    var additions: Int
    var deletions: Int
    var compact: Bool = false

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if additions > 0 {
                Text("+\(Self.abbreviate(additions))")
                    .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : Palette.positive)
            }
            if deletions > 0 {
                Text("-\(Self.abbreviate(deletions))")
                    .foregroundStyle(
                        isOnSelection
                            ? Palette.selectedEmphasizedText.opacity(0.75)
                            : Palette.negative
                    )
            }
        }
        // One rung, two designs: `compact` is the monospaced form used inside a chip, where the
        // digits have to line up with a filename set in the same face, not a smaller form. It was
        // written as a size step and never was one, because both styles resolved to 10.
        .font(compact ? Typo.codeSmall : Typo.caption)
        .monospacedDigit()
    }

    /// 2.8k rather than 2793, because the sidebar has no room for the exact number.
    ///
    /// `formatted` rather than `String(format:)`, which is not locale aware: the composer's token
    /// gauge a few inches away already used `formatted`, so on a machine set to a comma decimal
    /// separator one number in this window read `174,0k` and the other `2.8k`.
    static func abbreviate(_ value: Int) -> String {
        if value < 1_000 { return value.formatted(.number.grouping(.never)) }
        let thousands = Double(value) / 1_000
        return thousands < 10
            ? "\(thousands.formatted(.number.precision(.fractionLength(1))))k"
            : "\(thousands.formatted(.number.precision(.fractionLength(0)).grouping(.never)))k"
    }
}

/// Whether the content is sitting on an emphasized (accent coloured) selection.
///
/// A selected row inverts its text, but a label that hard-codes a colour, such as a green plus
/// count, keeps its own and ends up unreadable on the accent fill. Descendants read this to pick
/// a variant that survives the inversion, which is what AppKit does for secondary text in a
/// selected table row.
private struct OnEmphasizedSelectionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isOnEmphasizedSelection: Bool {
        get { self[OnEmphasizedSelectionKey.self] }
        set { self[OnEmphasizedSelectionKey.self] = newValue }
    }
}

/// Rows in the sidebar and the file list share this hover and selection treatment.
///
/// Selection follows the AppKit convention rather than a single fixed colour: the accent colour
/// only when the window is active, a quiet grey otherwise. A row that stays vivid blue in a
/// background window is one of the clearest tells that an app is not really native.
struct RowBackground: ViewModifier {
    var isSelected: Bool
    var isHovered: Bool
    /// Whether the list this row belongs to has keyboard focus.
    ///
    /// Default false, because most of the lists that draw a selection in this window never take
    /// focus. The inspector's changed files are picked with the pointer while the composer holds
    /// the keyboard, and AppKit's rule for that is the quiet grey, not the accent: the emphasized
    /// fill means "the arrow keys move this", and painting it on a list the arrow keys do not move
    /// is a promise the window does not keep. It was keyed on the window being main instead, which
    /// is why every one of those rows sat in a saturated accent fill all the time.
    ///
    /// The menus over the composer pass true, since they really are driven by the arrow keys.
    var isFocused: Bool = false

    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .fill(fill)
            }
            .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary)
            .environment(\.isOnEmphasizedSelection, isEmphasized)
    }

    private var isEmphasized: Bool {
        isSelected && isFocused && activeState != .inactive
    }

    private var fill: Color {
        if isSelected {
            return isEmphasized ? Palette.selectedEmphasized : Palette.selected
        }
        return isHovered ? Palette.hover : .clear
    }
}

extension View {
    func rowBackground(
        isSelected: Bool, isHovered: Bool, isFocused: Bool = false
    ) -> some View {
        modifier(
            RowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: isFocused)
        )
    }

    /// Tracks hover without each call site needing its own @State.
    func onHoverChange(_ handler: @escaping (Bool) -> Void) -> some View {
        onHover(perform: handler)
    }
}

/// A spinner that does not animate when nothing is running, because a dozen idle workspaces
/// each animating a spinner is a measurable amount of CPU.
struct ActivityDot: View {
    var isActive: Bool
    var tint: Color = Palette.running

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// Reduce Motion drops the pulse rather than slowing it, the same way the pane animations do.
    /// The dot still says what it said: it is tinted while something is running and grey when it
    /// is not, so nothing is lost by holding it still.
    private var isPulsing: Bool { isActive && pulse && !reduceMotion }

    var body: some View {
        Circle()
            .fill(isActive ? tint : Palette.textTertiary)
            .frame(width: Metrics.dot, height: Metrics.dot)
            .scaleEffect(isPulsing ? 1.35 : 1)
            .opacity(isPulsing ? 0.5 : 1)
            .animation(
                isActive && !reduceMotion
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onChange(of: isActive, initial: true) { _, active in
                pulse = active
            }
    }
}

// MARK: - Link buttons

extension View {
    /// A `Button` that reads as a link, in Bloom's teal rather than the system accent.
    ///
    /// `.linkButton()` alone draws system blue: measured `#2B66D3` on this machine, and
    /// whatever the user picked in Appearance on anyone else's. Several of these sit in the
    /// transcript inches from prose links that `Palette.linkNSColor` already paints teal, so the
    /// same word rendered two colours depending on whether it was markdown or a control.
    ///
    /// A modifier rather than a note in a review, because there are eleven call sites and the
    /// twelfth is the one that would be missed.
    func linkButton() -> some View {
        buttonStyle(.link).tint(Palette.link)
    }
}

// MARK: - Focus rings

extension ControlActiveState {
    /// Whether a focus ring drawn under this state should be visible at all.
    ///
    /// AppKit draws a focus ring only in the key window, and every hand-drawn ring in Bloom was
    /// drawing one in every window at once: with five workspaces open, four of them showed a lit
    /// composer while the fifth was the one actually taking the keys.
    ///
    /// Named here rather than written out at each ring, because there are five of them and the
    /// sixth is the one that would be missed.
    var showsFocusRing: Bool { self != .inactive }
}
