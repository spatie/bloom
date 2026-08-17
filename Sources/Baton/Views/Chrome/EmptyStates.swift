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
                .font(.system(size: 32))
                .foregroundStyle(Palette.textTertiary)

            Text(title)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)

            Text(message)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Gives short background work a quiet, reusable treatment that does not dominate dense panes.
struct LoadingView: View {
    let label: String?

    init(_ label: String? = nil) {
        self.label = label
    }

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)

            if let label {
                Text(label)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

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

                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .foregroundStyle(Palette.negative)
            .padding(Metrics.gutter)
            .background(Palette.negative.opacity(0.12), in: RoundedRectangle(cornerRadius: Metrics.corner))
        }
    }
}
