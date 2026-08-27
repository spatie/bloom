import SwiftUI

/// Carries one boolean out of a transcript's observation without the list's body reading it.
///
/// `TranscriptListView` has to tell `TranscriptLiveEndFollower` when an answer is arriving, and an
/// `onChange` value expression is evaluated inside the body it is written on. So the list held an
/// observation edge on `TranscriptModel.isStreaming`, and every change of it re-ran a body whose
/// `entries` is a pass over the whole session: on the owner's 2,981 row session that is three
/// thousand closures assembled twenty times a second to hand a boolean to an object nothing in
/// that body draws from.
///
/// Here the edge lands on a view with nothing behind it, so the pass costs what the boolean is
/// worth. The same narrowing as `StreamingTailView`, `TranscriptBubbleWidth` and
/// `TranscriptHoverHost`, and for the same reason.
///
/// Zero sized and unhittable on purpose: it is a subscription rather than something to look at, so
/// it goes in a `background` where it can neither take a click nor change what anything measures.
struct TranscriptStreamingSignal: View {
    let transcript: TranscriptModel
    let report: @MainActor (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: transcript.isStreaming, initial: true) { _, streaming in
                report(streaming)
            }
    }
}
