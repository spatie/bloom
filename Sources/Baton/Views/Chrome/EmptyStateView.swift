import SwiftUI

/// Keeps low-information screens visually consistent so every feature does not invent its own placeholder.
struct EmptyStateView: View {
    let glyph: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        glyph: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: Metrics.gutter) {
            Image(systemName: glyph)
                .font(Typo.title)
                .imageScale(.large)
                .foregroundStyle(Palette.textTertiary)

            Text(title)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)

            Text(message)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
