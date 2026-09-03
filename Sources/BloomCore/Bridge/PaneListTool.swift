import Foundation

/// Reading the window's own strip, which lives in the main-actor UI graph.
///
/// Injected for the reason `PaneOpening` and its siblings are. It is its own closure rather than
/// a case on `BrowserPaneCommanding`, and that is a deliberate shape: **a tool that only reports
/// cannot be handed a verb.** The seam takes a workspace and gives back a census, so there is no
/// argument anywhere on this path that could ask the window to do something, and no later edit
/// that adds one without a reader noticing.
public typealias PaneListing = @Sendable (WorkspaceID) async -> PaneCensus?

/// `pane_list`: what the person has open in this workspace.
///
/// ## Why this one had to come first
///
/// The gap this whole family closes was reported in one sentence: a browser pane was open beside a
/// chat, the person asked "can you see what is in that browser?", and the honest answer was no.
/// The agent could open a pane, rename it and close it, and could not see one. Every tool that
/// reads or drives a browser needs a way to say which browser, and until something listed them
/// there was nothing for a caller to name. So this is the census, and the numbers it hands out are
/// the vocabulary the six `browser_` tools are spoken in.
///
/// ## Why it is answered without asking anybody
///
/// It reports the furniture: which tabs exist, what the strip calls them, which are in the tab in
/// front, and where each browser is pointed. All of it is on the screen in front of the reader,
/// none of it is the contents of a page, and an agent that cannot see what is open cannot even
/// offer to help with it. `pane_open` and `pane_close` are on the same list for the same kind of
/// reason, and the tools that read a page or move one are deliberately not: see
/// `BridgeToolApproval`.
///
/// The one thing here that a page influences is a browser tab's name and address, because a tab is
/// named after the page unless somebody renamed it. That is why the answer carries a line saying
/// so. It is metadata rather than content, and it is marked all the same.
public struct PaneListTool: BridgeToolHandling {
    private let census: PaneListing

    public init(_ census: @escaping PaneListing) {
        self.census = census
    }

    /// The gate the whole workspace-scoped family shares, argued once in `BridgeWorkspaceScope`.
    public let roles = BridgeWorkspaceScope.roles

    public let tool = BridgeTool(
        name: "pane_list",
        description: """
            List what the person has open in the workspace you are in: their chats, terminals, \
            browsers, the changed files and the notes. Each pane says what kind it is, what the \
            tab is called, and whether it is in the tab they are looking at right now.

            A browser pane also says where it is pointed and whether it is still loading, and \
            carries the number the browser_ tools take. Call this first whenever you mean to read \
            or drive one of them, because those numbers change as tabs are opened and closed.

            It reads your own workspace and takes no arguments. It reports the tab strip and never \
            the contents of a page: browser_text and browser_screenshot are what read a page.
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
                BridgeWorkspaceScope.refusal(tool: "pane_list", doing: "lists the panes of")
            )
        }
        guard let census = await census(workspaceID) else {
            return .failure(
                "That workspace is not open in Bloom any more, so there is nothing to list."
            )
        }
        return .json(census.json)
    }
}
