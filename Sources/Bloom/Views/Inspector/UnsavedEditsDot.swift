import SwiftUI

/// The dot that says Edit mode is holding text the disk has not got.
///
/// Its own view, and it asks the session itself rather than being handed the answer, because
/// `FileEditSession.drafts` is one `@Observable` dictionary and observation is per stored property
/// rather than per key. A bar that read `isDirty` from its own body was invalidated by every
/// keystroke in the editor beside it, which is written down in `SharedDiff` as the reason the
/// share text is rendered on export. `FileHeaderBar` is the bar in question and it holds a
/// `ViewThatFits` over three clusters of seven controls, so every character typed measured all
/// three of them. Asked here, a keystroke redraws a five point circle.
struct UnsavedEditsDot: View {
    var session: FileEditSession
    /// The file's absolute path, which is what `FileEditSession` keys on.
    var path: String

    var body: some View {
        if session.isDirty(path) {
            Circle()
                .fill(Palette.accent)
                .frame(width: Metrics.dot, height: Metrics.dot)
                .help("Unsaved changes")
                .accessibilityLabel("Unsaved changes")
        }
    }
}
