import AppKit
import BloomCore
import Foundation
import Observation

/// Owned by the workspace, not by its transient pane. Dismissing the overlay leaves the runner
/// and draft alive; archiving or quitting still tears it down with the other transcripts.
@MainActor
@Observable
final class SideConversationState {
    var transcript: TranscriptModel?
    var snapshot: SideConversation.Snapshot?
    var isVisible = false
    var isOpening = false
    var error: String?
    var pendingQuestion = ""
    @ObservationIgnored var task: Task<Void, Never>?
    /// The view behind the card, so a drag can ask where the card is in the window when it needs
    /// to and nothing has to track it while it animates. See `FileDropTarget`.
    @ObservationIgnored weak var cardAnchor: NSView?

    var windowFrame: CGRect { cardAnchor.map { $0.convert($0.bounds, to: nil) } ?? .zero }
}
