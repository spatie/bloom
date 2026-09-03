import Foundation

/// What every tool that acts inside the caller's own workspace has in common: who may call it, and
/// the one sentence it refuses a connection that is standing in no workspace with.
///
/// ## Why the gate is stated here rather than on each tool
///
/// It was on each tool, and it was the same eight line paragraph pasted into `PaneOpenTool`,
/// `PaneCloseTool`, `PaneSplitTool` and `PaneRenameTool` word for word, with `BrowserPaneRun` and
/// `TerminalPaneRun` holding a fifth and sixth copy of the conclusion. Two of those pastes landed
/// in the middle of an existing comment, so `pane_open` and `pane_rename` both read "the parent
/// can open one on its behalf if it really is wanted. A parent and nothing else." A rule that is
/// copied is a rule that is edited in one place, and the edit nobody notices here is a role
/// quietly widened on one tool of six.
///
/// The reasoning, once. **`.parent` and nothing else.**
///
/// Not `.owner`, and this is the mistake that was made once already and must not be made again.
/// Every tool on this gate is scoped to the workspace the caller is standing in, and
/// `BridgeIdentity.owner` carries no `workspaceID` by definition: the role is the person reaching
/// Bloom from a client they started themselves, sitting in no workspace at all. Four of the pane
/// tools were advertised to that role at first, could only ever answer with the refusal below, and
/// had to be taken away again. `BridgeRole.owner` says as much in its own doc comment: not
/// anything scoped to a workspace, because it has none to be scoped to.
///
/// Not `.child`. A subagent moving panes, tabs or terminals in its parent's window is something
/// happening to the reader on behalf of a thing they did not address, and the parent can do it for
/// the child if it really is wanted.
///
/// ## Why the refusal is composed rather than written out
///
/// Thirteen tools said the same fact and eight of them said it differently, which is the failure
/// `WorkspaceTabTrouble.noWorkspace` next door already names: a model told two different things
/// about one absence learns that one of them is wrong. Two had drifted far enough to stop saying
/// what was actually wrong at all, `media_show` with "media_show only shows a file from the
/// workspace you are in" and `terminal_start` with "terminal_start only starts a terminal in the
/// workspace you are in", both of which restate the tool's scope and leave the caller to work out
/// that its connection is the thing that does not have one.
///
/// The half that must differ still differs. `doing` is the tool's own verb phrase, because a
/// refusal that names the tool and what it would have done is a refusal a model can act on, and
/// `pane_list` saying "lists the panes of" where `pane_split` says "splits a tab in" is the part
/// worth keeping.
public enum BridgeWorkspaceScope {
    /// The gate every tool scoped to the caller's own workspace shares. See the head of this file.
    public static let roles: Set<BridgeRole> = [.parent]

    /// The sentence a workspace-scoped tool refuses a connection that is speaking for no workspace
    /// with. `doing` is the tool's own half: "opens a pane in", "lists the panes of", "renames".
    public static func refusal(tool: String, doing: String) -> String {
        "\(tool) \(doing) the workspace you are in, and this connection is not speaking for one."
    }
}
