import BloomCore

/// What an Agent call row in the chat can do about the run behind it, handed to the row by the
/// list.
///
/// **Closures rather than values, and that is the list's performance rule rather than a style.**
/// The roster moves about once a second while a subagent works, and reading it in the pass that
/// assembles the entries would rebuild every entry on every tick. Asked inside the row, it is read
/// by the one row that needs it, and only when the stored rows cannot answer: see
/// `SubagentRunLink.canOpen`. Not part of the row's `==`, for the reason no other closure there is.
struct SubagentRunActions {
    /// Whether the roster still holds the subagent this call started.
    var isLive: (String) -> Bool
    /// Open the run: the call's id, whether rows are stored under it, and whether its result has
    /// come back. `SubagentRunLink.target` decides what that opens.
    var open: (String, Bool, Bool) -> Void
}
