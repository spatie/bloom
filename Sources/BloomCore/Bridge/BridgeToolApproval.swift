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
/// `quick_prompt_delete` and `quick_prompt_update` are the two on the bridge today that this
/// applies to. Neither touches a repository, but both act on a few lines the owner wrote by hand,
/// Bloom keeps no copy of what was there before, and both are reachable only from the owner's own
/// client, where there is somebody sitting to answer. That is the whole of why they are allowed at
/// all and the whole of why they ask. `quick_prompt_list` is on the list below; the other three
/// are not.
///
/// ## The browser pane, which is where the line got its sharpest test
///
/// Seven tools reach a browser pane the owner has open, and two of them are on the list. The
/// question is not how destructive each one is, it is what a page in that pane actually is: his
/// own application, logged in as him, with a live session. Anything that reads it out or acts
/// inside it is doing so as him.
///
/// So the line is drawn at the chrome. `pane_list` and `browser_read` report the strip and the
/// address bar: which tabs are open, what they are called, where each browser is pointed, whether
/// it is loading, whether Back would do anything. Every fact of that is on the screen in front of
/// him already, none of it is the contents of a page, and an agent that cannot see what is open
/// cannot offer to help with it. They also have to be callable while nobody is watching, because
/// the whole point of them is to be the first call of a turn that then does something useful.
///
/// The other five are off the list, in two groups. `browser_reload`, `browser_go` and
/// `browser_scroll` change what the person is looking at: a reload can lose what they had typed
/// into a form, a navigation is a request made from their browser with whatever they are logged
/// into, and a scroll moves the page under somebody who is reading it. `browser_screenshot` and
/// `browser_text` carry the page itself into a model's context, which is to say off this machine,
/// and a page he is signed into is his data. Bloom cannot tell a dev server's front page from an
/// administration screen, so it does not try: it asks, and the person who can tell answers.
///
/// **There is no tool here that runs script in the page, and that is a decision rather than an
/// omission.** The argument is at the head of `BrowserPaneCommand`, and the part that belongs on
/// this list is that self-approval could not have rescued it: a permission prompt showing a
/// paragraph of JavaScript is a prompt nobody can evaluate, so keeping it off the list would have
/// been a safeguard in name only.
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
        // A name, on a tab the reader is looking at, which they undo by double clicking it and
        // typing the old one back. There is nothing here for a person to weigh that they cannot
        // see and reverse in a second.
        "pane_rename",
        // The only one of the four quick prompt tools on this list, and the only one of them a
        // parent can call unattended. It reads the owner's own library and changes nothing in it,
        // so the ask would carry nothing for a person to weigh, and an unanswered ask on a read is
        // the hang described above for no gain at all. `quick_prompt_create` is deliberately off
        // the list, because a row lands in a panel nobody is looking at rather than in front of
        // the reader the way a pane does; `quick_prompt_update` overwrites what the owner wrote
        // and `quick_prompt_delete` removes it, with no undo on either.
        "quick_prompt_list",
        // The two that report the window's own furniture rather than anything on a page. See the
        // section above: everything they say is already on the screen in front of the reader, and
        // an agent that cannot see which panes are open has nothing to name in the five tools
        // that act on one.
        "pane_list",
        "browser_read",
        // The strip, read as a strip, which is the same furniture `pane_list` reports in another
        // shape and is on the list for the same reason: it is on the screen in front of the reader
        // already, none of it is the contents of a page, a diff or a note, and it is the first
        // call of any turn that then does something useful.
        "workspace_tabs",
        // Clicking a tab, which is `pane_open` with less in it: that one makes a tab AND brings it
        // to the front and is on this list, so a rule that asked before an agent could bring an
        // existing tab forward would cost a hung turn and protect nothing. What it changes is
        // which tab the reader is looking at, in the workspace whose agent is asking, and one
        // click puts it back. It cannot create a tab, which is what keeps it this small.
        "workspace_tab_select",
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
