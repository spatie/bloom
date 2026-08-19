import SwiftUI
import BloomCore

/// The single line a tool call occupies while it is closed: what it did, to what, and how long it
/// took, on the columns every other row uses.
struct ToolRowHeader: View {
    var presentation: ToolPresentation
    /// Which worktree the row's paths are relative to, and which review a file chip opens into.
    var workspace: Workspace
    var isError: Bool
    var durationMS: Int?
    var isExpanded: Bool
    var isHovered: Bool

    /// The model is looked up rather than passed down, exactly as `UserTurnRowView` does it: the
    /// transcript is handed a session, not a workspace model, and this only ever reads. Nothing in
    /// `body` touches it, so no row observes it and no row is invalidated when it changes.
    @Environment(AppModel.self) private var app

    /// Where a hovered chip says it is, so the transcript can draw the preview card over the
    /// scroll view. Nil in any context that is not drawing one.
    @Environment(\.filePreviewHost) private var previewHost

    /// A chip that repeats the detail replaces it: `Read [notes.txt]` rather than
    /// `Read notes.txt [notes.txt]`.
    private var showsDetail: Bool {
        !presentation.detail.isEmpty && !presentation.chips.contains { $0.text == presentation.detail }
    }

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(
                symbol: presentation.glyph,
                tint: isError ? Palette.negative : presentation.tint
            )

            Text(presentation.label)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .transcriptLabelColumn()

            if showsDetail {
                Text(presentation.detail)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            // Deliberately not `fixedSize`: a row is one line tall and clips, so a chip that
            // refuses to give ground is cut in half at a narrow pane width rather than
            // truncated. `Chip` already holds itself to one line, and the detail beside it
            // carries the higher layout priority, so the chip only gives ground last.
            ForEach(Array(presentation.chips.enumerated()), id: \.offset) { _, chip in
                switch chip {
                case .code(let text):
                    Chip(text: text, monospaced: true)
                case .file(let path):
                    fileChip(path)
                }
            }

            Spacer(minLength: TranscriptLayout.tight)

            // Both of these are last in a row whose detail carries `layoutPriority`, so
            // without `fixedSize` the detail takes the slack and "error" wraps to "e" over "r"
            // inside a row that is one line tall by construction.
            if isError {
                Text("error")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
                    .fixedSize()
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
                previewHost?.request = frame.map {
                    FilePreviewRequest(attachment: attachment, worktree: worktree, frame: $0)
                }
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
