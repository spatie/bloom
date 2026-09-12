import SwiftUI
import BloomCore
import BloomUI

/// What the user asked for, as one side of a conversation.
///
/// A filled bubble in the brand blue, with light text, drawn the way iMessage draws the messages
/// you sent. It replaced a near white plate with a hairline around it, which sat on a near white
/// transcript and separated from the reply under it by almost nothing: you scrolled past your own
/// question without noticing it went by. A fill is the cheapest thing that says "this half is
/// yours" without adding a second border to a column that already has enough lines in it.
///
/// **Only this side is bubbled, and that is deliberate.** The agent's replies stay unbubbled prose
/// and must not be "finished off" later. iMessage works because both sides are a sentence long. An
/// agent turn is paragraphs, tool rows, code blocks and a footer, and wrapping that in a tinted
/// plate would put a box around ninety percent of the window, cap prose at the bubble's measure and
/// leave the tool rows either inside a bubble they do not belong in or outside one, breaking the
/// column they align on. The asymmetry IS the design: one side is a remark, the other is a report.
///
/// Files attached to the turn are drawn as the same chips the composer showed a moment before it
/// was sent, rather than as the list of paths the agent was handed. The agent needs paths in the
/// text and always will, but the reader already knows what they attached and a scratch path under
/// `.bloom/attachments` tells them nothing they did not know. See `AttachmentTrailer` for the one
/// place that format is written and read.
///
/// Instructions Bloom appended to a turn it composed itself are drawn the same way, as a chip
/// where the block sits, and hovering one shows the words the agent was given. They used to be a
/// button under the bubble with a popover behind a click, next to a pull request's instructions
/// which were a pill in the sentence with a card on hover: one thing, drawn twice, and only one of
/// the two answered the pointer. See `SentTurn` for the cut and `InlineChip` for the chip that
/// takes either a file or a body.
struct UserTurnRowView: View {
    var text: String
    /// The files this turn carried, worktree relative, in the order they were attached.
    var attachments: [String] = []
    /// The review comments this turn carried, when `ReviewTurn.split` recognised it as one. The
    /// bubble then shows `text` as the typed message and one chip per comment, the way the
    /// composer showed them a moment before the send.
    var reviewChips: [ReviewTurnRecord.Chip] = []
    /// Which worktree those paths are relative to, and which review the chips open into.
    var home: TranscriptHome

    @Environment(AppModel.self) private var app
    /// The list's one value, set in `TranscriptListView`, rather than actions built per bubble:
    /// a fresh pair of closures on every pass is churn the row's AppKit text view then has to
    /// swallow on each update.
    @Environment(\.markdownLinkActions) private var linkActions
    /// What the conversation is set at, which face it is in and how far apart its lines are,
    /// because the bubble now resolves a real `NSFont` and a real paragraph style rather than
    /// handing SwiftUI a rung and a modifier to resolve for themselves.
    @Environment(\.fontScale) private var fontScale
    @Environment(\.chatFont) private var chatFont
    @Environment(\.chatLineHeight) private var chatLineHeight
    /// Where a hovered chip says it is, so the card is drawn over the scroll view rather than
    /// inside a bubble that would clip it. See `TranscriptHoverOverlay`.
    @Environment(\.transcriptHoverHost) private var hoverHost
    /// The width this bubble may fill, read from the object the list hands down rather than from a
    /// number the list passes in. See `TranscriptBubbleWidth`: reading it HERE is what keeps a pane
    /// being made narrower from invalidating every tool row in the session.
    @Environment(\.transcriptBubbleWidth) private var bubbleWidth

    /// What a bubble drawn outside a transcript is capped at, which is every use of this view that
    /// is not the list: nothing else puts one up today, and a bubble with no cap at all would run
    /// the full width of whatever it landed in.
    ///
    /// Not private, for the reason `inset` above gives: `PendingTurnRowView` draws the same bubble
    /// in a different state and had a copied 560 of its own.
    static let uncappedFallback = BloomBubbleMetrics.maximumWidth

