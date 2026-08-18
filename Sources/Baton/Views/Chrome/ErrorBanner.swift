import SwiftUI

/// Makes recoverable failures visible without forcing every caller to manage a separate alert.
struct ErrorBanner: View {
    let title: String
    let message: String

    @State private var isVisible = true

    var body: some View {
        if isVisible {
            HStack(alignment: .top, spacing: Metrics.gutter) {
                Image(systemName: "exclamationmark.triangle.fill")

                VStack(alignment: .leading, spacing: Metrics.cornerSmall) {
                    Text(title)
                        .font(Typo.labelEmphasis)
                    Text(message)
                        .font(Typo.label)
                }

                Spacer(minLength: Metrics.gutter)

                Button("Dismiss", systemImage: "xmark") {
                    isVisible = false
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
            }
            .foregroundStyle(Palette.negative)
            .padding(Metrics.gutter)
            .background(Palette.hover, in: RoundedRectangle(cornerRadius: Metrics.corner))
        }
    }
}
