import Foundation

/// Opening a pane in the window, as the tab strip's `+` menu does it.
///
/// Injected for the reason `WorkspaceStarting` and `WorkspaceMergeRequesting` are: a bridge
/// handler runs off the main actor on a background task per connection, and everything that puts
/// a pane on screen is in the main-actor UI graph. The far side of this closure is `NewPane.open`,
/// unchanged and not copied, so a pane an agent asks for is the pane the menu makes.
public typealias PaneOpening = @Sendable (PaneOrder, WorkspaceID) async -> PaneOutcome

/// `pane_open`: put a chat, a terminal or a browser in a new tab of the workspace you are in.
///
/// ## Why this one is allowed to move the window, when so little else is
///
/// Nothing here is destructive and nothing here is hidden. A tab is added to a strip the reader
/// can see, it can be closed with the shortcut every other tab uses, and the worst outcome of a
/// wrong call is a tab somebody did not want. That is a very different weight from
/// `workspace_start`, which cuts a worktree, or `workspace_merge`, which asks for a merge, and it
/// is why this takes no confirmation.
///
/// **It cannot reach another workspace.** There is no workspace argument. Identity is minted by
/// Bloom and carried in the shim's environment, so the pane lands in the workspace whose agent is
/// asking and nowhere else: an agent cannot open tabs in a window somebody is working in on the
/// other side of the sidebar.
///
/// ## Focus is the caller's to choose, and defaults to yes
///
/// "Open me a terminal" means the terminal, in front. An agent opening a browser to check
/// something mid turn should be able to leave the reader where they are. See `PaneOrder.focus`.
public struct PaneOpenTool: BridgeToolHandling {
    private let open: PaneOpening

    public init(_ open: @escaping PaneOpening) {
        self.open = open
    }

    /// Not `.child`. A subagent opening tabs in its parent's window is a pane arriving from
    /// something the reader did not address, and the parent can open one on its behalf if it
    /// really is wanted.
    public let roles: Set<BridgeRole> = [.parent, .owner]

    public let tool = BridgeTool(
        name: "pane_open",
        description: """
            Open a pane in a new tab of the workspace you are in: a chat, a terminal, or a \
            browser. Use it when the person asks for one, and when what you are about to explain \
            would be easier for them with the thing already open in front of them.

            'kind' is one of \(PaneOrder.kindList). 'url' is for a browser and is optional. \
            'title' is what the tab is called and is optional: pass one when you know what the \
            pane is for, because four tabs called Terminal are four a reader cannot tell apart. \
            'focus' decides whether the new tab is brought to the front, and defaults to true: \
            pass false when you are opening something to be useful later and the reader is in the \
            middle of something now.

            It opens in your own workspace and takes no workspace argument. It is not \
            destructive: the reader can close the tab.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(PaneKind.allCases.map { .string($0.rawValue) }),
                    "description": .string("What to open."),
                ]),
                "url": .object([
                    "type": .string("string"),
                    "description": .string("Where a browser pane should start. Browser only."),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string(
                        "What to call the tab. Leave it out for the strip's own numbering."
                    ),
                ]),
                "focus": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Whether to bring the new tab to the front. Defaults to true."
                    ),
                ]),
            ]),
            "required": .array([.string("kind")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure(
                "pane_open opens a pane in the workspace you are in, and this connection is not "
                    + "speaking for one."
            )
        }
        switch PaneOrder.parse(
            kind: request.stringParam("kind"),
            url: request.stringParam("url"),
            focus: request.param("focus"),
            title: request.stringParam("title"),
            tool: "pane_open"
        ) {
        case .refused(let refusal):
            return .failure(refusal)
        case .order(let order):
            switch await open(order, workspaceID) {
            case .opened(let sentence): return BridgeToolResult(text: sentence)
            case .refused(let refusal): return .failure(refusal)
            }
        }
    }
}
