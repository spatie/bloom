import Foundation

/// Every tool the bridge serves, and the only place a new one is added.
///
/// A list of handlers rather than a switch. There are twenty-five of them now, and a switch
/// would put each in three places: the listing, the dispatch and the role gate. Here a tool is one
/// type, and it carries its own gate. See `docs/BRIDGE.md` for the whole surface and who may reach
/// it.
public struct BridgeToolbox: Sendable {
    public let handlers: [any BridgeToolHandling]

    public init(handlers: [any BridgeToolHandling]) {
        self.handlers = handlers
    }

    /// What a `BridgeServer` built without the app serves: everything that needs no seam back
    /// into the app, which is every test that did not ask for more.
    ///
    /// `whoami` came first and came alone, because it needs no runner, no writes and no parentage,
    /// so it proved the transport and the identity mapping before any of the machinery the rest
    /// need existed.
    ///
    /// One thing the live run measured that the tools after this one have to answer: **a bridge
    /// call raises a permission question like any other tool call.** On claude 2.1.238, under
    /// `acceptEdits`, calling `whoami` produced an ask for `mcp__bloom-workspace-bridge__whoami`
    /// and the turn stopped until it was answered. That matters because the reason the bridge is
    /// MCP rather than a CLI the agent shells out to was partly that a shell command goes through
    /// the permission machinery; being an MCP tool does not exempt it. A child that has to file
    /// `workspace_report` unattended therefore needs an answer of its own, either a grant Bloom
    /// makes for its own tools or an allow rule in the child's settings. `BridgeToolApproval` is
    /// where that was answered, and its head says which tools Bloom answers for and why the rest
    /// are not on the list. See `LiveBridgeTests`.
    ///
    /// `workspace_start`, `workspace_merge` and the thirteen pane and tab tools are the exceptions
    /// and are added by `AppModel.bridgeToolbox()`, because starting a workspace has to reach the
    /// main-actor graph that runs one, asking one to merge has to reach the same path the Merge
    /// button takes, and a pane is a thing the window owns; see `WorkspaceStarting`,
    /// `WorkspaceMergeRequesting`, `PaneOpening`, `PaneSplitting`, `PaneClosing`, `PaneRenaming`,
    /// `PaneListing`, `BrowserPaneCommanding`, `WorkspaceTabListing` and `WorkspaceTabSelecting`.
    /// Four of those are the ones that read: a `WKWebView` is as much a part of the UI graph as a
    /// tab strip is, so seeing a pane crosses the same line as opening one, and which tab a
    /// workspace is in is held nowhere but in memory on the main actor.
    public static let standard = BridgeToolbox(handlers: [
        WhoamiTool(),
        ProjectListTool(),
        ProjectAddTool(),
        ProjectHideTool(),
        ProjectUnhideTool(),
        WorkspaceListTool(),
        // A quick prompt is a row in `quick_prompt` and nothing else, so all four reach the store
        // directly and none of them needs a seam into the window: the panel finds out through the
        // update hook, the way it would about a write made anywhere else. See `QuickPromptCall`.
        QuickPromptListTool(),
        QuickPromptCreateTool(),
        QuickPromptUpdateTool(),
        QuickPromptDeleteTool(),
    ])

    /// The tools a caller may see. Sorted by name so `tools/list` is stable between calls, which
    /// is one fewer thing to wonder about when a transcript is read back.
    public func tools(for role: BridgeRole) -> [BridgeTool] {
        handlers.filter { $0.roles.contains(role) }.map(\.tool).sorted { $0.name < $1.name }
    }

    /// The handler for a call, or nil when there is none this caller may reach. A tool that exists
    /// but is refused to this role answers nil exactly as an unknown name does, so the refusal
    /// cannot be read as a hint that something is there.
    public func handler(named name: String, for role: BridgeRole) -> (any BridgeToolHandling)? {
        handlers.first { $0.tool.name == name && $0.roles.contains(role) }
    }
}
