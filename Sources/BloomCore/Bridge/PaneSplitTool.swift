import Foundation

/// Splitting the tab the reader is on, as Cmd+D and Shift+Cmd+D do it.
///
/// Injected for the same reason `PaneOpening` is, and it is a second closure rather than a flag on
/// that one because the two verbs land in different places: `NewPane.open` makes a tab and
/// `WorkspaceTabsStore.split` divides one.
public typealias PaneSplitting =
    @Sendable (PaneOrder, SplitAxis, WorkspaceID) async -> PaneOutcome

/// `pane_split`: put a pane beside what is already on screen rather than behind it.
///
/// ## Why it is its own tool and not an argument to `pane_open`
///
/// They read as one feature and behave as two. Opening always works: a workspace can always hold
/// another tab. Splitting can be refused, and by rules that have nothing to do with the kind being
/// asked for: there has to be a tab to split, and `PaneSplit` will not duplicate a pane a
/// workspace has exactly one of. A single tool would have one set of arguments and two quite
/// different refusal vocabularies, and a model reading "could not open" would not know which of
/// the two it had run into.
///
/// The split rule itself is not restated here. `PaneSplit.duplicating` is what the menu items read
/// to decide whether Split Right is greyed, and this asks the same question through the same door,
/// so a pane the menu will not split is a pane this refuses with the menu's own reason.
///
/// ## The axis is named for what the reader sees
///
/// `SplitAxis.horizontal` is side by side and `.vertical` is stacked, which is the convention the
/// rest of the app uses and the opposite of what half of the people reading it will expect. So the
/// description says "beside" and "below" rather than the two words, and the wire still carries the
/// enum, so nothing here invents a third vocabulary for the same two directions.
public struct PaneSplitTool: BridgeToolHandling {
    private let split: PaneSplitting

    public init(_ split: @escaping PaneSplitting) {
        self.split = split
    }

    public let roles: Set<BridgeRole> = [.parent, .owner]

    public let tool = BridgeTool(
        name: "pane_split",
        description: """
            Split the tab the reader is on and show a pane in the new half: a chat, a terminal, \
            or a browser. Use it when the two things are worth reading together, a terminal beside \
            the diff it is about, and `pane_open` when they are not.

            'kind' is one of \(PaneOrder.kindList). 'url' is for a browser and is optional. \
            'direction' is 'beside' to put the new pane on the right, or 'below' to stack it \
            under; it defaults to 'beside'.

            It splits the tab in your own workspace and takes no workspace argument. It can be \
            refused: there has to be a tab open, and some panes a workspace has only one of \
            cannot be duplicated. It is not destructive.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(PaneKind.allCases.map { .string($0.rawValue) }),
                    "description": .string("What to show in the new half."),
                ]),
                "url": .object([
                    "type": .string("string"),
                    "description": .string("Where a browser pane should start. Browser only."),
                ]),
                "direction": .object([
                    "type": .string("string"),
                    "enum": .array([.string("beside"), .string("below")]),
                    "description": .string(
                        "'beside' puts it on the right, 'below' stacks it. Defaults to 'beside'."
                    ),
                ]),
            ]),
            "required": .array([.string("kind")]),
        ])
    )

    /// The wire's two words, and the app's two. Named for what the reader sees rather than for the
    /// axis, because `horizontal` meaning "side by side" is the thing everyone reads backwards.
    static func axis(named direction: String?) -> Result<SplitAxis, PaneRefusal> {
        switch direction?.trimmingCharacters(in: .whitespaces).lowercased() {
        case .none, .some(""), .some("beside"): return .success(.horizontal)
        case .some("below"): return .success(.vertical)
        case .some(let other):
            return .failure(PaneRefusal("Bloom splits 'beside' or 'below', not '\(other)'."))
        }
    }

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure(
                "pane_split splits a tab in the workspace you are in, and this connection is not "
                    + "speaking for one."
            )
        }
        // The pane a split lands in is beside what the reader is already looking at, so it is
        // always in front of them: there is nothing for `focus` to choose between and the
        // argument is deliberately absent rather than accepted and ignored.
        switch PaneOrder.parse(
            kind: request.stringParam("kind"),
            url: request.stringParam("url"),
            focus: JSONValue?.none,
            tool: "pane_split"
        ) {
        case .refused(let refusal):
            return .failure(refusal)
        case .order(let order):
            switch Self.axis(named: request.stringParam("direction")) {
            case .failure(let refusal):
                return .failure(refusal.sentence)
            case .success(let axis):
                switch await split(order, axis, workspaceID) {
                case .opened(let sentence): return BridgeToolResult(text: sentence)
                case .refused(let refusal): return .failure(refusal)
                }
            }
        }
    }
}
