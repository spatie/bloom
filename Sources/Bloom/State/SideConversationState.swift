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
}
