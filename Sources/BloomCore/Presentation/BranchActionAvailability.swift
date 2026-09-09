import Foundation

/// Whether the pull request strip may accept its current action while an agent is busy.
///
/// Create, push, merge and conflict resolution submit messages through the transcript's delivery
/// queue. They can be requested during a turn, just like a message typed into the composer.
/// Continue and Archive act on the worktree immediately, so a finished pull request still needs
/// an idle workspace before those controls become available.
public struct BranchActionAvailability: Sendable, Hashable {
    /// Whether the strip's branch actions may be pressed.
    public var isAllowed: Bool

    /// A few words for the strip's own line, where somebody reads it without hovering.
    ///
    /// Nil when acting is allowed, and then the strip keeps whatever it says about itself
    /// ("1 check passed", the branch's target). A disabled control that explains itself only on
    /// hover is a control most people never get an explanation from, so the reason takes the one
    /// line of text the band already has for as long as it is true.
    public var note: String?

    /// The whole of it, for the tooltip every disabled control in the band carries.
    public var reason: String?

    public init(isAllowed: Bool, note: String? = nil, reason: String? = nil) {
        self.isAllowed = isAllowed
        self.note = note
        self.reason = reason
    }

    /// Nothing in the way.
    public static let allowed = BranchActionAvailability(isAllowed: true)

    public static func mayActOnBranch(
        isAgentBusy: Bool,
        pullRequest: PullRequest?
    ) -> BranchActionAvailability {
        guard isAgentBusy, let pullRequest, !pullRequest.isOpen else { return .allowed }
        return BranchActionAvailability(
            isAllowed: false,
            note: "The agent is still running here.",
            reason: "The agent is still running in this worktree. Continue and Archive become "
                + "available when the turn ends."
        )
    }
}
