import SwiftUI
import BloomCore

/// What the menu bar shows about how much of each provider's allowance is left.
///
/// **The shape is a list, in the order the provider's own windows come in, and that is a decision
/// taken twice.** The first version drew four bars of equal weight and read as a dashboard. The
/// second promoted whichever window was nearest its wall into a headline with a bigger figure and
/// left the rest as a ledger of small rows with no figures at all, which is what the owner was
/// looking at when he asked for this: one row drawn large with a number and two drawn small
/// without one, and no way to compare a lane in the first against a lane in the second because
/// they were not even the same length.
///
/// What he asked for instead is the plain reading: each provider in turn, and inside a provider the
/// shortest window first, so the five hour window sits above the week. Every row carries its own
/// figure, every lane runs the full width of the panel at the same scale, and nothing is promoted,
/// so the list holds still instead of reshuffling itself whenever one number crosses another.
/// `QuotaBoard.lines` is where all of that is decided; this file draws what it is handed.
///
/// The lane is drawn square rather than as a capsule, because the app's mark is three lanes
/// arriving and one leaving and this is the one place in the interface where a filled length is the
/// whole content. A rounded pill here would be the same shape every progress view on the platform
/// is, which is the shape this panel is trying not to be.
///
/// A window whose usage the provider has not published gets no track at all. Claude Code sends a
/// figure only once a window has passed its warning threshold, so drawing an empty track for the
/// other case would tell somebody they had used nothing when what is true is that nobody said. The
/// two cases have to look different and they do: a measured zero is a full track with nothing in
/// it, and an unmeasured window is a dashed rule and the words.
///
/// **Nothing in here comes from `Palette` or `Typo`, and that is the point.** This is the one view
/// in Bloom that is not drawn in a Bloom window. It is hosted in an `NSMenu`, sitting on the menu's
/// own vibrant material, with real `NSMenuItem`s above and below it that AppKit draws in
/// `labelColor` at `NSFont.menuFont`. A menu is system chrome, and a row of system chrome that
/// wears the app's palette reads as something pasted onto the menu rather than as one of its rows.
///
/// It was pasted on, and the photograph of the real menu in light said so. The eyebrow, "not
/// reported" and every countdown were `Palette.textTertiary`, a blue-grey the app tuned to sit on
/// its own white page, and on the menu's near-white translucency they came out at about three to
/// one beside a jet black "Prevent Sleep While Agents Run" one row below. The lane's track was
/// `Palette.border`, a rule tuned to divide two panes of a window, and on this material it very
/// nearly disappeared; the panel's own rule was visibly paler than the menu's real separators an
/// inch under it. None of that is a bug in the palette. Those values are correct on the ground
/// they were measured against, and this is a different ground, translucent, tinted by whatever is
/// behind the menu bar, and different again under Reduce Transparency.
///
/// So every colour below is an AppKit semantic one and every size comes from `NSFont.menuFont`.
/// They resolve against the menu's own effective appearance exactly as the items around them do,
/// which is the only way this panel can be as legible as its neighbours in both appearances, on
/// any accent, and with Reduce Transparency or Increase Contrast switched on. The one thing kept
/// from the app is the severity ramp's meaning, not its values: calm, warning, critical still
/// step in that order, in the system's own three colours.
struct QuotaPanel: View {
    let board: QuotaBoard
    /// How old the oldest figure on the board is, decided in `BloomCore` rather than here.
    ///
    /// **A number with no age on it is a claim about now.** Bloom asks both providers on a
    /// schedule, so between asks the panel is drawing history, and that is fine right up until
    /// something has stopped answering. A five hour window drawn at 40 percent from this morning's
    /// reading would be worse than the "not reported" this whole feature replaced, so a board that
    /// has missed two polls says how long ago underneath itself and stops implying otherwise.
    var freshness: QuotaFreshness = .current
    /// Passed rather than read, so every countdown in one drawing agrees and so the panel can be
    /// rendered at a fixed instant.
    var now: Date = Date()

