import SwiftUI
import BloomCore

/// A message the owner has asked for that has not gone to the agent yet.
///
/// **The same object as `UserTurnRowView` in a different state, and every number here is that
/// view's number rather than a new one.** Same inset from the left, same cap on the measure, same
/// corner radius, same padding inside the fill, same right hand side of the pane. What changes is
/// that the fill is not the accent: a bubble that is only outlined has not been said yet, which is
/// the whole message, and a pending turn that was drawn as a second style of plate would read as a
/// different kind of thing rather than as this one waiting.
///
/// The ground is `surfaceRaised` rather than a literal white. On the light ramp that IS white, so
/// it is the bubble the owner asked for; on the dark ramp white would be a hole burnt in the
/// window, and the raised surface is what "white" means there. The dots are the tertiary ink,
/// which is the one colour in the palette that stays clearly visible against both without
/// competing with the sentence inside it.
///
/// **This is not a `messages` row and never becomes one here**, which is the same safety property
/// `WorkspaceEvent`'s header sets out for the rows Bloom draws about a workspace. It is drawn from
/// the `deliveries` table; the agent is handed the sentence by the runner at the moment the queue
/// moves, and it is the runner that writes the row. Nothing an agent reads can contain a sentence
/// nobody has sent it. See `Delivery`.
struct PendingTurnRowView: View {
    var delivery: Delivery
    /// The sentence saying why the queue is waiting, under the last bubble in it and nowhere else.
    ///
    /// One sentence for the queue rather than one per message: four bubbles each explaining the
    /// same running turn is the same sentence four times. Under the last rather than the first,
    /// which is where it was: between two bubbles it read as a caption on the one below it, or as
    /// a divider somebody had left in. At the foot of the run it reads as what it is, which is a
    /// note about everything above it.
    var hold: DeliveryHold?
    var maxWidth: CGFloat
    var onCancel: @MainActor () -> Void

    @State private var isHovered = false

    /// `UserTurnRowView`'s three numbers, named here so a change to one of them is visibly a
    /// change to both drawings of the same object.
    private static let inset = UserTurnRowView.inset
    private static let corner = UserTurnRowView.corner
    private static let padding = UserTurnRowView.padding

    /// Short dashes with a gap wider than they are, which reads as dotted at a hairline and stays
    /// dotted when the conversation is set larger: the pattern is in points, not in ems, because
    /// the border is a border rather than a piece of text.
    private static let dots = StrokeStyle(lineWidth: Metrics.hairline, dash: [2, 3])

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Self.inset)

            VStack(alignment: .trailing, spacing: TranscriptLayout.tight) {
                bubble
                caption
            }
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
        .onHover { isHovered = $0 }
    }

    private var bubble: some View {
        CappedWidth(width: maxWidth) {
            Text(delivery.body)
                .font(Typo.body)
                .lineSpacing(TranscriptLayout.proseLeading)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                // No `maxWidth: .infinity`. `CappedWidth` measures the text at the cap and then
                // takes the width it actually used, and filling the proposal defeats exactly
                // that: three words came out in a bubble the full width of the pane with the
                // words floating at one end of it, while the sent bubble a line above hugged its
                // own sentence. Two drawings of one object have to agree about this.
                .padding(Self.padding)
        }
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Self.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(Palette.textTertiary, style: Self.dots)
        }
    }

    /// Why it is waiting, and the way out of it.
    ///
    /// Both in the caption size under the bubble rather than inside it, because neither is part of
    /// what was asked for: the bubble holds the owner's words and nothing else, so that the words
    /// look the same before and after they go.
    ///
    /// Cancel appears on hover and is announced always. A control that only exists under the
    /// pointer is invisible to anybody driving this with a keyboard or a screen reader, and
    /// withdrawing something you asked for is not a decoration.
    @ViewBuilder
    private var caption: some View {
        HStack(spacing: Metrics.gutter) {
            if let hold {
                Text(hold.sentence)
                    .foregroundStyle(Palette.textTertiary)
            }

            Button("Cancel", action: onCancel)
                .buttonStyle(.link)
                .help("Takes this message back out of the queue. It is not sent.")
                .opacity(isHovered ? 1 : 0)
                .accessibilityHidden(false)
        }
        .font(Typo.caption)
        .padding(.trailing, Self.padding.trailing)
    }
}
