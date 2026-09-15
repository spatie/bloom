import Foundation

/// The brake on two agents talking to each other for ever.
///
/// ## The failure it is for
///
/// Each message starts a turn, and an agent that has been told "answer with workspace_say" answers
/// every message, including "thanks". Two of them in two workspaces make a loop that costs two
/// turns a round, runs while nobody is watching, and never ends by itself. Nothing in the envelope
/// can talk a model out of it, because each side is doing what it was told.
///
/// ## The numbers
///
/// Six messages from one workspace to one other in ten minutes. A real exchange is an ask, an
/// answer, perhaps a follow up and a correction: four, spread over the minutes a turn takes. A
/// loop sends a message every turn, which is one every thirty seconds to two minutes, so it hits
/// six well inside the window, and the owner has lost at most six turns a side when it stops.
/// Counted per direction, so the side that is answering is braked separately from the side that
/// is asking.
///
/// The same words twice inside the window are refused outright, because that is the loop's other
/// shape: a model retrying a message it believes did not arrive, or two agents trading the same
/// status line.
///
/// Counted from `workspace_messages`, not from memory, so a restart does not reset it. Cancelled
/// messages do not count: the owner took them back, and an agent should not be braked for a
/// message that never went.
public enum WorkspaceSayThrottle {
    /// How many messages one workspace may send one other inside `window`.
    public static let limit = 6
    /// The rolling window both rules look back over.
    public static let window: TimeInterval = 10 * 60

    /// Why this message may not go, or nil. `recent` is what the same source has sent the same
    /// target; anything outside the window or cancelled is ignored here, whatever the query did.
    public static func refusal(
        sending text: String, to workspace: String, recent: [WorkspaceMessage], now: Date = Date()
    ) -> WorkspaceSayTrouble? {
        let since = now.addingTimeInterval(-window)
        let counted = recent.filter { $0.state != .cancelled && $0.createdAt >= since }

        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if counted.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == words }) {
            return .repeated(workspace: workspace)
        }
        if counted.count >= limit {
            return .tooMany(workspace: workspace, count: counted.count)
        }
        return nil
    }
}
