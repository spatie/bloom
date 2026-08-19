import SwiftUI
import Observation

/// The one file a transcript is previewing, and where its chip is.
struct FilePreviewRequest: Equatable {
    var attachment: PromptAttachment
    /// Empty for a file outside the worktree, whose path is already absolute.
    var worktree: String
    /// The chip's frame in window coordinates, which is the only space a row deep inside a
    /// `LazyVStack` and the view drawing the card can both name.
    var frame: CGRect
}

/// What a chip anywhere in a transcript tells, and what the card at the top of the transcript
/// listens to.
///
/// A shared object rather than a closure handed down through five view layers, and rather than a
/// binding, for one reason each:
///
/// - A closure in the environment is a NEW closure every time the enclosing body runs, so every
///   row reading it would be invalidated by every pass over the list. An object's identity is
///   stable, so reading it costs a row nothing.
/// - Writing `request` from a row's hover callback registers no observation: observation is
///   recorded where a property is READ during a body, and a row never reads this. Only
///   `FilePreviewOverlay` reads it, so a hover redraws the card and nothing else.
///
/// It holds one request because one pointer can only be on one chip.
@MainActor
@Observable
final class FilePreviewHost {
    var request: FilePreviewRequest?
}

extension EnvironmentValues {
    /// Nil wherever no transcript is drawing a card, which is every other use of a file chip:
    /// the composer has its own, positioned against the box rather than against the pane.
    @Entry var filePreviewHost: FilePreviewHost?
}