    /// The menu sizes itself to its widest item, so this is what decides how wide the whole menu
    /// is, and it is a measurement rather than a taste.
    ///
    /// It was 272 when the panel was set at eleven and ten points. Menu size is thirteen or
    /// fourteen depending on the machine, so every column grew, and this is the width measured off
    /// a capture of the real menu carrying the longest row Bloom can produce, with nothing
    /// truncated. It is now also what sets the lane's length, which is the reason it must not
    /// shrink: every lane in the panel is this wide, so two rows can be compared by eye.
    static let width: CGFloat = 344

    /// The two insets are different, and they are AppKit's rather than a choice.
    ///
    /// A standard menu item's title starts clear of the column its checkmark is drawn in, and its
    /// separators start on that same edge. Measured off a capture of this menu open: twenty nine
    /// points from the menu's leading edge to the title, fourteen from its trailing edge to the end
    /// of a separator. A panel padded evenly sat sixteen points to the left of "Prevent Sleep While
    /// Agents Run" underneath it, with its rule overhanging the separators above and below, and
    /// read as something pasted onto the menu rather than as one of its rows.
    private static let leadingInset: CGFloat = 29
    private static let trailingInset: CGFloat = 14

    /// The type, and all of it is the menu's rather than the app's.
    ///
    /// `Typo` is a scale built on the system text styles, which is right in a window and wrong
    /// here: its rungs are eleven and ten points, and a menu item is thirteen or fourteen
    /// depending on the machine and the user's settings. Set on that scale the panel read as a
    /// caption sitting above the menu instead of as two of its rows, which is exactly what it was
    /// reported as. `NSFont.menuFont(ofSize: 0)` is the size AppKit is drawing "Prevent Sleep
    /// While Agents Run" at, whatever that turns out to be, so asking for it is the only answer
    /// that stays right on a machine this was never measured on.
    private static var rowFont: Font { Font(NSFont.menuFont(ofSize: 0)) }
    private static var rowFontEmphasised: Font { rowFont.weight(.semibold) }