    private var maxWidth: CGFloat { bubbleWidth?.cap ?? Self.uncappedFallback }

    /// The pill inside the sentence the pointer is currently on, reported by `LinkTextView` the
    /// moment it arrives. Nil for every bubble nobody is pointing at, which is what keeps the
    /// probe below and the timer beside it off every other row in the transcript.
    @State private var hovered: FileChipHover?
    /// Where the sentence is in the window, read only while a pill in it is under the pointer. See
    /// `chipProbe`.
    @State private var textFrame: CGRect = .zero
    @State private var hoverTask: Task<Void, Never>?
    /// The card this bubble put up, if it is still up. Recorded rather than recomputed, exactly as
    /// `ToolRowHeader` records its own: what has to be taken down is what was PUT up, and the
    /// pointer crossing from one chip to the next raises the second before the first is told it
    /// was left.
    @State private var published: TranscriptHoverCard?

    /// How much of the pane a user turn always leaves empty on its left, so it reads as one side of
    /// a conversation even when it is short.
    ///
    /// This and the two below are not private, and `CappedWidth` at the foot of the file is not
    /// either, because `PendingTurnRowView` draws the same object in a different state and every
    /// number it uses has to be this one. A copied 12 is a bubble that stops matching the moment
    /// somebody changes one of them.
    static let inset = BloomBubbleMetrics.leadingSpace

    /// The bubble's radius, which is its own number rather than `Metrics.corner`.
    ///
    /// Six is the radius of a control: a button, a chip, the composer's box. A speech bubble is not
    /// a control, and at six a filled one reads as a coloured button with a paragraph in it. Twice
    /// that is the roundness the shape wants and is still short of the pill iMessage draws, which
    /// on a Mac full of six point corners would look borrowed rather than chosen.
    ///
    /// Local on purpose: `Metrics` is where radii live and this is a candidate to move there as
    /// `Metrics.cornerBubble` the moment anything else needs it. Nothing else does yet.
    static let corner = BloomBubbleMetrics.corner

    /// Air inside the fill. Wider than the plate it replaces, because a hairline lets text sit
    /// close to the edge and a fill does not: on a coloured ground the words need to look placed
    /// in it rather than pressed against the side of it.
    static let padding = BloomBubbleMetrics.padding

