import SwiftUI
import Observation

/// What a transcript draws in the card that floats over it while the pointer rests on something.
///
/// Two kinds, and they are the same question asked about two different things: "what is that,
/// really". A chip names a file and the card shows the file. A tool row states what it did on one
/// line, that line is cut to fit the row, and the card puts it back.
///
/// One type rather than two hosts and two overlays, because one pointer can only rest on one
/// thing: making them separate would mean two popovers that could be up at once, over each other,
/// and two copies of the measure-then-present dance in `TranscriptHoverOverlay`.
enum TranscriptHoverCard: Equatable {
    /// A file a chip names, drawn by Quick Look. `worktree` is empty for a file outside it, whose
    /// path is already absolute.
    case file(attachment: PromptAttachment, worktree: String)
    /// A tool row's own line, put back whole. Everything here is already in hand: it is the
    /// `ToolPresentation` the row is drawn from, so the card asks nothing of the row it belongs to
    /// and nothing of the disk. `isCode` travels with the detail so the card sets the line in the
    /// face the row set it in, rather than deciding a second time and disagreeing.
    case row(title: String, detail: String, isCode: Bool)

    /// What a measurement of this card was taken FOR, so a size left over from the last one is
    /// never handed to the next. See `TranscriptHoverOverlay.Measurement`.
    var identity: String {
        switch self {
        case .file(let attachment, _): "file:" + attachment.path
        case .row(let title, let detail, let isCode):
            "row:" + title + "\u{0}" + detail + "\u{0}" + (isCode ? "code" : "prose")
        }
    }
}

/// The one thing a transcript is showing a card for, and where the thing is.
struct TranscriptHoverRequest: Equatable {
    var card: TranscriptHoverCard
    /// The chip's or the row's frame in window coordinates, which is the only space a row deep
    /// inside a `LazyVStack` and the view drawing the card can both name.
    var frame: CGRect
}

/// What a chip or a row anywhere in a transcript tells, and what the card at the top of the
/// transcript listens to.
///
/// A shared object rather than a closure handed down through five view layers, and rather than a
/// binding, for one reason each:
///
/// - A closure in the environment is a NEW closure every time the enclosing body runs, so every
///   row reading it would be invalidated by every pass over the list. An object's identity is
///   stable, so reading it costs a row nothing.
/// - Writing `request` from a row's hover callback registers no observation: observation is
///   recorded where a property is READ during a body, and a row never reads this. Only
///   `TranscriptHoverOverlay` reads it, so a hover redraws the card and nothing else.
///
/// It holds one request because one pointer can only be on one thing.
@MainActor
@Observable
final class TranscriptHoverHost {
    var request: TranscriptHoverRequest?
}

extension EnvironmentValues {
    /// Nil wherever no transcript is drawing a card, which is every other use of a file chip:
    /// the composer has its own, positioned against the box rather than against the pane.
    @Entry var transcriptHoverHost: TranscriptHoverHost?
}
