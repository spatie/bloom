import SwiftUI
import BloomCore

/// The single line a tool call occupies while it is closed: what it did, to what, and how long it
/// took, on the columns every other row uses.
struct ToolRowHeader: View {
    var presentation: ToolPresentation
    /// Which worktree the row's paths are relative to, and which review a file chip opens into.
    var workspace: Workspace
    var isError: Bool
    /// Set when the call never ran, which the protocol reports with the same `is_error` a real
    /// failure carries. See `ToolRefusal`.
    var refusal: ToolRefusal?
    /// The sentence the CLI gave for the refusal, in one line.
    var refusalReason: String = ""
    var durationMS: Int?
    var isExpanded: Bool
    var isHovered: Bool

    /// The model is looked up rather than passed down, exactly as `UserTurnRowView` does it: the
    /// transcript is handed a session, not a workspace model, and this only ever reads. Nothing in
    /// `body` touches it, so no row observes it and no row is invalidated when it changes.
    @Environment(AppModel.self) private var app

    /// Where a hovered chip or row says it is, so the transcript can draw the card over the
    /// scroll view. Nil in any context that is not drawing one.
    @Environment(\.transcriptHoverHost) private var hoverHost

    /// Whether each half of the line is being cut off, answered by `TruncationProbe` and only
    /// while this row is the hovered one. Both start false, which is what every row that is not
    /// under the pointer stays.
    @State private var titleIsCut = false
    @State private var detailIsCut = false
    /// Where this row is, read once the pointer is on it. See `frameProbe`.
    @State private var frameInWindow: CGRect = .zero
    @State private var hoverTask: Task<Void, Never>?
    /// The card this row put up, if it is still up. Recorded rather than recomputed, because what
    /// has to be taken down is what was PUT up: a row that is opened while its card is showing
    /// would compute a different one and leave the old card standing over a row that has already
    /// answered the question.
    @State private var published: TranscriptHoverCard?

    /// How long the pointer has to rest on a row before its card opens. The same wait
    /// `AttachmentChip` makes for the file card, so the two cards in this pane answer at the same
    /// speed rather than at two speeds a reader would have to learn.
    private static let hoverDelay = Duration.milliseconds(350)

    /// A chip that repeats the detail replaces it: `Read [notes.txt]` rather than
    /// `Read notes.txt [notes.txt]`.
    ///
    /// And an open row replaces it too. Every expanded body states the target in full, in the face
    /// it deserves: a command as a code block, a path as a path, an edit as a before and after. The
    /// header's copy is the same string truncated to one line, so an open Bash row printed its
    /// command twice, once directly above the other. The full one is the one worth keeping.
    private var showsDetail: Bool {
        !isExpanded
            && !presentation.detail.isEmpty
            && !presentation.chips.contains { $0.text == presentation.detail }
    }

    /// The face the detail is set in.
    ///
    /// A shell command was set in the proportional face while the permission panel four points
    /// below it set the same command in mono, and the panel is the one that was right: a command is
    /// read character by character, and `-rf` beside `-r f` is exactly the difference a
    /// proportional face hides. So anything `ToolLiteral` calls a literal is code here, and
    /// anything it does not (the sentence a subagent was given, a phrase somebody would say out
    /// loud, a count of todos) stays proportional, because English set in mono reads as data.
    ///
    /// A rung DOWN from the label beside it, not the same rung, and the difference is characters on
    /// the row. Mono is the wider face at a given size, so the preview shows fewer of them however
    /// this is done. Measured on the 154 character `gh api ... --jq` command from the screenshot
    /// that prompted this, at a 480 point detail column: 81 characters in the proportional face it
    /// used to be set in, 70 at `codeSmall`, 64 at `code`. Losing a fifth of the line to make it
    /// legible is a bad trade; losing an eighth is not, and what is left is a line whose characters
    /// can be told apart, which is the whole reason for the change. `codeTiny` fits 77, near enough
    /// to break even, and is refused: ten points is the floor of the scale and is documented for a
    /// count or a duration read off the thing beside it, not for the longest string on the row.
    ///
    /// It is also exactly the pairing `ToolRowCard` already used, so the row and the card that puts
    /// the cut line back are now set the same way rather than two ways.
    private var detailFont: ScaledFont {
        presentation.detailIsCode ? Typo.codeSmall : Typo.label
    }

