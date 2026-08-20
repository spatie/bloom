import SwiftUI
import BloomCore

/// What the View link next to the logs checkbox opens: the excerpt itself, in full, exactly as it
/// would be sent.
///
/// **Not a sample and not a summary.** The string on screen is the same string the report carries,
/// produced by the same call, held by the same draft. That is the only thing that makes the
/// checkbox honest: a person is being asked to send their own log, so they have to be able to read
/// the whole of it first, scroll to the end of it, and copy it somewhere else if they want to look
/// harder.
///
/// Monospaced and selectable, because it is a log. There is no editing: what would be sent is what
/// Bloom read, and a box somebody could type into would raise the question of which version goes.
struct FeedbackLogSheet: View {
    var text: String
    var onClose: @MainActor () -> Void

    /// Tall enough to read a screenful of log at a time, short enough to sit inside the sheet it
    /// is opened from on a laptop screen.
    private static let height: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                Text(Feedback.Copy.logsTitle)
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)

                Text(Feedback.Copy.logsDetail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? AppLogExcerpt.empty : text)
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(Metrics.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.height)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.corner).strokeBorder(Palette.border)
            )

            HStack(spacing: Metrics.gutter) {
                Text(lineCount)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)

                Spacer(minLength: Metrics.gutter)

                Button("Copy") { Clipboard.copy(text) }
                    .disabled(text.isEmpty)

                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.pane)
        .frame(width: 700)
        .background(Palette.surface)
    }

    /// How much there is, said plainly. A person deciding whether to send their log wants to know
    /// whether it is four lines or two hundred before they start reading.
    private var lineCount: String {
        guard !text.isEmpty else { return "Nothing to send" }
        let lines = LogTail.lineCount(text)
        return lines == 1 ? "1 line" : "\(lines) lines"
    }
}
