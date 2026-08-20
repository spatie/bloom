import SwiftUI

/// The whole of a tool row's line, shown while the pointer rests on a row that had to cut it.
///
/// A collapsed row is one line by design, which is the only reason a run of four hundred tool
/// calls can be watched at all, and one line means a long command or a deep path is truncated with
/// an ellipsis. The row is still the right shape; what was missing was any way to read the rest of
/// it without opening the row and losing your place in the list. So the pointer resting on a
/// truncated row puts the same two strings back, whole.
///
/// The same `MenuPanel` the file card sits in, because the two are one card that says two things
/// and a second material for the second thing is how a window stops looking like one window.
///
/// Text, not a picture of text, and not a tooltip. `.help` is what the row used to offer for this,
/// and a tooltip is the system's yellow strip: one line, no face of its own, and it arrives after
/// a delay macOS owns. The command is code and is set as code here, on the rung the transcript
/// sets code at everywhere else.
struct ToolRowCard: View {
    /// What the row said it did, which is the label a row leads with.
    var title: String
    /// What it did it to: a command, a path, a pattern. Already one line, and already capped at
    /// three hundred characters by `ToolPresenter.oneLine`, so nothing here can be asked to lay
    /// out a megabyte.
    var detail: String
    /// What the pane has to give, which is what the card may take.
    var availableWidth: CGFloat

    /// Wide enough for a shell command with a couple of flags on one line, and no wider: the card
    /// sits over the conversation, so it borrows that space rather than owning it. The same cap
    /// the file card uses, for the same reason.
    private static let maxWidth: CGFloat = 520
    private static let minWidth: CGFloat = 240

    var body: some View {
        MenuPanel {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(title)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)

                if !detail.isEmpty, detail != title {
                    Text(detail)
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        // Wrapped, and that is the difference between this card and `SourceLines`.
                        // That one refuses to wrap because a line of a FILE that soft wraps reads
                        // as different code. This is one line that was already cut once, and
                        // cutting it a second time at the card's edge would show exactly as much
                        // as the row did.
                        .textSelection(.disabled)
                }
            }
            // A definite width rather than a cap, because the overlay measures this card under
            // `fixedSize`, and a `Text` offered no width at all is one very long line: a
            // `maxWidth` frame would be honoured for the card and ignored by the text inside it.
            // The card only ever appears over a line that was too long for a row, so a width it
            // fills is the width it wants anyway.
            .frame(width: width, alignment: .leading)
            .padding(Metrics.inset)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var width: CGFloat {
        max(min(availableWidth - Metrics.gutter * 2, Self.maxWidth), Self.minWidth)
    }
}