    /// What the row says happened, in the slot where a failure says "error".
    ///
    /// A refusal is drawn in the caution colour rather than the alarm one, and it keeps the
    /// detail beside it: the command that was declined is the thing the user needs to see, so the
    /// CLI's sentence goes in the tooltip and into the accessible label rather than displacing it.
    /// Every one of these rows opens onto the full sentence and what to do about it.
    private var outcome: (text: String, tint: Color, help: String)? {
        if let refusal {
            var sentence = refusalReason.isEmpty ? refusal.summary : refusalReason
            // The CLI's sentences are not all punctuated: "This command requires approval" has no
            // full stop, and running the remedy straight onto it read as one run-on line.
            if let last = sentence.last, !".!?:".contains(last) { sentence += "." }
            return (
                refusal.label,
                Palette.warning,
                [sentence, refusal.remedy].compactMap { $0 }.joined(separator: " ")
            )
        }
        if isError {
            return ("error", Palette.negative, "The tool reported an error. Open the row for what it said.")
        }
        return nil
    }

    var body: some View {
        // Read once for the pass. Working it out punctuates a sentence and joins two more, and the
        // glyph's tint at the top of this stack and the word near the bottom of it both need it.
        let outcome = outcome

        return HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(
                symbol: presentation.glyph,
                // The outcome's colour wins where there is one, and the presentation's role
                // becomes one here. See `ToolTint`: which role a tool row carries is a decision
                // in the core, and this is where it stops being one.
                tint: outcome?.tint ?? presentation.tint.colour
            )

            // A rung below the prose beside it, and in the secondary colour, because that is the
            // whole hierarchy of this pane: what the agent wrote is the content, and what it ran
            // is the receipt. Set in medium at reading size it was the loudest thing in the
            // window, and forty of them in a row buried the answer underneath. Quieter, not
            // smaller: it is still the label column of a row that has to be scannable, and the
            // size it drops to is the one every other label in the window is set at.
            Text(presentation.label)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .transcriptLabelColumn()
                .reportsTruncation(
                    of: presentation.label,
                    font: Typo.label,
                    isActive: wantsMeasuring,
                    into: $titleIsCut
                )

            if showsDetail {
                Text(presentation.detail)
                    .font(detailFont)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .reportsTruncation(
                        of: presentation.detail,
                        font: detailFont,
                        isActive: wantsMeasuring,
                        into: $detailIsCut
                    )
            }

            // Deliberately not `fixedSize`: a row is one line tall and clips, so a chip that
            // refuses to give ground is cut in half at a narrow pane width rather than
            // truncated. `Chip` already holds itself to one line, and the detail beside it
            // carries the higher layout priority, so the chip only gives ground last.
            ForEach(presentation.chips.indices, id: \.self) { index in
                switch presentation.chips[index] {
                case .code(let text):
                    Chip(text: text, monospaced: true)
                case .file(let path):
                    fileChip(path)
                }
            }

            Spacer(minLength: TranscriptLayout.tight)

            // Both of these are last in a row whose detail carries `layoutPriority`, so
            // without `fixedSize` the detail takes the slack and the outcome word wraps to "e"
            // over "r" inside a row that is one line tall by construction.
            //
            // The outcome is set in medium, which it was not before the coloured rule down the
            // left of the row was taken away. That word and the glyph's tint are now the whole of
            // what says a call failed or was declined, so the word carries a little more weight
            // than the duration it sits next to.
            if let outcome {
                Text(outcome.text)
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(outcome.tint)
                    .fixedSize()
                    .help(outcome.help)
                    .accessibilityLabel(outcome.help)
            }

            if let durationMS, durationMS > 0 {
                Text(TurnDuration.short(durationMS))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }

            TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
        }
        .transcriptRowFrame()
        .background { frameProbe }
        .onChange(of: showsCard) { _, wants in
            hoverTask?.cancel()
            guard wants else {
                withdraw()
                return
            }
            let wanted = card
            hoverTask = Task {
                try? await Task.sleep(for: Self.hoverDelay)
                // Zero only if the probe has not been laid out yet, which would put the card in
                // the pane's top left corner. Saying nothing beats saying it in the wrong place.
                guard !Task.isCancelled, frameInWindow != .zero else { return }
                published = wanted
                hoverHost?.request = TranscriptHoverRequest(card: wanted, frame: frameInWindow)
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            withdraw()
        }
    }

    // MARK: The row's own card

