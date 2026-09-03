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
    /// Where attachment paths resolve and which workspace opens when a pill is clicked.
    var home: TranscriptHome = .init()
    /// The sentence saying why the queue is waiting, under the last bubble in it and nowhere else.
    ///
    /// One sentence for the queue rather than one per message: four bubbles each explaining the
    /// same running turn is the same sentence four times. Under the last rather than the first,
    /// which is where it was: between two bubbles it read as a caption on the one below it, or as
    /// a divider somebody had left in. At the foot of the run it reads as what it is, which is a
    /// note about everything above it.
    var hold: DeliveryHold?
    /// Whether the message is at the front of an idle queue after a failed start.
    var canRetry = false
    /// Attempts this queued message again without adding a duplicate to the queue.
    var onRetry: @MainActor () -> Void = {}
    /// Whether this one may be sent in place of the turn that is running. `DeliverySteer` is
    /// where that is decided; the row is only told the answer.
    var canSteer = false
    /// Stops the running turn and sends this message into the space it makes. No question first,
    /// for Edit's reason and one more: what it interrupts is on screen above it, still writing.
    var onSteer: @MainActor () -> Void = {}
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
    @Environment(AppModel.self) private var app
    @Environment(\.markdownLinkActions) private var linkActions
    @Environment(\.fontScale) private var fontScale
    @Environment(\.chatFont) private var chatFont
    @Environment(\.chatLineHeight) private var chatLineHeight
    @Environment(\.transcriptHoverHost) private var hoverHost
    /// Draws the row as though the pointer were on it, for `--snapshot`. An offscreen render has
    /// no pointer, and the state worth photographing here is the one under it.
    var pointerInside = false

    @State private var isHovered = false
    @State private var hovered: FileChipHover?
    @State private var textFrame: CGRect = .zero
    @State private var hoverTask: Task<Void, Never>?
    @State private var published: TranscriptHoverCard?

    private var isPointedAt: Bool { isHovered || pointerInside }

    /// `UserTurnRowView`'s three numbers, named here so a change to one of them is visibly a
    /// change to both drawings of the same object.
    private static let inset = UserTurnRowView.inset
    private static let corner = UserTurnRowView.corner
    private static let padding = UserTurnRowView.padding

    /// Short dashes with a gap wider than they are, which reads as dotted at a hairline and stays
    /// dotted when the conversation is set larger: the pattern is in points, not in ems, because
    /// the border is a border rather than a piece of text.
    private static let dots = StrokeStyle(lineWidth: Metrics.outline, dash: [2, 3])

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
        .onChange(of: hovered) { _, chip in
            hoverTask?.cancel()
            guard let chip else {
                withdraw()
                return
            }
            let wanted = card(for: chip.subject)
            hoverTask = Task {
                try? await Task.sleep(for: Motion.hoverCardDelay)
                guard !Task.isCancelled, textFrame != .zero else { return }
                publish(wanted, at: chip.frame.offsetBy(dx: textFrame.minX, dy: textFrame.minY))
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            withdraw()
        }
    }

    /// A queued review turn is drawn as what was asked rather than as the rendered prompt: the
    /// typed words and a count. The full text goes to the agent untouched; only the drawing of
    /// the wait is summarised, the same bargain the sent bubble makes with its chips.
    private var displayText: String {
        guard let review = ReviewTurn.split(delivery.body) else {
            return attachmentTurn.body
        }
        let count = review.chips.count
        let suffix = "\(count) review comment\(count == 1 ? "" : "s") attached"
        return review.message.isEmpty ? suffix : "\(review.message)\n\(suffix)"
    }

    private var bubble: some View {
        CappedWidth(width: bubbleWidth?.cap ?? UserTurnRowView.uncappedFallback) {
            VStack(alignment: .leading, spacing: TranscriptLayout.block) {
                if !displayText.isEmpty {
                    TranscriptTextView(
                        text: TranscriptLink.attributedString(
                            sent: displayText,
                            font: Typo.body.resolvedNSFont(scale: fontScale, face: chatFont),
                            color: NSColor(Palette.textSecondary),
                            lineSpacing: TranscriptLayout.proseLeading(
                                Typo.body,
                                scale: fontScale,
                                face: chatFont,
                                lineHeight: chatLineHeight
                            ),
                            chipGround: .composer
                        ),
                        linkColor: NSColor(Palette.link),
                        selectionColor: .selectedTextBackgroundColor,
                        actions: linkActions.opening(file: open, hovering: { hovered = $0 })
                    )
                    .background { chipProbe }
                }

                if !attachmentTurn.paths.isEmpty {
                    ChipFlow(spacing: Metrics.spacingSmall, lineSpacing: Metrics.spacingSmall) {
                        ForEach(attachmentTurn.paths, id: \.self) { path in
                            AttachmentChip(
                                attachment: .sent(path: path),
                                worktree: home.worktree,
                                onOpen: { open(path) },
                                onPreview: { frame in preview(path, frame) },
                                verifiesOnDisk: false
                            )
                        }
                    }
                }
            }
            // No `maxWidth: .infinity`. `CappedWidth` measures the contents at the cap and then
            // takes the width they actually use, matching the sent bubble above it.
            .padding(Self.padding)
        }
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Self.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(Palette.textTertiary, style: Self.dots)
        }
    }

    private var attachmentTurn: (body: String, paths: [String]) {
        AttachmentTrailer.split(delivery.body)
    }

    private func open(_ path: String) {
        guard let id = home.workspaceID, let model = app.existingModel(for: id) else { return }
        FileReview.open(path: path, in: model)
    }

    /// `UserTurnRowView.card(for:)`, for the same chips before the turn has gone. A queued merge
    /// request carries the same block a sent one does, and it reads the same way here.
    private func card(for subject: InlineChip) -> TranscriptHoverCard {
        switch subject {
        case .file(let path):
            let target = FileChipTarget.resolve(path, in: home.worktree)
            return .file(attachment: .sent(path: target.path), worktree: target.worktree)
        case .instructions(let block):
            return .instructions(title: block.title, body: block.body)
        }
    }

    @ViewBuilder
    private var chipProbe: some View {
        if hoverHost != nil, hovered != nil {
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    textFrame = $0
                }
        }
    }

    private func preview(_ path: String, _ frame: CGRect?) {
        guard let frame else {
            withdraw()
            return
        }
        publish(card(for: .file(path: path)), at: frame)
    }

    private func publish(_ card: TranscriptHoverCard, at frame: CGRect) {
        published = card
        hoverHost?.request = TranscriptHoverRequest(card: card, frame: frame)
    }

    private func withdraw() {
        defer { published = nil }
        guard let published, hoverHost?.request?.card == published else { return }
        hoverHost?.request = nil
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
    /// **The control is last in the row and the row carries no trailing padding**, so its right
    /// edge is the enclosing `VStack`'s trailing edge, which is the bubble's. Nothing here
    /// re-states the alignment: one container aligns both, and the two edges agree by
    /// construction. The bubble's outline is a `strokeBorder`, which draws inside the frame rather
    /// than astride it, so the frame edge really is the edge you can see.
    ///
    /// The sentence was last and the words Edit and Delete led the row, which put two pieces of
    /// prose in one caption competing to be read first. The mark is the thing you act on, so it
    /// takes the edge under the bubble's own corner; the sentence, when there is one, explains
    /// from the left.
    ///
    /// **One mark rather than three.** The words became a pencil, a bin and a turn arrow, on the
    /// grounds that three pieces of caption prose leave the reader working out which are
    /// pressable. Three glyphs in a row solved that and bought a different complaint, which was
    /// made: too much furniture under a message whose whole job is to say it is waiting. They are
    /// behind one circled ellipsis now, and the words are back where a menu can carry them. See
    /// `moreMenu`, which also answers the old argument about where Steer had to sit.
    @ViewBuilder
    private var caption: some View {
        HStack(spacing: Metrics.gutter) {
            if let sentence = hold?.sentence {
                Text(sentence)
                    .foregroundStyle(Palette.textTertiary)
            }

            if canRetry {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.link)
                    .pointerStyle(.link)
                    .help("Try to send this message again.")
            }

            moreMenu
        }
        .font(Typo.caption)
    }

    /// The three things you can do to a queued message, behind one mark.
    ///
    /// **They were three marks in a row and that was too much furniture for a queued message.**
    /// A pencil, a bin and a turn arrow are each legible on their own, and side by side under a
    /// bubble they are three targets and three decisions on a row whose whole job is to say that
    /// a message is waiting. Reported as visually heavy, and it was.
    ///
    /// One circled ellipsis instead, which is the mark this app already uses for "more about this
    /// row": `WorkspaceRow.moreMenu` in the sidebar. Read its notes before changing the styling
    /// here, because both lines below were measured rather than chosen. `.menuStyle(.button)`
    /// with `.buttonStyle(.plain)` is what makes a menu take the ink it is given; `.borderlessButton`
    /// paints its own and ignores the colour wherever it is stated.
    ///
    /// **The words come back.** A glyph had to carry the whole meaning while these sat in a row,
    /// so each one wore its sentence as a tooltip nobody sees until they hover. In a menu the item
    /// is the word, which is what a reader wanted in the first place, and the sentence stays
    /// beside it as the help.
    ///
    /// Steer's argument about position is answered rather than kept: it was placed first so that
    /// a turn ending could not shuffle the pencil and the bin under a hand already reaching for
    /// them. Nothing shuffles now. The mark is in the same place whether one item is offered or
    /// three, and only the contents of the menu change.
    private var moreMenu: some View {
        Menu {
            // A turn arrow rather than a stop sign or a paper plane: the action is neither of its
            // two halves on its own, and what it means is "this way instead".
            if canSteer {
                Button("Steer", systemImage: "arrow.turn.up.right", action: onSteer)
                    .help("Stops the turn that is running and sends this message now.")
            }

            // Offered only for a message the composer could be handed back as text, which is
            // `PendingMessageEdit.canEdit`: a disabled item with no explanation says less than no
            // item at all.
            if PendingMessageEdit.canEdit(delivery) {
                Button("Edit", systemImage: "pencil", action: onEdit)
                    .help("Takes this message back into the composer to change it.")
            }

            Button("Delete", systemImage: "trash", action: onDelete)
                .help("Takes this message back out of the queue. It is not sent.")
        } label: {
            Label("More for this message", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .imageScale(.medium)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(isPointedAt ? Palette.link : Palette.textTertiary)
        .pointerStyle(.link)
        .help("Steer, edit or delete this queued message")
    }
}