    var body: some View {
        BloomUserBubble(maxWidth: maxWidth, fill: Palette.accentFill) {
            bubble.environment(\.isOnEmphasizedSelection, true)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
        .onChange(of: hovered) { _, chip in
            hoverTask?.cancel()
            guard home.remoteWorkspaceID == nil else { return }
            guard let chip else {
                withdraw()
                return
            }
            let wanted = card(for: chip.subject)
            hoverTask = Task {
                try? await Task.sleep(for: Motion.hoverCardDelay)
                // Zero only if the probe has not been laid out yet, which would put the card in
                // the pane's top left corner. Saying nothing beats saying it in the wrong place.
                guard !Task.isCancelled, textFrame != .zero else { return }
                publish(wanted, at: chip.frame.offsetBy(dx: textFrame.minX, dy: textFrame.minY))
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            withdraw()
        }
    }

    /// The words and then the files, which is the order they were written in and the order the
    /// composer showed them in, except that up there the chips sat above the text because that is
    /// where the row of them lives. Here the sentence comes first: it is what the turn is about.
    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.block) {
            // A prompt of nothing but attachments is a turn in its own right, and an empty `Text`
            // above the chips would put a blank line inside the bubble.
            if !text.isEmpty {
                let font = Typo.body.resolvedNSFont(scale: fontScale, face: chatFont)
                // Written text, not markdown. A question with a `*` in it is a question with a
                // `*` in it, and two things only are lifted out of it: an address, found by
                // `LinkScan`, and a file, found by `FileMention`. Both rules live in the core
                // where they are tested, and both are the same rules the agent's own prose goes
                // through.
                //
                // Drawn by AppKit rather than by `Text`, and that is the whole of why
                // `TranscriptTextView` exists: a link inside a selectable `Text` is decoration.
                // Measured on a real window, the cursor over one was an I-beam and a press routed
                // nothing at all. See the note on that type.
                    TranscriptTextView(
                    text: TranscriptLink.attributedString(
                        sent: text,
                        font: font,
                        // White, the same ink a selected row uses on the same fill. Measured 5.2
                        // to 1 on Spatie Blue, which passes AA for body text in both appearances.
                        color: .alternateSelectedControlTextColor,
                        // The reader's line height, and handing it in is also what keeps the
                        // bubble's own cache honest: `SentTurnKey` is keyed on this number, so a
                        // step just moved is a miss rather than a bubble redrawn at the old one.
                        lineSpacing: TranscriptLayout.proseLeading(
                            Typo.body, scale: fontScale, face: chatFont, lineHeight: chatLineHeight
                        ),
                        chipGround: .userBubble
                    ),
                    linkColor: NSColor(Palette.linkInverted),
                    // The measured value from the note above: on the dark ramp the selection is a
                    // muted slate that sits clearly on Spatie Blue and leaves white text alone.
                    // AppKit cannot read the `colorScheme` this bubble sets, so it is named.
                    selectionColor: Palette.bubbleTextSelection,
                    alignsBubbleInk: true,
                    actions: linkActions.opening(
                        file: open, hovering: { hovered = $0 },
                        previewing: { home.remoteWorkspaceID == nil ? PromptAttachment.sent(path: $0).url(in: home.worktree) : nil }
                    )
                )
                .background { chipProbe }
            }

            if !reviewChips.isEmpty {
                ReviewTurnChips(chips: reviewChips, home: home)
            }

            if !attachments.isEmpty {
                // The composer's own flow layout, so a turn carrying eight files wraps them the
                // same way the box did rather than pushing the bubble off the pane.
                ChipFlow(spacing: Metrics.spacingSmall, lineSpacing: Metrics.spacingSmall) {
                    ForEach(attachments, id: \.self) { path in
                        AttachmentChip(
                            attachment: .sent(path: path),
                            worktree: home.worktree,
                            onOpen: { open(path) },
                            onPreview: { frame in preview(path, frame) },
                            // No warning triangle on a turn that has already gone. The composer
                            // drops an attachment whose file has vanished in the moment before it
                            // sends, and `PullRequestInstructions.ensure` looks at its own file
                            // before naming it, so every path in a sent prompt was a readable file
                            // when the agent was handed it. What the probe can still find out
                            // afterwards is that the file has since been deleted, moved, reclaimed
                            // into the scratch folder or taken away with the worktree when the
                            // workspace was archived, and none of that is a fault in the turn. The
                            // row is a record of what was asked, not a picker. See
                            // `AttachmentChip.verifiesOnDisk`, and `ToolRowHeader`, which draws the
                            // agent's own file chips the same way a few lines further down the
                            // same transcript.
                            verifiesOnDisk: false
                        )
                    }
                }
            }
        }
    }

    /// A chip opens where every other file in Bloom opens, which is the review tab, and it is the
    /// same door the composer's chips use. The model is looked up rather than passed down: the
    /// transcript is handed a session, not a workspace model, and `existingModel` only reads.
    private func open(_ path: String) {
        if home.remoteWorkspaceID != nil {
            app.remoteServer.openFile(path)
            app.isInspectorVisible = true
            return
        }
        // No workspace is Ask Bloom, which has no review pane for a file to open into. The chip
        // still draws and still previews, which is what a path in that conversation is for.
        guard let id = home.workspaceID, let model = app.existingModel(for: id) else { return }
        FileReview.open(path: path, in: model)
    }

