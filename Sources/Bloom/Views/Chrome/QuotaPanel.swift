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
    /// is. Wide enough for "Claude Code" and a window label on one line with the lane and the
    /// countdown beside them, and no wider: a menu that reaches a third of the way across the
    /// screen to hold two percentages is worse than one that wraps nothing.
    static let width: CGFloat = 268

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
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    ForEach(ledger) { quota in
                        ledgerRow(quota)
                    }
                }
            }

            if board.isEmpty { emptyState }
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.horizontal, Metrics.inset + Metrics.spacingSmall)
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
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Metrics.spacingWide)
                Text(percentage(quota) ?? "")
                    .font(Typo.labelEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(tint(for: quota))
            }

            lane(for: quota, height: 6)

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
        HStack(spacing: Metrics.spacingWide) {
            Text(title(for: quota))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Metrics.spacingSmall)
            if quota.fraction != nil {
                lane(for: quota, height: 3)
                    .frame(width: 42)
            } else {
                Text("not reported")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
            if let resetsAt = quota.resetsAt {
                Text(QuotaCountdown.phrase(until: resetsAt, from: now))
                    .font(Typo.micro)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 54, alignment: .trailing)
            }
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
                    // Clamped, because a provider reporting 103 percent of an overage allowance is
                    // a thing that happens and a lane wider than its track draws over the text.
                    .frame(width: proxy.size.width * min(max(quota.fraction ?? 0, 0), 1))
            }
        }
        .frame(height: height)
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
