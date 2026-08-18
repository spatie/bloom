import SwiftUI

/// Gives short background work a quiet, reusable treatment that does not dominate dense panes.
struct LoadingView: View {
    let label: String?

    init(_ label: String? = nil) {
        self.label = label
    }

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            ProgressView()

            if let label {
                Text(label)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        // One announcement rather than "progress indicator" followed by a stray sentence.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "Loading")
    }
}
