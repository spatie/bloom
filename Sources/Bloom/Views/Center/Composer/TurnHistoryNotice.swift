import SwiftUI
import BloomCore

struct TurnHistoryNotice: View {
    var transcript: TranscriptModel

    var body: some View {
        if let failure = transcript.history.failure {
            HStack(alignment: .top, spacing: Metrics.spacing) {
                Text(failure).font(Typo.caption).textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Dismiss") { transcript.history.failure = nil }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.spacingSmall)
            // The composer floats over the transcript, so a notice with no material of its own
            // drew its text straight across whatever row was scrolled behind it.
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .padding(.bottom, Metrics.spacingSmall)
        }
    }
}
