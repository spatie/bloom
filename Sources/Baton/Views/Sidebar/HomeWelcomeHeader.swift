import SwiftUI

/// The line at the top of Home: who you are, what is waiting, and the one button that starts work.
struct HomeWelcomeHeader: View {
    var greeting: String
    var summary: String
    var onCreateWorkspace: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSection) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(greeting)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(Palette.textPrimary)
                Text(summary)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: Metrics.gutter)

            // No `font` of its own. A large bordered button already picks the weight and size
            // AppKit uses at that control size, and overriding it desynchronised the label from
            // the capsule drawn around it.
            Button("New workspace", systemImage: "plus", action: onCreateWorkspace)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
    }
}
