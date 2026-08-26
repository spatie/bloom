import Foundation

/// Reading the workspace's tab strip, which lives in the main-actor UI graph.
///
/// Injected for the reason `PaneListing` is, and shaped the same way for the same reason: **a tool
/// that only reports cannot be handed a verb.** The seam takes a workspace and gives back a
/// census, so there is no argument on this path that could ask the window to do anything.
/// `WorkspaceTabSelecting` next door is the one that acts, and it is deliberately a second
/// closure rather than a case on this one.
public typealias WorkspaceTabListing = @Sendable (WorkspaceID) async -> WorkspaceTabCensus?

/// `workspace_tabs`: the strip of the workspace the caller is standing in, tab by tab.
///
/// ## Why this exists next to `pane_list`
///
/// `pane_list` flattens the window into panes, which is the right shape for the question the
/// browser tools ask ("which of the reader's browsers do you mean") and the wrong shape for the
/// question a person asks. A reader says "go back to the chat about the parser" or "bring the
/// notes forward", and a flat list of panes has nothing in it that is a tab: a split contributes
/// two rows and neither of them is the thing the reader would click.
///
/// So this is the strip, and it carries the one fact per tab that a caller can act on rather than
/// everything Bloom knows: a chat says which agent, whether a turn is going and how long the
/// conversation is; a review says which file it is on; a terminal says where its shell was started
/// and whether one has been started at all; a browser says where it is pointed and what number the
/// `browser_` tools know it by; the notes say whether there is anything in them.
///
/// ## What it is not allowed to cost
///
/// Nothing here runs a command or makes a request. The two temptations were a terminal's live
/// working directory and what is running in it, and both mean asking tmux, which is a subprocess
/// inside a listing an agent calls at the top of every turn. The tab says which directory its
/// shell was started in and says out loud that it does not know the rest, which is a true small
/// answer rather than a plausible large one.
///
/// It does not create anything either. `CenterTabStore.liveBrowser` is what the browser half asks,
/// never `browser(for:)`, and the terminal half asks whether a shell exists rather than for one,
/// so a listing cannot fetch a page or fork a shell that nobody had opened. That is the same rule
/// `pane_list` is held to and it is the reason both are self-approved.
public struct WorkspaceTabsTool: BridgeToolHandling {
    private let census: WorkspaceTabListing

    public init(_ census: @escaping WorkspaceTabListing) {
        self.census = census
    }

    /// A parent and nothing else. See `BrowserPaneRun.roles`, which argues the gate the whole pane
    /// family shares, and `BridgeRole.owner` for why the odd role out cannot have any of them:
    /// every tool here is scoped to the workspace the caller is standing in, and the owner's own
    /// client stands in none.
    public let roles = BrowserPaneRun.roles

    public let tool = BridgeTool(
        name: "workspace_tabs",
        description: """
            The tab strip of the workspace you are in, left to right: what each tab is, what the \
            person sees it called, which one is in front, and one true thing about what is in it.

            A chat says which agent drives it, whether a turn is running and how many messages it \
            holds. A review says which file it is showing. A terminal says the directory its shell \
            was started in and whether a shell has been started at all. A browser says where it is \
            pointed and carries the number the browser_ tools take. The notes say how long they \
            are and never what they say.

            A tab somebody has split also lists what it has absorbed. Use pane_list when you want \
            every pane flattened rather than the strip.

            'tab' is a place in the strip counting from 1 and it moves as tabs are opened, closed \
            and dragged, so call this again before acting on a number. workspace_tab_select takes \
            either that number or the title.

            It reads your own workspace and takes no arguments. It runs no command and fetches no \
            page: a terminal's directory is where its shell started, not where it is now, and \
            nothing here is the contents of a page, a diff or a note.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure(
                "workspace_tabs lists the tabs of the workspace you are in, and this connection "
                    + "is not speaking for one."
            )
        }
        guard let census = await census(workspaceID) else {
            return .failure(WorkspaceTabTrouble.noWorkspace)
        }
        return .json(census.json)
    }
}

/// The one sentence both tab tools say about a workspace that has gone.
///
/// Said once because they are the same fact, and a model that is told two different things about
/// one absence learns that one of them is wrong. `AppModel.noWorkspaceForPane` is the same
/// decision made for the pane family, in a register that fits a tool which puts something on the
/// screen rather than one that reads the strip.
public enum WorkspaceTabTrouble {
    public static let noWorkspace =
        "That workspace is not open in Bloom any more, so its tabs cannot be reached."
}
