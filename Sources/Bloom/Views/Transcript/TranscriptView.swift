import SwiftUI

/// The transcript: the surface where a user watches an agent work.
///
/// This is only the shell around the optional. Everything that scrolls lives in
/// `TranscriptListView`, so a pane with no session behind it never builds a scroll view at all.
struct TranscriptView: View {
    private let transcript: TranscriptModel?
    /// Passed through to explain an empty transcript while a workspace is still being set up.
    private let isRunningSetup: Bool

    /// Told whenever the user leaves, or returns to, the live end of the transcript. The composer
    /// uses it to decide whether a "jump to newest" pill is worth offering.
    private let onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)?

    init(
        transcript: TranscriptModel,
        isRunningSetup: Bool = false,
        onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.transcript = transcript
        self.isRunningSetup = isRunningSetup
        self.onScrolledUpChange = onScrolledUpChange
    }

    /// The call site holds an optional and should not have to unwrap it just to show an empty pane,
    /// so the optional case is an overload rather than the caller's problem.
    init(
        transcript: TranscriptModel?,
        isRunningSetup: Bool = false,
        onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.transcript = transcript
        self.isRunningSetup = isRunningSetup
        self.onScrolledUpChange = onScrolledUpChange
    }

    var body: some View {
        Group {
            if let transcript {
                TranscriptListView(
                    transcript: transcript,
                    isRunningSetup: isRunningSetup,
                    onScrolledUpChange: onScrolledUpChange
                )
            } else {
                EmptyTranscriptView()
            }
        }
        .background(Palette.surface)
    }
}
