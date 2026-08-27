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
    /// Takes this one out of the queue and puts its words back in the composer. No question first:
    /// nothing is lost, so a dialog would only be in the way. See `PendingMessageEdit`.
    var onEdit: @MainActor () -> Void
    /// Asks to delete this one. It asks rather than deletes: the confirmation and the promise
    /// about where the sentence ends up are `PendingMessageDiscard`'s, through `TranscriptModel`.
    var onDelete: @MainActor () -> Void
    /// The width this bubble may fill. Read from the list's object rather than handed in, for the
    /// reason `TranscriptBubbleWidth` sets out: a number passed in is a number the list has to
    /// read, and a list that reads it is a list that is rebuilt whenever the pane changes width.
    @Environment(\.transcriptBubbleWidth) private var bubbleWidth
    /// Draws the row as though the pointer were on it, for `--snapshot`. An offscreen render has
    /// no pointer, and the state worth photographing here is the one under it.
    var pointerInside = false

    @State private var isHovered = false

    private var isPointedAt: Bool { isHovered || pointerInside }

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

    /// A queued review turn is drawn as what was asked rather than as the rendered prompt: the
    /// typed words and a count. The full text goes to the agent untouched; only the drawing of
    /// the wait is summarised, the same bargain the sent bubble makes with its chips.
    private var displayText: String {
        guard let review = ReviewTurn.split(delivery.body) else { return delivery.body }
        let count = review.chips.count
        let suffix = "\(count) review comment\(count == 1 ? "" : "s") attached"
        return review.message.isEmpty ? suffix : "\(review.message)\n\(suffix)"
    }

    private var bubble: some View {
        CappedWidth(width: bubbleWidth?.cap ?? UserTurnRowView.uncappedFallback) {
            Text(displayText)
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
    /// **Both are drawn at rest and light up under the pointer**, where Delete used to be drawn at
    /// opacity zero until the pointer arrived. The owner asked for the ability to delete a pending
    /// message that the app already had, which is what a control nobody can see amounts to. At
    /// rest it is the tertiary ink of the sentence beside it, so the row reads as one caption
    /// rather than as a button somebody left on every bubble; under the pointer it takes the link
    /// colour, which is the app's word for "this does something".
    ///
    /// Nothing moves when the pointer arrives, which was already true and stays true for a
    /// stronger reason: it is the same view at two tints rather than a view appearing. The opacity
    /// it used to fade was there for exactly this and is gone with the fade.
    ///
    /// **The two controls are last in the row and the row carries no trailing padding**, so their
    /// right edge is the enclosing `VStack`'s trailing edge, which is the bubble's. Nothing here
    /// re-states the alignment: one container aligns both, and the two edges agree by
    /// construction. The bubble's outline is a `strokeBorder`, which draws inside the frame rather
    /// than astride it, so the frame edge really is the edge you can see.
    ///
    /// The sentence was last and the words Edit and Delete led the row, which put two pieces of
    /// prose in one caption competing to be read first. The marks are the things you act on, so
    /// they take the edge under the bubble's own corner; the sentence, when there is one, explains
    /// from the left.
    ///
    /// **Marks rather than the words.** "Edit" and "Delete" set in caption beside a sentence in
    /// the same size and the same resting ink read as three pieces of prose, and the reader has to
    /// tell which two of them are pressable. A pencil and a bin are the two most legible glyphs in
    /// the system for exactly these, and each keeps the sentence it had as its tooltip and its
    /// accessibility label, so nothing is lost to somebody who cannot read a glyph.
    @ViewBuilder
    private var caption: some View {
        HStack(spacing: Metrics.gutter) {
            if let sentence = hold?.sentence {
                Text(sentence)
                    .foregroundStyle(Palette.textTertiary)
            }

            // First, because it is the safer of the two and the one wanted more often. Offered
            // only for a message the composer could actually be handed back as text, which is
            // `PendingMessageEdit.canEdit`: a disabled button with no explanation says less than
            // no button at all.
            if PendingMessageEdit.canEdit(delivery) {
                action(
                    "pencil",
                    label: "Edit",
                    help: "Takes this message back into the composer to change it.",
                    run: onEdit
                )
            }

            action(
                "trash",
                label: "Delete",
                help: "Takes this message back out of the queue. It is not sent.",
                run: onDelete
            )
        }
        .font(Typo.caption)
    }

    /// Not `linkButton()`, and not `.link` with a tint of its own: measured on this SDK,
    /// `.buttonStyle(.link)` paints the system link colour whatever `.tint` says, so the resting
    /// state came out the same blue as the pointed-at one and the whole point of the two states
    /// was lost. A plain button takes the colour it is given, and `.pointerStyle` puts back the
    /// one thing the link style was buying.
    private func action(
        _ symbol: String, label: String, help: String, run: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPointedAt ? Palette.link : Palette.textTertiary)
        .pointerStyle(.link)
        .help(help)
        .accessibilityLabel(label)
    }
}
