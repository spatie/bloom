import SwiftUI

/// Isolates token-by-token observation from the stored row list.
///
/// A stream delta changes several transcript properties many times per second. Keeping every read
/// of those properties in this wrapper means SwiftUI invalidates only the live tail instead of
/// rebuilding every visible stored row.
struct StreamingTailView: View {
    let transcript: TranscriptModel
    var hasCompletedTurn = false

    var body: some View {
        Group {
            // The result footer replaces the activity slot in the same pass. Waiting for the
            // runner to stop briefly draws both and then collapses the transcript a second time.
            if !hasCompletedTurn, transcript.isStreaming || transcript.sending != nil || transcript.isRunning {
                StreamingRowView(transcript: transcript)
                    .padding(.bottom, TranscriptLayout.block)
            } else {
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
    }
}
