import Foundation

/// The destination comes from the authenticated chat, not whichever pane has keyboard focus
/// after the agent has finished thinking. The app resolves that destination in its pane trees.
public typealias PaneSplitting =
    @Sendable (PaneOrder, SplitAxis, PaneSplitAnchor, WorkspaceID) async -> PaneOutcome

/// Adds a pane to an existing tab. New tabs belong to `pane_open`.
public struct PaneSplitTool: BridgeToolHandling {
    private let split: PaneSplitting

    public init(_ split: @escaping PaneSplitting) {
        self.split = split
    }

    /// The gate the whole workspace-scoped family shares, argued once in `BridgeWorkspaceScope`.
    public let roles = BridgeWorkspaceScope.roles

    public let tool = BridgeTool(
        name: "pane_split",
        description: """
            Add a pane alongside this conversation, inside the same tab. A tab is an entry in \
            the top tab strip; a pane is one visible region inside a tab. Splitting adds a region \
            so both contents are visible together. pane_open creates a separate tab instead.

            For "add a pane", "split pane in this chat", or "split vertically next to this chat", \
            call pane_split with no arguments: it opens a NEW chat to the RIGHT of the chat \
            making this request, separated by a vertical divider. It does not duplicate this \
            conversation. Do not select another tab first or use pane_open for these requests.

            'kind' defaults to 'chat'; use 'terminal' or 'browser' when requested. 'direction' \
            defaults to 'beside' (right, side by side, vertical divider); 'below' stacks panes \
            with a horizontal divider. 'url' is optional and browser-only. 'title' names the new \
            content, not the containing tab.

            'target' defaults to 'this_chat', resolved from your connection even if another tab \
            or pane has focus. Only use 'active_pane' when the person explicitly asks to split \
            the currently selected pane instead of this chat. A missing target is refused; it \
            never silently falls back to another chat. Everything stays in your own workspace.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(PaneKind.allCases.map { .string($0.rawValue) }),
                    "description": .string("What to show in the new pane. Defaults to a new chat."),
                ]),
                "url": .object([
                    "type": .string("string"),
                    "description": .string("Where a browser pane should start. Browser only."),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Name of the new content. Does not rename the containing tab."
                    ),
                ]),
                "target": .object([
                    "type": .string("string"),
                    "enum": .array([.string("this_chat"), .string("active_pane")]),
                    "description": .string("Defaults to this_chat, the conversation making this request. active_pane explicitly follows UI focus."),
                ]),
                "direction": .object([
                    "type": .string("string"),
                    "enum": .array([.string("beside"), .string("below")]),
                    "description": .string(
                        "'beside': right with a vertical divider (default). 'below': underneath with a horizontal divider."
                    ),
                ]),
            ]),
            "required": .array([]),
            "additionalProperties": .bool(false),
        ])
    )

    /// The wire's two words, and the app's two. Named for what the reader sees rather than for the
    /// axis, because `horizontal` meaning "side by side" is the thing everyone reads backwards.
    static func axis(named direction: String?) -> Result<SplitAxis, PaneRefusal> {
        switch direction?.trimmingCharacters(in: .whitespaces).lowercased() {
        case .none, .some(""), .some("beside"): return .success(.horizontal)
        case .some("below"): return .success(.vertical)
        case .some(let other):
            return .failure(PaneRefusal(
                "Bloom splits 'beside' or 'below', not '\(other)'. Use 'beside' for side-by-side "
                    + "panes with a vertical divider, or 'below' for stacked panes with a horizontal divider."
            ))
        }
    }

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure(
                BridgeWorkspaceScope.refusal(tool: "pane_split", doing: "splits a tab in")
            )
        }
        let anchor: PaneSplitAnchor
        switch request.param("target") {
        case nil, .string("this_chat"):
            guard let sessionID = identity.sessionID else {
                return .failure("This connection has no chat to split beside.")
            }
            anchor = .chat(sessionID)
        case .string("active_pane"): anchor = .activePane
        default: return .failure("'target' must be 'this_chat' or 'active_pane'.")
        }
        for name in ["kind", "direction"] {
            if let value = request.param(name), value.stringValue == nil {
                return .failure("'\(name)' must be a string. Leave it out for the default.")
            }
        }
        switch PaneOrder.parse(
            kind: request.stringParam("kind") ?? "chat",
            url: request.stringParam("url"),
            focus: JSONValue?.none,
            title: request.stringParam("title"),
            tool: "pane_split"
        ) {
        case .refused(let refusal):
            return .failure(refusal)
        case .order(let order):
            switch Self.axis(named: request.stringParam("direction")) {
            case .failure(let refusal):
                return .failure(refusal.sentence)
            case .success(let axis):
                switch await split(order, axis, anchor, workspaceID) {
                case .opened(let sentence): return BridgeToolResult(text: sentence)
                case .refused(let refusal): return .failure(refusal)
                }
            }
        }
    }
}
