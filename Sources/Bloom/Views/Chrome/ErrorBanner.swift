import SwiftUI

/// Makes recoverable failures visible without forcing every caller to manage a separate alert.
///
/// Dismissal is the caller's, through `onDismiss` clearing whatever presents the banner. It used
/// to be a private flag in here, re-raised by an onChange of the message, and a retry that failed
/// with the identical sentence (the common case, since callers report fixed strings) changed
/// nothing, so the second failure was reported once and then silently swallowed.
struct ErrorBanner: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.negative)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(title)
                    .font(Typo.labelEmphasis)
                Text(message)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // An error in a developer tool is something you paste somewhere else.
            .textSelection(.enabled)

            Spacer(minLength: Metrics.gutter)

            Button("Dismiss", systemImage: "xmark", action: onDismiss)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.textSecondary)
            .help("Dismiss")
        }
        .padding(Metrics.gutter)
        .background(
            Palette.negative.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Metrics.corner)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
