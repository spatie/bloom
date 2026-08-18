import SwiftUI

/// Isolates token-by-token observation from the stored row list.
///
/// A stream delta changes several transcript properties many times per second. Keeping every read
/// of those properties in this wrapper means SwiftUI invalidates only the live tail instead of
/// rebuilding every visible stored row.
struct StreamingTailView: View {
    let transcript: TranscriptModel

    var body: some View {
        Group {
            if transcript.isRunning || transcript.isStreaming {
                StreamingRowView(transcript: transcript)
            }
        }
    }
}
