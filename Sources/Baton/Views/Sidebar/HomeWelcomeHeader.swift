import SwiftUI

/// The line at the top of Home: who you are, what is waiting, and the one button that starts work.
struct HomeWelcomeHeader: View {
    var greeting: String
    var summary: String
    var onCreateWorkspace: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(Palette.textPrimary)
                Text(summary)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: 12)

            Button("New workspace", systemImage: "plus", action: onCreateWorkspace)
                .font(Typo.bodyEmphasis)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
    }
}
