import Foundation

/// Whether the pull request strip may act on this workspace's branch right now.
///
/// **One answer for the whole strip, rather than one `if` per button.** Every control in that
/// band ends in the same place: a turn is composed and sent, and the agent then commits, pushes,
/// merges, cuts a fresh branch or brings the base in. So the question is asked once, here, and
/// the strip disables its action cluster on the answer. A button added to that cluster later is
/// disabled by the cluster rather than by remembering to ask, which is the failure this shape
/// exists to make impossible.
///
/// **Why a running agent is a no.** Merging while an agent is still writing to the worktree
/// merges a branch whose commits may not all be pushed yet, and it is the kind of mistake that
/// cannot be undone from inside the app: the commits land on somebody else's branch and the
/// branch they came from is deleted on the server. The rest of the band is the same mistake a
/// step short of the server. Commit and push publishes a worktree that is being written to as it
/// is read, Fix merge conflicts merges the base into that worktree, Continue cuts a new branch
/// out from under the turn, and Archive deletes the worktree entirely.
///
/// **This reverses an earlier decision, deliberately.** These buttons were live mid turn on the
/// argument that a press queues rather than refusing: the turn goes into the chat's queue, drawn
/// above the composer, and runs when the current one ends. That is a good answer for asking an
/// agent to do more work and a bad one for landing a branch, because what the reader saw when
/// they pressed is not what the queued turn will act on. The queue still exists and the composer
/// still uses it; the strip's branch actions wait instead.
///
/// Nothing that only navigates or reveals is covered by this. The pull request number, the arrow
/// out to the browser, Copy link and Share, the inspector's own tabs: none of them touches the
/// worktree, and a reader whose agent is working still wants to read.
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

    /// The one decision, for the whole strip.
    ///
    /// One parameter today. It is a function rather than a computed property on the flag because
    /// the next reason to hold the band back (a rebase in flight, a worktree being archived) is a
    /// second argument here and nothing at all at any call site.
    public static func mayActOnBranch(isAgentBusy: Bool) -> BranchActionAvailability {
        guard isAgentBusy else { return .allowed }
        return BranchActionAvailability(
            isAllowed: false,
            note: "The agent is still running here.",
            reason: "The agent is still running in this worktree. Merging or pushing now would "
                + "act on a branch whose commits may not all be pushed yet, and none of that can "
                + "be undone from in here. It comes back when the turn ends."
        )
    }
}
