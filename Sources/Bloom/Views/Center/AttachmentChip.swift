import SwiftUI
import AppKit

/// One attached file, as it appears above what you are typing: the icon Finder would draw for it,
/// then its name.
///
/// The name only. A path in a chip is a path in the composer again, which is the thing this
/// replaces, and the folder an attachment came from is never the interesting part: the reader
/// dropped it a second ago and the hover card and the tab both say where it went.
///
/// Hovering swaps the icon for the close control rather than adding one beside it, which is what
/// Conductor does and is worth copying: the chip keeps exactly the width it had, so a row of them
/// does not reflow under the pointer and the thing you were aiming at stays where it was. The slot
/// is a fixed square for that reason, not because the two glyphs happen to be the same size.
struct AttachmentChip: View {
    var attachment: PromptAttachment
    var worktree: String
    var onOpen: @MainActor () -> Void
    var onRemove: @MainActor () -> Void
    /// Raised once the pointer has settled, and lowered the moment it leaves.
    var onHover: @MainActor (Bool) -> Void

    @State private var isHovered = false
    @State private var isMissing = false
    @State private var hoverTask: Task<Void, Never>?

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
                .foregroundStyle(isMissing ? Palette.textTertiary : Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.maxNameWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(Palette.warning)
                    .help("This file is no longer on disk")
            }
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(isHovered ? Palette.hover : Palette.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
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

    @ViewBuilder
    private var leading: some View {
        if isHovered {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: Self.slot, height: Self.slot)
                    .foregroundStyle(Palette.textSecondary)
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
