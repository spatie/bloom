import Foundation

/// Bringing one tab of the strip to the front, which only the window can do.
///
/// A second closure rather than a case on `WorkspaceTabListing`, and the split is the same one
/// `PaneListing` and `BrowserPaneCommanding` make: the seam that reports carries no verb, and the
/// seam that acts carries exactly one. The choice is resolved on the far side of it, against a
/// strip read in the same turn, for the reason `driveBrowserForBridge` resolves a browser number
/// there: a tab closed between the listing and the call would otherwise leave a number naming
/// something else.
public typealias WorkspaceTabSelecting =
    @Sendable (WorkspaceTabChoice, WorkspaceID) async -> WorkspaceTabSelection

/// `workspace_tab_select`: make one of the workspace's tabs the one in front.
///
/// ## What it deliberately cannot do
///
/// **It never creates a tab.** The tempting shape was "select, and open it if it is not there",
/// which reads as helpful and is how an agent asked to go back to a terminal ends up forking a
/// second one beside the one it meant. So the caller may only name a tab that is in the strip
/// already, a name that answers to nothing is a refusal carrying the strip, and `pane_open` stays
/// the only way a tab comes into being.
///
/// It reaches no window but the caller's own, which is the rule the whole pane family is held to:
/// there is no workspace argument, so an agent cannot rearrange a window somebody is working in on
/// the other side of the sidebar.
///
/// ## Why Bloom answers its own permission question for it
///
/// It is `pane_open` with less in it. That tool is self-approved and it both makes a tab and
/// brings it to the front; refusing to let an agent bring a tab that already exists forward, while
/// letting it conjure one and focus it, would be a rule that costs a hung turn and protects
/// nothing. What changes here is which tab the reader is looking at, in the workspace whose agent
/// is asking, and one click puts it back. Nothing is destroyed, nothing is hidden and nothing
/// leaves the machine.
///
/// The cost that is real is interruption, and it is answered in the description rather than by a
/// prompt: a person typing into a chat does not want the strip moving under them, so the tool says
/// to ask first when they are in the middle of something.
public struct WorkspaceTabSelectTool: BridgeToolHandling {
    private let select: WorkspaceTabSelecting

    public init(_ select: @escaping WorkspaceTabSelecting) {
        self.select = select
    }

    /// The gate the whole workspace-scoped family shares, argued once in `BridgeWorkspaceScope`.
    public let roles = BridgeWorkspaceScope.roles

    public let tool = BridgeTool(
        name: "workspace_tab_select",
        description: """
            Bring one tab of your workspace's centre column to the front, which is what clicking \
            it in the strip does.

            Name it with 'tab', the number workspace_tabs prints, or with 'title', the name the \
            strip shows. One of the two and not both. Numbers move as tabs are opened and closed, \
            so call workspace_tabs in the same turn rather than reusing a number from earlier.

            It only ever selects a tab that is already open: it will not create one, and a name \
            nothing answers to is refused with the list of tabs there are. pane_open is what opens \
            a new tab.

            Selecting a chat also makes it the workspace's active conversation, exactly as \
            clicking it would. The person may be reading or typing in the tab that is in front, so \
            ask before pulling them out of it unless they asked you to.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "tab": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Which tab, as workspace_tabs numbers them, counting from 1 along the "
                            + "strip."
                    ),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The tab's name as the strip shows it. Case does not matter. Refused when "
                            + "two tabs share the name, so pass 'tab' for those."
                    ),
                ]),
            ]),
            "required": .array([]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure(
                BridgeWorkspaceScope.refusal(tool: "workspace_tab_select", doing: "acts on")
            )
        }

        let choice: WorkspaceTabChoice
        switch WorkspaceTabChoice.parse(
            number: request.param("tab"), title: request.param("title")
        ) {
        case .failure(let refusal): return .failure(refusal.sentence)
        case .success(let parsed): choice = parsed
        }

        switch await select(choice, workspaceID) {
        case .selected(let sentence): return BridgeToolResult(text: sentence)
        case .refused(let sentence): return .failure(sentence)
        }
    }
}
