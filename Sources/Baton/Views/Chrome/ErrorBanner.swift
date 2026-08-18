import SwiftUI

/// Makes recoverable failures visible without forcing every caller to manage a separate alert.
struct ErrorBanner: View {
    let title: String
    let message: String

    @State private var isVisible = true

    var body: some View {
        Group {
            if isVisible {
                banner
            }
        }
        // A banner sitting in a fixed slot keeps its view identity, so a second failure after a
        // dismissal never reappeared: the view was still mounted, still hidden. The handler has
        // to sit outside the branch, or it is not attached while the banner is dismissed.
        .onChange(of: message) { _, _ in isVisible = true }
    }

    private var banner: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.negative)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(title)
                    .font(Typo.labelEmphasis)
                Text(message)
                    .font(Typo.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Metrics.gutter)

            Button("Dismiss", systemImage: "xmark") {
                isVisible = false
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
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
