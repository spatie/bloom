import Foundation

/// Whether Bloom answers a permission question about one of its own tools without asking anybody.
///
/// ## Why this exists
///
/// Bloom's bridge tools reach the agent as MCP tools, and an MCP tool call goes through the CLI's
/// permission machinery like any other. Measured on a real run: the first `workspace_start` in a
/// project stopped the parent's turn on an ask, and with nobody watching the turn sat waiting and
/// died `cancelled` when the app quit, having started nothing. A feature whose first use hangs
/// unless somebody happens to be looking at that workspace is a feature that does not work.
///
/// ## Why answering it is not a shortcut round consent
///
/// Bloom is on both ends of this question. It wrote the tool, it minted the token the caller is
/// using, it knows which workspace is asking, and it enforces every limit itself: the role gate
/// hides `workspace_start` from a child, the handler refuses a caller that was itself
/// agent-started, and eight running children is the ceiling. There is nothing for a person to
/// weigh that Bloom has not already decided, and the ask carries no information a person could
/// act on beyond "an agent would like to use Bloom".
///
/// That is emphatically not true of the tools the agent brings with it. `Bash`, `Write` and
/// `Edit` reach outside anything Bloom knows about, and nothing here touches them.
///
/// ## What is deliberately not on the list
///
/// Anything that destroys work. When `workspace_archive` lands it removes a worktree and can
/// remove a branch with it, and the whole reason Bloom asks before archiving by hand is that the
/// answer is sometimes no. A tool that can lose work is a tool a person answers for.
///
/// `workspace_merge` is off the list too, and it draws the line one step further out. It destroys
/// nothing: it sends a turn, and the agent that reads it runs the merge in front of the owner. But
/// what that turn leads to is a call to a server other people share, and unlike a worktree there
/// is nothing on the far side of it to restore. Bloom answering its own permission question there
/// would be Bloom deciding to publish, which is the one decision it has never had.
public enum BridgeToolApproval {
    /// The prefix the CLI puts on an MCP tool's name: `mcp__<server>__<tool>`.
    ///
    /// Composed from `BridgeRegistration.serverName` rather than written out, so renaming the
    /// server cannot leave this matching a name nothing sends any more.
    public static var toolPrefix: String { "mcp__\(BridgeRegistration.serverName)__" }

    /// The tools Bloom answers for itself, by their bare names.
    ///
    /// A list rather than "anything with our prefix", so a tool added later is opted in by someone
    /// thinking about it rather than by inheriting a decision made before it existed.
    public static let selfApproved: Set<String> = [
        "whoami",
        "workspace_start",
        // Both add something the reader can see and close, in the workspace whose agent is
        // asking and nowhere else. Nothing is destroyed and nothing is hidden, which is a very
        // different weight from `workspace_merge`, which is deliberately not on this list.
        "pane_open",
        "pane_split",
        // Closing is on this list for the same reason opening is, and because it refuses the two
        // cases that would cost anything: it will not empty the centre column, and it cannot name
        // the review or the notes, which hold the reader's own work.
        "pane_close",
    ]

    /// Whether this ask is Bloom answering itself.
    public static func isSelfApproved(toolName: String) -> Bool {
        guard toolName.hasPrefix(toolPrefix) else { return false }
        return selfApproved.contains(String(toolName.dropFirst(toolPrefix.count)))
    }

    /// The note the transcript shows on a question Bloom answered for itself.
    ///
    /// A settled row rather than no row at all: the call still happened, and a reader scrolling
    /// back should find out that it did and who let it through. "Allowed automatically" with no
    /// reason is the thing that makes people distrust an app's permission model.
    public static let note = "Bloom's own tool, allowed without asking. See BridgeToolApproval."
}