    /// Whether the truncation probes should be measuring, which is while the pointer is on a
    /// closed row and somewhere there is a card to draw.
    ///
    /// An open row is excluded rather than merely uninteresting. Every expanded body states the
    /// target in full, in the face it deserves, so there is nothing a card could add, and the
    /// header of an open row has already dropped its detail for exactly that reason.
    private var wantsMeasuring: Bool {
        hoverHost != nil && isHovered && !isExpanded
    }

    /// And whether there is something worth showing: a card that repeated a line the row was
    /// already showing whole would be a card for nothing.
    private var showsCard: Bool {
        wantsMeasuring && (titleIsCut || detailIsCut)
    }

    private var card: TranscriptHoverCard {
        .row(
            title: presentation.label,
            detail: showsDetail ? presentation.detail : "",
            isCode: presentation.detailIsCode
        )
    }

    /// Takes the card down, and only this row's own.
    ///
    /// The comparison is what makes the hide immediate AND safe. The pointer crossing from one row
    /// to the next raises the new row before the old one has been told it was left, so a bare
    /// `request = nil` would sometimes clear the card the row below had just put up.
    private func withdraw() {
        defer { published = nil }
        guard let published, hoverHost?.request?.card == published else { return }
        hoverHost?.request = nil
    }

    /// Where the row is, measured only while the pointer is on it.
    ///
    /// Reading a frame behind every row of a transcript would be a read per row per layout pass,
    /// on the list that re-lays out on every frame of a sidebar drag. Behind the hovered row alone
    /// it is one row's worth of reads, for the one row that is about to be asked where it is.
    ///
    /// The whole row rather than the label inside it: the row is what the pointer is on, what the
    /// hover plate lights, and the thing the card is about. AppKit centres the popover under the
    /// anchor and flips it above when there is no room below, which is what a row in the last turn
    /// always needs.
    @ViewBuilder
    private var frameProbe: some View {
        if wantsMeasuring {
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    frameInWindow = $0
                }
        }
    }

    /// A file the call was about, drawn as the chip the composer draws and the sent turn repeats.
    ///
    /// The one thing this has to work out is where the chip goes when it is clicked. An agent
    /// writes absolute paths, because Claude Code requires one on every read, and the review
    /// resolves a path against the worktree, so the two are reconciled here. A file in another
    /// checkout, in the home directory or in a temporary folder has nowhere to open: it is still
    /// drawn, because it is still a file, and it simply does not answer to the pointer.
    ///
    /// `AttachmentChip` truncates its own name in the middle at 150 points, so `fixedSize` here
    /// asks for the width of the name and no more rather than letting the chip stretch into the
    /// slack the row's `Spacer` would otherwise have taken.
    ///
    /// The chip's own tap gesture rather than a `Button` around it, which is not the house habit
    /// and is deliberate. The whole header is already a `Button`, and a nested one is folded into
    /// its label: with the chip wrapped, the row read to VoiceOver as "Read, 420ms" and the file
    /// it was about disappeared from the tree entirely. Unwrapped, the name lands in the row's
    /// combined label exactly the way the monospace chips beside it already do, which is the
    /// behaviour this change should not have altered.
    private func fileChip(_ path: String) -> some View {
        let inside = FilePathGuess.relative(path, to: workspace.path)
        let attachment = PromptAttachment.sent(path: inside ?? path)
        let worktree = inside == nil ? "" : workspace.path
        // Spelled out rather than mapped over the optional, so the closure's actor is written down
        // rather than inferred through two layers of optional.
        let onOpen: (@MainActor () -> Void)?
        if let inside {
            onOpen = { open(inside) }
        } else {
            onOpen = nil
        }

        // The two things a transcript wants turned off: no close control to reveal, since a row is
        // a record of what happened rather than a draft, and nothing asked of the file system,
        // since there are hundreds of these in a turn. See `AttachmentChip.verifiesOnDisk`.
        return AttachmentChip(
            attachment: attachment,
            worktree: worktree,
            onOpen: onOpen,
            onPreview: { frame in
                let file = TranscriptHoverCard.file(attachment: attachment, worktree: worktree)
                guard let frame else {
                    if hoverHost?.request?.card == file { hoverHost?.request = nil }
                    return
                }
                hoverHost?.request = TranscriptHoverRequest(card: file, frame: frame)
            },
            verifiesOnDisk: false
        )
        .fixedSize()
    }

    /// The same door the composer's chips and a sent turn's chips use.
    private func open(_ path: String) {
        guard let model = app.existingModel(for: workspace.id) else { return }
        FileReview.open(path: path, in: model)
    }
}