    /// The eyebrow, and the one thing here allowed to be smaller than a menu item, because a
    /// heading over a list is smaller than the list in every sidebar on the platform. Two points
    /// down from menu size rather than a rung of a scale, so it moves with the menu font.
    private static var headingFont: Font {
        Font(NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2)).weight(.semibold)
    }

    /// The footnote, one point down from a menu item.
    ///
    /// Every row now carries one, where before only the promoted row did, so three or four of them
    /// stack down the panel and at full menu size they competed with the names above them. One
    /// point is enough to settle them and not enough to make them a caption: they are still read,
    /// and "Lifts in 3d" is half the answer somebody opened this for.
    private static var footFont: Font {
        Font(NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 1))
    }

    /// How thick a lane is. One value, because every lane is now the same lane.
    private static let laneHeight: CGFloat = 4

    /// The gap between one window's block and the next.
    ///
    /// Wider than anything inside a block, which is what makes three lines read as one row rather
    /// than as three. It is the only grouping in the panel: there are no rules between rows, since
    /// a rule every three lines in a 344 point column is a fence around every sheep.
    private static let rowGap: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow

            VStack(alignment: .leading, spacing: Self.rowGap) {
                ForEach(board.lines(at: now)) { line in
                    row(line)
                }
            }

            if board.isEmpty { emptyState }
            if !board.isEmpty, let age = freshness.phrase { staleNote(age) }
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
        .padding(.top, Metrics.spacing)
        .padding(.bottom, Metrics.spacingWide)
        .fixedSize()
    }

    // MARK: The eyebrow

    /// Named, because a block of percentages under the sleep switch with no heading reads as part
    /// of it.
    ///
    /// "LIMITS" rather than "ALLOWANCE", which is the owner's word and the shorter one. Uppercased
    /// and tracked, because capitals at this size set nearly solid, and in `secondaryLabelColor`
    /// rather than the tertiary rung: tertiary is what AppKit draws a DISABLED item in, and a
    /// heading nobody can read is a heading nobody reads.
    private var eyebrow: some View {
        Text(QuotaPhrase.heading)
            .font(Self.headingFont)
            .tracking(Typo.microTracking)
            .foregroundStyle(MenuInk.secondary)
            .padding(.bottom, Metrics.spacingWide)
    }

    // MARK: One window

    /// Three lines: who and how much, the lane, and when it lifts.
    ///
    /// The figure sits at the panel's trailing edge rather than beside the name, so every figure in
    /// the panel is on one right hand margin and the column can be read down without reading the
    /// names. It is `labelColor` and not the severity tint, which is what it used to be:
    /// photographed on a near-white menu, `systemOrange` at semibold measured about two to one
    /// against the material, under even the three to one a large glyph has to clear, so the one
    /// number the panel exists to show was the palest thing on the row. The lane directly under it
    /// carries the tint instead, which is the job a system colour like `systemOrange` is tuned for.
    private func row(_ line: QuotaLine) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
                Text(line.title)
                    .font(Self.rowFont)
                    .foregroundStyle(MenuInk.primary)
                    .lineLimit(1)
                    // Nothing here may be shortened: a menu that says "Claude Code · 5 ho..." has
                    // failed at the one job it has. The panel is sized so this never bites, and
                    // this is what makes that a promise rather than a hope.
                    .fixedSize()
                Spacer(minLength: Metrics.spacingWide)
                Text(line.figure)
                    .font(Self.rowFontEmphasised)
                    .monospacedDigit()
                    .foregroundStyle(line.severity == nil ? MenuInk.secondary : MenuInk.primary)
                    .lineLimit(1)
                    .fixedSize()
            }

            lane(line)

            if !line.footnote.isEmpty {
                Text(line.footnote)
                    .font(Self.footFont)
                    .foregroundStyle(MenuInk.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    // MARK: Parts

    /// The filled length, or a dashed rule for a window nobody has measured.
    ///
    /// The track is a rung of ink rather than a wash of the fill, so an almost empty lane still
    /// reads as a lane with something in it instead of as a faint smear of colour.
    /// `tertiaryLabelColor` and not `Palette.border`: the border is a rule tuned to separate two
    /// panes of a Bloom window, and on the menu's material it came out as very nearly nothing.
    ///
    /// The unmeasured case is a dashed rule at the same height and never a track, because a track
    /// is a claim about how much has gone and the whole point of that case is that nobody made
    /// one. Dashed rather than absent, so the row keeps the panel's rhythm and so an eye running
    /// down the column can see that something is there and is not a quantity.
    @ViewBuilder
    private func lane(_ line: QuotaLine) -> some View {
        if let fill = line.fill {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(MenuInk.track)
                    Rectangle()
                        .fill(tint(line.severity))
                        // Clamped at both ends. A provider reporting 103 percent of an overage
                        // allowance is a thing that happens and a lane wider than its track draws
                        // over the text; and at the other end a fraction of a percent of 300
                        // points rounds to nothing at all, so a window that has been used reads as
                        // one that has not.
                        .frame(width: laneFill(fill, of: proxy.size.width))
                }
            }
            .frame(height: Self.laneHeight)
        } else {
            Rectangle()
                .fill(MenuInk.track)
                .frame(height: Metrics.hairline)
                .mask(alignment: .leading) {
                    // A dash and a gap, drawn as a repeating gradient rather than as a stroked
                    // path, because a dashed `Shape` inside a menu item's hosting view is measured
                    // by `fittingSize` before it has a width to dash across.
                    LinearGradient(
                        stops: Self.dashStops,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .frame(height: Self.laneHeight)
        }
    }

    /// Twenty four dashes across the panel, which at 344 points is a three point mark and a four
    /// point gap: a rule that reads as broken at arm's length without turning into a texture.
    private static let dashStops: [Gradient.Stop] = (0..<24).flatMap { index -> [Gradient.Stop] in
        let step = 1.0 / 24.0
        let start = Double(index) * step
        return [
            .init(color: .white, location: start),
            .init(color: .white, location: start + step * 0.45),
            .init(color: .clear, location: start + step * 0.45),
            .init(color: .clear, location: start + step),
        ]
    }

    /// Never wider than the track, and never narrower than the lane is thick, so the shortest
    /// honest fill is a square rather than a hairline nobody can see.
    private func laneFill(_ fraction: Double, of width: CGFloat) -> CGFloat {
        let share = min(max(fraction, 0), 1)
        guard share > 0 else { return 0 }
        return min(max(width * share, Self.laneHeight), width)
    }

    /// When the figures above were last confirmed, shown only once they are old enough to matter.
    ///
    /// Under everything rather than beside a row, because it is one fact about the whole panel:
    /// the ask goes out for every provider at once, so they go stale together. In the secondary
    /// ink and not a warning colour, because an old reading is not an alarm, it is a caveat on
    /// numbers that are otherwise still the best answer anybody has.
    private func staleNote(_ age: String) -> some View {
        Text("Last checked \(age)")
            .font(Self.footFont)
            .foregroundStyle(MenuInk.secondary)
            .padding(.top, Self.rowGap)
    }

    // MARK: The empty state

    /// Two of the four CLIs Bloom detects publish nothing about their limits, and the two that do
    /// have to be installed and signed in before they will answer, so a machine with neither lands
    /// here. It says what will fill it rather than announcing an absence, because there is nothing
    /// wrong.
    ///
    /// A provider that is simply absent contributes no rows at all, rather than a row explaining
    /// its own absence. That is `QuotaBoard.make`'s doing and it is the same rule as this one, one
    /// provider at a time.
    private var emptyState: some View {
        Text(Self.emptySentence)
            .font(Self.rowFont)
            .foregroundStyle(MenuInk.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Why the panel is empty, said as a thing that is about to happen rather than as a blank.
    ///
    /// It names the mechanism, because "nothing reported yet" on its own reads as broken. It no
    /// longer says "after the next turn", because Bloom no longer waits to be told: both providers
    /// are asked directly, on a schedule, and neither ask costs a turn. See `AgentQuotaSources`.
    /// What is left here is the genuinely empty case: neither CLI installed, neither signed in, or
    /// the very first seconds of a launch before the first ask has come back.
    static let emptySentence =
        "Nothing reported yet. Bloom asks Claude Code and Codex for their figures every few "
        + "minutes, so this fills in shortly after either one is installed and signed in."

    /// The severity ramp. Three steps, and the system's colours rather than Bloom's.
    ///
    /// It was `Palette.accent`, `Palette.warning` and `Palette.negative`, which are the right three
    /// marks in a Bloom window and the wrong three here for the reason the whole of this view is
    /// now semantic: they are a pair of hex values each, tuned against a white page and against a
    /// very dark blue one, and the menu's dark material is a mid grey rather than either. The
    /// system's three track the menu's appearance, and they lift under Increase Contrast, which no
    /// literal can.
    ///
    /// `controlAccentColor` is the one place this view deliberately obeys System Settings where
    /// the rest of Bloom deliberately does not (see `Palette.accent`). The reason the app overrides
    /// it is that Bloom has a mark and a ramp of its own; a menu does not belong to Bloom. On a Mac
    /// set to Graphite this lane comes out grey, and so does every progress bar the system draws
    /// two menus away, which is the agreement worth having here.
    ///
    /// Nothing calls this with `nil`: a row with no severity has no lane. It is written to take one
    /// anyway so that the day somebody gives an unmeasured row a lane, it is grey rather than
    /// quietly the accent, which would be the panel inventing a measurement.
    private func tint(_ severity: QuotaSeverity?) -> Color {
        switch severity {
        case .calm: MenuInk.calm
        case .warning: MenuInk.warning
        case .critical, .spent: MenuInk.critical
        case nil: MenuInk.track
        }
    }
}

/// The ink a view hosted in an `NSMenu` is drawn in, which is AppKit's and never Bloom's.
///
/// Named here rather than reached for as `Color(nsColor: .labelColor)` at nine call sites, so that
/// the next person adding a row to the panel picks a rung off this list instead of picking one off
/// `Palette` and undoing the fix. See the head of `QuotaPanel` for what went wrong.
private enum MenuInk {
    /// A row label: the same ink AppKit draws a menu item's title in.
    static var primary: Color { Color(nsColor: .labelColor) }
    /// Anything read off the row beside it: a countdown, a heading, a note.
    static var secondary: Color { Color(nsColor: .secondaryLabelColor) }
    /// The empty part of a lane.
    static var track: Color { Color(nsColor: .tertiaryLabelColor) }
    static var calm: Color { Color(nsColor: .controlAccentColor) }
    static var warning: Color { Color(nsColor: .systemOrange) }
    static var critical: Color { Color(nsColor: .systemRed) }
}
