import SwiftUI

/// One readout in the header's strip: a count, what it counts, and the tint that says whether a
/// machine is dealing with it or the user has to.
struct HomeCount: Identifiable {
    var id: String { text }
    var text: String
    var systemImage: String
    var tint: Color
}

/// The line at the top of Home: who you are, what every project adds up to right now, and the one
/// button that starts work.
///
/// The counts are set as plain tinted labels rather than as filled pills, for the reason the
/// sidebar's status bar gives: a pill in a header reads as a control, and clicking these does
/// nothing. They are a readout of what the cards below already say, gathered into one line so the
/// answer is there before any scrolling happens.
struct HomeWelcomeHeader: View {
    var greeting: String
    var summary: String
    var counts: [HomeCount]
    var onCreateWorkspace: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSection) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(greeting)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(Palette.textPrimary)

                if counts.isEmpty {
                    Text(summary)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    strip
                }
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

    /// One line where the pane is wide enough for one, two where it is not.
    ///
    /// An `HStack` alone truncated every part of it at once on a narrow window, so the header read
    /// "15 workspa… 5 need…", which is worse than saying nothing. `ViewThatFits` takes the first
    /// arrangement whose ideal width is offered, and the last candidate stacks the counts so the
    /// strip degrades by getting taller rather than by losing its words.
    /// No line limit anywhere below, on purpose. `ViewThatFits` measures each candidate at its
    /// ideal width, which for a `Text` is the whole string on one line whether or not wrapping is
    /// allowed, so the arrangement is chosen the same way either way; what changes is that the
    /// arrangement it settles on wraps rather than truncating in the middle of "workspaces".
    private var strip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.spacingWide) {
                summaryText
                countLabels(separated: true)
            }

            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                summaryText
                HStack(spacing: Metrics.spacingSection) {
                    countLabels(separated: false)
                }
            }

            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                summaryText
                countLabels(separated: false)
            }
        }
        .font(Typo.body)
    }

    private var summaryText: some View {
        Text(summary).foregroundStyle(Palette.textSecondary)
    }

    /// The separator belongs to the one-line arrangement only. Stacked, a leading interpunct is
    /// a bullet the line does not need and the reader has to skip past.
    @ViewBuilder
    private func countLabels(separated: Bool) -> some View {
        ForEach(counts) { count in
            if separated {
                Text(verbatim: "\u{00B7}")
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)
            }

            Label(count.text, systemImage: count.systemImage)
                .foregroundStyle(count.tint)
        }
    }
}
