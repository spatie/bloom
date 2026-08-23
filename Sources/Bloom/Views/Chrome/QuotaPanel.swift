import SwiftUI
import BloomCore

/// What the menu bar shows about how much of each provider's allowance is left.
///
/// **The shape is the decision, and it is a decision against a dashboard.** Bloom can know four
/// windows at once, two from each backend that publishes any, and four stacked bars is a control
/// panel opened by somebody who came to read one thing. So the panel answers one question in the
/// place the eye lands first, which is how close you are to the nearest wall and when that wall
/// lifts, and puts the rest underneath as a ledger of single lines. The headline window is not
/// repeated in the ledger; it has already been said.
///
/// The bar is a lane rather than a capsule, drawn square, because the app's mark is three lanes
/// arriving and one leaving and this is the one place in the interface where a filled length is
/// the whole content. A rounded pill here would be the same shape every progress view on the
/// platform is, which is the shape this panel is trying not to be.
///
/// A window whose usage the provider has not published gets no lane at all. Claude Code sends a
/// figure only once a window has passed its warning threshold, so drawing an empty track for the
/// other case would tell somebody they had used nothing when what is true is that nobody said.
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
    /// is, and it is a measurement rather than a taste. A ledger line is a provider name, a window
    /// label, a lane or the words "not reported", and a countdown.
    ///
    /// It was 272 when the panel was set at eleven and ten points. Menu size is thirteen or
    /// fourteen depending on the machine, so every column grew, and this is the width measured off
    /// a capture of the real menu carrying the longest row Bloom can produce today, "Claude Code .
    /// 5 hours" beside "not reported" beside "in 4h 32m", with nothing truncated and the columns
    /// still lining up. A menu that reaches a third of the way across the screen to carry two
    /// percentages is worse than one that wraps nothing, and this is the narrowest that wraps
    /// nothing.
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

    private var ledger: [AgentQuota] {
        let headline = board.headline?.id
        return board.all.filter { $0.id != headline }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow

            if let headline = board.headline {
                headlineBlock(headline)
            }

            if !ledger.isEmpty {
                if board.headline != nil {
                    Rectangle()
                        .fill(MenuInk.rule)
                        .frame(height: Metrics.hairline)
                        .padding(.vertical, Metrics.spacingWide)
                }
                // A grid rather than a stack of rows, so the lanes start on one edge and the
                // countdowns end on one edge whatever the provider is called. Three loose rows
                // was the first version and the lanes wandered by twenty points down the column.
                Grid(alignment: .leading, horizontalSpacing: Metrics.spacing, verticalSpacing: Metrics.spacing) {
                    ForEach(ledger) { quota in
                        ledgerRow(quota)
                    }
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
        Text("LIMITS")
            .font(Self.headingFont)
            .tracking(Typo.microTracking)
            .foregroundStyle(MenuInk.secondary)
            .padding(.bottom, Metrics.spacingSmall)
    }

    // MARK: The headline

    private func headlineBlock(_ quota: AgentQuota) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                Text(title(for: quota))
                    .font(Self.rowFontEmphasised)
                    .foregroundStyle(MenuInk.primary)
                Spacer(minLength: Metrics.spacingWide)
                // `labelColor` and not the severity tint, which is what this used to be.
                //
                // Photographed on a near-white menu, `systemOrange` at semibold measures about two
                // to one against the material, under even the three to one a large glyph has to
                // clear, so the one number the panel exists to show was the palest thing on the
                // row. The lane directly under it carries the tint instead, which is the job a
                // system colour like `systemOrange` is tuned for, and this reads as firmly as the
                // menu item below it. Severity is not lost: a spent window is a full red lane.
                Text(percentage(quota) ?? "")
                    .font(Self.rowFontEmphasised)
                    .monospacedDigit()
                    .foregroundStyle(MenuInk.primary)
            }

            lane(for: quota, height: 4)

            if let resetsAt = quota.resetsAt {
                Text("Lifts \(QuotaCountdown.phrase(until: resetsAt, from: now))")
                    .font(Self.rowFont)
                    .foregroundStyle(MenuInk.secondary)
            }
        }
    }

    // MARK: The ledger

    /// One line per window: who and which window on the left, then the lane, then how long. The
    /// percentage is deliberately absent here. Three numbers on a line is a table, and the lane
    /// already says the thing the number would, to the precision anybody reads a menu for.
    private func ledgerRow(_ quota: AgentQuota) -> some View {
        GridRow {
            Text(title(for: quota))
                .font(Self.rowFont)
                // `labelColor`, the same ink as the menu items under it, because this is a row
                // label and not a caption. It was the secondary rung and read as one.
                .foregroundStyle(MenuInk.primary)
                .lineLimit(1)
                // The row is wide enough for this and SwiftUI still truncated it, because the two
                // fixed columns beside it are asked for their width first and the name is left
                // whatever is over. Nothing here may be shortened: a menu that says
                // "Claude Code . 5 ho..." has failed at the one job it has.
                .fixedSize()
                .gridColumnAlignment(.leading)
            Group {
                if quota.fraction != nil {
                    lane(for: quota, height: 3)
                } else {
                    // Not an empty track. An empty track is a claim about how much has gone, and
                    // the whole point of this case is that nobody made one.
                    Text("not reported")
                        .font(Self.rowFont)
                        .foregroundStyle(MenuInk.secondary)
                        .lineLimit(1)
                }
            }
            // Sized to the words rather than to the lane, because the lane would happily be
            // half this and "not reported" would not, and a column that changes width depending
            // on which of the two a row is showing is not a column.
            .frame(width: 92, alignment: .leading)
            .gridColumnAlignment(.leading)
            Text(quota.resetsAt.map { QuotaCountdown.phrase(until: $0, from: now) } ?? "")
                .font(Self.rowFont)
                .monospacedDigit()
                .foregroundStyle(MenuInk.secondary)
                .lineLimit(1)
                // Pushed to the panel's own edge rather than to the grid's natural width, so the
                // countdowns end where the headline lane ends. Sized to the longest phrase this
                // can produce, which lets the column hold still as the numbers count down instead
                // of the whole menu breathing in and out under the pointer.
                .frame(minWidth: 78, maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
        }
    }

    /// When the figures above were last confirmed, shown only once they are old enough to matter.
    ///
    /// Under everything rather than beside a row, because it is one fact about the whole panel:
    /// the ask goes out for every provider at once, so they go stale together. In the secondary
    /// ink and not a warning colour, because an old reading is not an alarm, it is a caveat on
    /// numbers that are otherwise still the best answer anybody has.
    private func staleNote(_ age: String) -> some View {
        Text("Last checked \(age)")
            .font(Self.rowFont)
            .foregroundStyle(MenuInk.secondary)
            .padding(.top, Metrics.spacingWide)
    }

    // MARK: The empty state

    /// Two of the four CLIs Bloom detects publish nothing about their limits, and the two that do
    /// have to be installed and signed in before they will answer, so a machine with neither lands
    /// here. It says what will fill it rather than announcing an absence, because there is nothing
    /// wrong.
    private var emptyState: some View {
        Text(Self.emptySentence)
            .font(Self.rowFont)
            .foregroundStyle(MenuInk.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Why the panel is empty, said as a thing that is about to happen rather than as a blank.
    ///
    /// It names the mechanism, because "nothing reported yet" on its own reads as broken. As Bloom
    /// stands, both figures arrive on the way out of a turn and nowhere else, so a fresh install
    /// shows this until the first one finishes.
    ///
    /// It no longer says "after the next turn", because Bloom no longer waits to be told. Both
    /// providers are asked directly, on a schedule, and neither ask costs a turn: Claude Code
    /// answers a `control_request` of subtype `get_usage`, and the Codex app-server answers
    /// `account/rateLimits/read`. See `AgentQuotaSources`. What is left here is the genuinely
    /// empty case: neither CLI installed, neither signed in, or the very first seconds of a launch
    /// before the first ask has come back.
    static let emptySentence =
        "Nothing reported yet. Bloom asks Claude Code and Codex for their figures every few "
        + "minutes, so this fills in shortly after either one is installed and signed in."


    // MARK: Parts

    /// The filled length. Square rather than rounded, and the track is a rung of ink rather than
    /// a wash of the fill, so an almost empty lane still reads as a lane with something in it
    /// instead of as a faint smear of colour.
    ///
    /// `tertiaryLabelColor` for the track, not `Palette.border`. The border is a rule tuned to
    /// separate two panes of a Bloom window, and on the menu's material it came out as very nearly
    /// nothing: the ledger's short lanes read as a stub of colour floating with no track behind
    /// them. A quarter of the menu's own ink is a track in both appearances and under Reduce
    /// Transparency, because it is the same ink the menu is drawing everything else with.
    private func lane(for quota: AgentQuota, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(MenuInk.track)
                Rectangle()
                    .fill(tint(for: quota))
                    // Clamped at both ends. A provider reporting 103 percent of an overage
                    // allowance is a thing that happens and a lane wider than its track draws over
                    // the text; and at the other end the ledger's lane is forty eight points long,
                    // so six percent of it rounds to nothing at all and a window that has been used
                    // reads as one that has not.
                    .frame(width: laneFill(quota.fraction, of: proxy.size.width, thickness: height))
            }
        }
        .frame(height: height)
    }

    /// Never wider than the track, and never narrower than the lane is thick, so the shortest
    /// honest fill is a square rather than a hairline nobody can see.
    private func laneFill(_ fraction: Double?, of width: CGFloat, thickness: CGFloat) -> CGFloat {
        let share = min(max(fraction ?? 0, 0), 1)
        guard share > 0 else { return 0 }
        return min(max(width * share, thickness), width)
    }

    private func title(for quota: AgentQuota) -> String {
        "\(quota.provider.label) · \(quota.window.label)"
    }

    private func percentage(_ quota: AgentQuota) -> String? {
        // Rounded down, never up. Rounding 0.999 to "100%" says a window is spent while there is
        // still room in it, which is the one direction this number must not be wrong in.
        quota.fraction.map { "\(Int((min(max($0, 0), 1) * 100).rounded(.down)))%" }
    }

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
    private func tint(for quota: AgentQuota) -> Color {
        switch QuotaSeverity.of(quota.fraction) {
        case .calm: MenuInk.calm
        case .warning: MenuInk.warning
        case .critical, .spent: MenuInk.critical
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
    /// The rule between the headline and the ledger, and it is the menu's own separator.
    static var rule: Color { Color(nsColor: .separatorColor) }
    static var calm: Color { Color(nsColor: .controlAccentColor) }
    static var warning: Color { Color(nsColor: .systemOrange) }
    static var critical: Color { Color(nsColor: .systemRed) }
}