    /// Where the sentence sits in the window, measured only while a pill in it is under the
    /// pointer.
    ///
    /// The pill reports its own frame in the text view's coordinates, because AppKit measures from
    /// the bottom of a window and SwiftUI from the top, and the one number that reconciles them is
    /// where SwiftUI thinks this view is. Reading it behind every bubble would be a read per
    /// bubble per layout pass, on the list that re-lays out on every frame of a sidebar drag;
    /// behind the hovered one it is nothing at all for the rest. It is up well before it is
    /// needed: `Motion.hoverCardDelay` is a third of a second and this is a layout pass.
    @ViewBuilder
    private var chipProbe: some View {
        if hoverHost != nil, hovered != nil {
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    textFrame = $0
                }
        }
    }

    /// What the card is asked for.
    ///
    /// For a file, `FileChipTarget` is the rule, in the core, and it is the same call a tool row's
    /// chip makes: a path inside the worktree is shown relative to it, and one outside keeps the
    /// absolute path it arrived with and is resolved against nothing.
    ///
    /// A file that has since been deleted still gets a card, and the card says so: `AttachmentPreview`
    /// draws "it is gone" for a path with nothing behind it. That is deliberately the same answer a
    /// tool row gives, and it is the honest one here, because a sent turn is a record of what was
    /// asked rather than a picker. See `AttachmentChip.verifiesOnDisk`.
    ///
    /// For a block Bloom put in the message there is nothing to resolve and nothing to ask the disk:
    /// the words are in the turn this bubble is drawn from, so a transcript read back out of the
    /// database answers exactly as one still on screen does. See `InstructionsCard`.
    private func card(for subject: InlineChip) -> TranscriptHoverCard {
        switch subject {
        case .file(let path):
            let target = FileChipTarget.resolve(path, in: home.worktree)
            return .file(attachment: .sent(path: target.path), worktree: target.worktree)
        case .instructions(let block):
            return .instructions(title: block.title, body: block.body)
        }
    }

    /// The same card the composer showed while the file was being attached, drawn over the
    /// transcript instead of over the box. A bubble cannot hold it: it is a plate a few hundred
    /// points wide inside a lazy stack inside a scroll view, and it would be clipped at the first
    /// edge it met.
    ///
    /// This is the trailer's chips, which are laid out by SwiftUI and measure themselves, so they
    /// arrive with a window frame already in hand and need none of the timing above.
    private func preview(_ path: String, _ frame: CGRect?) {
        guard home.remoteWorkspaceID == nil else { return }
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

    /// Takes this bubble's card down, and only its own.
    ///
    /// The comparison is what makes the hide immediate AND safe. The pointer crossing from one
    /// chip to the next raises the new card before the old chip has been told it was left, so a
    /// bare `request = nil` would sometimes clear the card that had just gone up.
    private func withdraw() {
        defer { published = nil }
        guard let published, hoverHost?.request?.card == published else { return }
        hoverHost?.request = nil
    }
}

extension TranscriptLinkActions {
    /// The list's shared actions with a door for file chips added, and a way for one of them to
    /// say the pointer is on it.
    ///
    /// A copy per bubble rather than a fourth closure on the list's one value, because opening a
    /// file needs the workspace and the list is handed a session. It costs one struct on the rows
    /// that draw a bubble, which is a handful in a transcript of hundreds.
    ///
    /// Both closures at once because both need the same thing the list cannot give: the workspace,
    /// for the door and for the worktree the card resolves against. A value that has one always
    /// has the other, which is why `identity` gains no third case for the pair.
    @MainActor
    func opening(
        file open: @escaping @MainActor @Sendable (String) -> Void,
        hovering hover: @escaping @MainActor @Sendable (FileChipHover?) -> Void,
        previewing preview: @escaping @MainActor @Sendable (String) -> URL?
    ) -> TranscriptLinkActions {
        var copy = self
        copy.openFile = open
        copy.hoverFile = hover
        copy.previewFile = preview
        // The identity moves with the closure, or a bubble that can open a file would compare
        // equal to the list's value that cannot, and the environment would never see the change.
        if case let .workspace(id, pane) = identity {
            copy.identity = .workspaceOpeningFiles(id, pane: pane)
        }
        return copy
    }
}

// Queued messages use the same measured layout as sent messages.
typealias CappedWidth = BloomUI.CappedWidth
