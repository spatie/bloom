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
            .padding(Metrics.spacingSmall)
        }
    }
}
