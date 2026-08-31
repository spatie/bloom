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
/// `workspace_rename` is the near miss on that paragraph and is on the list, so the line between
/// them is worth stating. It overwrites something with no copy kept too, and what makes it
/// different is what is overwritten and what it costs to put back. A quick prompt is a paragraph
/// the owner wrote; a workspace name is a label Bloom proposed and the owner accepted, it is one
/// column of one row, and it is on the screen in the row the reader is looking at the moment it
/// changes. The answer carries the previous name, so undoing it from the far side of the socket
/// is one more call. See `WorkspaceRenameTool`.
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
        // A workspace's own name, which is a bigger label than a tab's and answers the same two
        // questions. There is nothing for a person to weigh: one column of one row, nothing
        // destroyed, nothing published, and the change is in the row they are looking at as it
        // lands. And the way back costs one call, because the answer carries the name it had. The
        // reason it must not ask is the bug it was written from: an agent nine commits into a
        // piece of work stopped and asked the owner to rename the workspace by hand, and an ask
        // on this from a parent running unattended is the hung turn described above.
        "workspace_rename",
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
        // The four crew tools, and they stand or fall together, because a crew that can be
        // assembled and not spoken to is worse than no crew at all. An orchestrator that has to
        // stop and ask the owner before it can talk to agents it started itself is an
        // orchestrator that hangs on an unattended turn, which is the failure this whole file is
        // about; and the agent waiting at the other end of the unanswered ask is a second bill
        // running while nothing happens. None of the four reaches outside the workspace the
        // caller is already in: they read and write the `sessions` rows of one worktree, the
        // caller's own token says which worktree that is, and there is no argument on any of them
        // that could name another.
        //
        // Weighed against the paragraph above about what is deliberately off this list: none of
        // them destroys anything. `agent_start` adds a chat to the sidebar in front of the
        // reader, which is the visibility a pane has. `agent_say` puts a message in a chat the
        // owner can read and answer. `agent_list` reads. `agent_stop` ends a turn and leaves the
        // conversation and every file the agent wrote exactly where they are, so what it costs is
        // work in flight rather than work done, and `agent_say` starts the same agent again.
        //
        // What holds the ceiling, the depth limit and the name rule is `Crew`, enforced in the
        // handler before the window is asked for anything, which is the same argument
        // `workspace_start` is on this list under: there is nothing here for a person to weigh
        // that Bloom has not already decided.
        "agent_start",
        "agent_say",
        "agent_list",
        "agent_stop",
        // A presentation request, scoped to an image or movie that resolves inside the caller's
        // own worktree. It changes no file and sends nothing away. The row it adds is the visible
        // record and the file remains under the same agent permission that created or read it.
        "media_show",
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
        // Navigation and only navigation, asked for by the owner's own client in a conversation
        // the owner is sitting in front of. It creates nothing, archives nothing and touches no
        // file: what it costs is a glance, and the way back is a click. Asking would put a
        // question in front of somebody who has just said out loud "show me those", and a hung ask
        // is a hung turn. See `RevealTool`.
        "reveal",
    ]

    /// Whether this ask is Bloom answering itself.
    public static func isSelfApproved(toolName: String) -> Bool {
        guard toolName.hasPrefix(toolPrefix) else { return false }
        return selfApproved.contains(String(toolName.dropFirst(toolPrefix.count)))
    }

    /// **A self-approved ask leaves no row in the transcript**, and that is a change from what
    /// this file used to say. The argument for a settled row was that a reader scrolling back
    /// should find out the call happened and who let it through. The first half of that is
    /// already true without a row: the tool call itself is drawn, with its name and its result,
    /// exactly as every other call is. What the row added was a second entry per call saying
    /// Bloom had allowed Bloom, and a turn that opens a pane, splits it, renames a tab and lists
    /// its crew produced four of them between the reader and the work. The list above is what
    /// says who let these through, and it is the thing to read rather than a row repeated at
    /// runtime. See `AgentRunner.handle(_:)`, which answers before it stores.
}
