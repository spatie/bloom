import SwiftUI
import BloomCore

/// The same wait the file loader draws, held back until it is a wait somebody can feel.
///
/// It is `LoadingView` centred in whatever it is given, which is exactly how `FilePreview`,
/// `FileEditPane`, `ChangedFileList` and `DiffView` all say "reading". Nothing new is drawn here
/// and nothing is styled here: a second way of waiting in one window is how a window stops
/// looking like one app. What this adds to those four is the delay, and only the delay.
///
/// The rule is `SlowWait`, in the core, with its tests. See the head of that file for why half a
/// second and not none: almost every switch in this window is over inside three frames, and a
/// spinner for that is a flicker, which reads as a fault rather than as progress.
///
/// # The task, and the two ways it has to end
///
/// One `.task(id:)` keyed on what is being waited for, which is the pattern `TranscriptListView`
/// and `ChatPaneView` already key their own work on. SwiftUI cancels it when the subject changes
/// and when the view goes away, so the content arriving and the pane being torn down are the same
/// ending and neither leaves a timer running. `Task.isCancelled` after the sleep is therefore the
/// honest reading of "the wait is over", and it is what is handed to the rule.
///
/// No transition, on purpose. If it appears, it should appear: fading a spinner in over 300ms
/// would mean the pane still shows nothing at 800ms, which is the wait this is meant to answer,
/// twice over.
struct SlowLoadingView<Subject: Equatable & Sendable>: View {
    /// What the pane has nothing to draw for, and nil when it has something. The delay starts
    /// again whenever this changes, so a second switch mid wait gets its own quiet half second
    /// rather than inheriting what was left of the first one's.
    var subject: Subject?
    /// The sentence under the spinner, in the register the file loader uses: what is being read.
    var label: String?

    /// The subject the delay has run out for, rather than a plain flag, so an answer left over
    /// from the previous subject cannot draw for the current one.
    @State private var showing: Subject?

    var body: some View {
        Group {
            if let subject, showing == subject {
                LoadingView(label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: subject) { await announceIfSlow() }
    }

    private func announceIfSlow() async {
        showing = nil
        guard let subject, let quiet = SlowWait.quiet() else { return }
        // A monotonic clock rather than `Date`, because this measures an elapsed half second and
        // the wall clock is free to move under it.
        let clock = ContinuousClock()
        let began = clock.now
        try? await clock.sleep(for: quiet)
        guard SlowWait.isShowing(waited: began.duration(to: clock.now), isOver: Task.isCancelled)
        else { return }
        showing = subject
    }
}
