import SwiftUI
import AppKit

/// One attached file: the icon Finder would draw for it, then its name.
///
/// Drawn twice, above what you are typing and again in the turn once it has been sent, and it is
/// deliberately one view. The chips in a sent prompt are the same files the reader chose a moment
/// earlier, and a second implementation of the same label is how the two stop looking alike.
///
/// The name only. A path in a chip is a path in the composer again, which is the thing this
/// replaces, and the folder an attachment came from is never the interesting part: the reader
/// dropped it a second ago and the hover card and the tab both say where it went.
///
/// Drawn on two very different grounds. Above the text field it sits on the composer's sunken
/// grey; inside a sent turn it sits on the filled blue bubble `UserTurnRowView` draws. The second
/// case is read from `isOnEmphasizedSelection`, the same environment value a selected sidebar row
/// sets, so the chip needs to know nothing about either caller: on the fill it becomes a light
/// plate with light ink, exactly as `Chip` and `DiffStatLabel` already do on the same colour. A
/// chip that kept its raised white plate and its primary ink would be the one thing in the bubble
/// still coloured for a white page, and it is the piece a reader looks straight at.
///
/// Hovering swaps the icon for the close control rather than adding one beside it, which is what
/// Conductor does and is worth copying: the chip keeps exactly the width it had, so a row of them
/// does not reflow under the pointer and the thing you were aiming at stays where it was. The slot
/// is a fixed square for that reason, not because the two glyphs happen to be the same size.
struct AttachmentChip: View {
    var attachment: PromptAttachment
    var worktree: String
    var onOpen: @MainActor () -> Void
    /// Nil where there is nothing to take the chip off, which is a turn that has already been
    /// sent: the prompt the agent read named that file, so the transcript cannot un-name it. The
    /// icon then stays an icon rather than swapping under the pointer.
    var onRemove: (@MainActor () -> Void)?
    /// Raised once the pointer has settled, and lowered the moment it leaves. Nil where nobody is
    /// listening, which costs the chip its hover timer rather than running one for no reader.
    var onHover: (@MainActor (Bool) -> Void)?

    @State private var isHovered = false
    @State private var isMissing = false
    @State private var hoverTask: Task<Void, Never>?

    /// True inside a sent user turn, where the ground is the accent fill rather than the page.
    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    /// Shorter than a list row: this is a label above the text field, and at 28 points a row of
    /// them read as a second toolbar. Not private: the bar reads it to know how tall one row of
    /// chips is before it has measured any.
    static let height: CGFloat = 22
    /// The icon, and the close control that replaces it.
    private static let slot: CGFloat = 14
    /// Enough for a name like `Screenshot 2026-08-19 at 14.03.11.png` to be recognisable once it
    /// is truncated in the middle, and short enough that four chips fit across a narrow column.
    private static let maxNameWidth: CGFloat = 150
    /// How long the pointer has to rest before the card opens. Short enough to feel like hovering,
    /// long enough that crossing the row on the way to the send button shows nothing.
    private static let hoverDelay = Duration.milliseconds(350)

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            leading

            Text(attachment.filename)
                .font(Typo.caption)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.maxNameWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    // Amber is a warning colour picked to be seen on the page's ground, and on the
                    // blue fill it is the one saturated mark in the turn. The chip is already
                    // saying "missing" in the shape of the glyph, so on the fill it says it in the
                    // fill's own ink instead.
                    .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : Palette.warning)
                    .help("This file is no longer on disk")
            }
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(plate)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(stroke, lineWidth: Metrics.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .onTapGesture(perform: onOpen)
        .onHover(perform: hover(_:))
        .help(attachment.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.filename)
        .accessibilityHint("Opens \(attachment.path) in a tab")
        .task(id: attachment.path) {
            isMissing = !FileManager.default.fileExists(atPath: url.path)
        }
        .onDisappear { hoverTask?.cancel() }
    }

    // MARK: Ground

    /// The plate under the chip. On the accent fill it is the same twenty percent of the inverted
    /// ink `Chip` uses there, which reads as a lighter patch of the bubble rather than as a white
    /// card sitting on top of it. Hover lifts it by a further tenth.
    private var plate: Color {
        guard isOnSelection else {
            return isHovered ? Palette.hover : Palette.surfaceRaised
        }
        return Palette.selectedEmphasizedText.opacity(isHovered ? 0.3 : 0.2)
    }

    /// A hairline in the page's border colour disappears into the fill, so on the accent the edge
    /// is drawn in the same ink as the label, kept faint enough to stay an edge.
    private var stroke: Color {
        isOnSelection ? Palette.selectedEmphasizedText.opacity(0.35) : Palette.border
    }

    /// A file that is no longer on disk is said quietly rather than in a different hue, which is
    /// what `textTertiary` does on the page and what three quarters of the inverted ink does here.
    private var nameColor: Color {
        guard isOnSelection else {
            return isMissing ? Palette.textTertiary : Palette.textPrimary
        }
        return isMissing
            ? Palette.selectedEmphasizedText.opacity(0.75)
            : Palette.selectedEmphasizedText
    }

    @ViewBuilder
    private var leading: some View {
        if isHovered, let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: Self.slot, height: Self.slot)
                    .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : Palette.textSecondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove \(attachment.filename)")
            .accessibilityLabel("Remove \(attachment.filename)")
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: Self.slot, height: Self.slot)
                .accessibilityHidden(true)
        }
    }

    private var url: URL { attachment.url(in: worktree) }

    private func hover(_ hovering: Bool) {
        isHovered = hovering
        hoverTask?.cancel()

        guard let onHover else { return }
        guard hovering else {
            onHover(false)
            return
        }
        hoverTask = Task {
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled else { return }
            onHover(true)
        }
    }
}
