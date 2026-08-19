import SwiftUI

/// One sentence in the corner of the window, saying something the app did on its own.
///
/// Deliberately not `ErrorBanner`. That one is red, it sits in the layout of the form that raised
/// it, and it stays until it is dismissed, because a failure that scrolls away is a failure nobody
/// acted on. This is the opposite kind of message: nothing went wrong, there is nothing to do, and
/// the only thing that would be worse than not saying it is saying it in a dialog.
///
/// It times out rather than waiting, and it can be dismissed early. It floats over the detail
/// column instead of taking part in the layout, so the window does not resize around a sentence
/// that is about to leave.
struct NoticeBanner: View {
    let notice: BloomNotice
    let onDismiss: () -> Void

    /// Long enough to read a sentence twice.
    private static let lifetime = Duration.seconds(12)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Image(systemName: "info.circle")
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text(notice.message)
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                // Worth pasting somewhere else, like every other message the app shows.
                .textSelection(.enabled)

            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.textSecondary)
                .help("Dismiss")
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacing)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(Metrics.gutter)
        .accessibilityElement(children: .combine)
        // Keyed on the notice's id, so a second notice arriving restarts the clock rather than
        // inheriting whatever was left of the first one's.
        .task(id: notice.id) {
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}
