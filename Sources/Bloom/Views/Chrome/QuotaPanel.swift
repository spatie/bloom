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
struct QuotaPanel: View {
    let board: QuotaBoard
    /// Passed rather than read, so every countdown in one drawing agrees and so the panel can be
    /// rendered at a fixed instant.
    var now: Date = Date()

    /// The menu sizes itself to its widest item, so this is what decides how wide the whole menu
    /// is, and it is a measurement rather than a taste. A ledger line is a provider name, a window
    /// label, a forty eight point lane and a countdown, and at 268 the longest pair Bloom can
    /// produce today, "Claude Code" beside "5 hours", truncated to "Claude Code . 5...". This is
    /// the width that holds it with the columns still lining up, and no more: a menu that reaches
    /// a third of the way across the screen to carry two percentages is worse than one that wraps
    /// nothing.
    static let width: CGFloat = 272

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
                        .fill(Palette.border)
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
    /// of it. Set on the scale's floor rung, uppercased and tracked, which is the treatment the
    /// question card's header already uses for exactly this job.
    private var eyebrow: some View {
        Text("ALLOWANCE")
            .font(Typo.micro)
            .tracking(Typo.microTracking)
            .foregroundStyle(Palette.textTertiary)
            .padding(.bottom, Metrics.spacing)
    }

    // MARK: The headline

    private func headlineBlock(_ quota: AgentQuota) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                Text(title(for: quota))
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Metrics.spacingWide)
                Text(percentage(quota) ?? "")
                    .font(Typo.title)
                    .monospacedDigit()
                    .foregroundStyle(tint(for: quota))
            }

            lane(for: quota, height: 4)

            if let resetsAt = quota.resetsAt {
                Text("Lifts \(QuotaCountdown.phrase(until: resetsAt, from: now))")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
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
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
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
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            // Sized to the words rather than to the lane, because the lane would happily be
            // half this and "not reported" would not, and a column that changes width depending
            // on which of the two a row is showing is not a column.
            .frame(width: 66, alignment: .leading)
            .gridColumnAlignment(.leading)
            Text(quota.resetsAt.map { QuotaCountdown.phrase(until: $0, from: now) } ?? "")
                .font(Typo.micro)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                // Pushed to the panel's own edge rather than to the grid's natural width, so the
                // countdowns end where the headline lane ends. Sized to the longest phrase this
                // can produce, which lets the column hold still as the numbers count down instead
                // of the whole menu breathing in and out under the pointer.
                .frame(minWidth: 62, maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
        }
    }

    // MARK: The empty state

    /// Two of the four CLIs Bloom detects publish nothing about allowances, and the two that do
    /// publish only after a turn, so an install that has not run one yet lands here. It says what
    /// will fill it rather than announcing an absence, because there is nothing wrong.
    private var emptyState: some View {
        Text("Nothing reported yet. Claude Code and Codex each publish theirs after a turn.")
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Parts

    /// The filled length. Square rather than rounded, and the track is the border colour rather
    /// than a wash of the fill, so an almost empty lane still reads as a lane with something in it
    /// instead of as a faint smear of the accent.
    private func lane(for quota: AgentQuota, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.border)
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

    /// The severity ramp, and it is the app's own three marks rather than a traffic light invented
    /// here. `Palette.warning` is amber and `Palette.negative` is the red every failed check in
    /// this window already uses, so a lane going red means the same thing as everything else that
    /// does.
    private func tint(for quota: AgentQuota) -> Color {
        switch QuotaSeverity.of(quota.fraction) {
        case .calm: Palette.accent
        case .warning: Palette.warning
        case .critical, .spent: Palette.negative
        }
    }
}
