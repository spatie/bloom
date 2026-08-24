import Foundation

/// Renaming a pane, as double clicking its tab in the strip does it.
///
/// Injected for the reason `PaneOpening`, `PaneSplitting` and `PaneClosing` are: a bridge handler
/// runs off the main actor and both places a name is written, the tab store and the session row,
/// are reached through the main-actor UI graph. Nil for the kind means the pane the reader is
/// focused on, which is what a double click renames.
public typealias PaneRenaming = @Sendable (String, PaneKind?, WorkspaceID) async -> PaneOutcome

/// The two arguments `pane_rename` takes, once they have been found to make sense.
///
/// A value rather than a tuple so the suite can compare one whole reading against another, the way
/// `PaneOrder` is compared next door.
public struct PaneRenameOrder: Sendable, Equatable {
    /// Trimmed, and never empty: an empty name is refused rather than written, because a tab with
    /// a blank label is one the reader cannot pick out and cannot click to fix.
    public var title: String

    /// Which pane, or nothing for the one the reader is focused on.
    public var kind: PaneKind?

    public init(title: String, kind: PaneKind? = nil) {
        self.title = title
        self.kind = kind
    }
}

/// `pane_rename`: give a pane a name the reader can find it by.
///
/// ## Why it exists beside the title on `pane_open`
///
/// Naming at the point of opening only covers the agent that opened the pane. The reader opens
/// most of them, and an agent that has just filled a terminal with a long build or pointed a
/// browser at one particular page knows what that tab is for better than "Terminal 3" does. The
/// name is also the only thing about a pane an agent can change after the fact: it cannot move
/// one, and `pane_close` is the only other verb it has.
///
/// ## Why it is safe
///
/// It renames a tab in the strip the reader is looking at, in the workspace whose agent is asking,
/// and a name is undone by typing over it. Nothing is destroyed and nothing is hidden, which is
/// why it is on `BridgeToolApproval.selfApproved` beside the other three.
///
/// It takes a kind rather than a pane id for the reason `pane_close` does: a model naming
/// `browser` is describing something it can see the effect of, and a model handed pane ids would
/// be renaming things by a number it guessed.
public struct PaneRenameTool: BridgeToolHandling {
    private let rename: PaneRenaming

    public init(_ rename: @escaping PaneRenaming) {
        self.rename = rename
    }

    /// Not `.child`, matching the other three. A subagent renaming its parent's tabs is a strip
    /// changing under the reader on behalf of something they did not address.
    /// A parent and nothing else.
    ///
    /// Not `.owner`, although it was at first, and that was a listed tool that could never work.
    /// This tool is scoped to the workspace the caller is standing in, and `BridgeIdentity.owner`
    /// carries no `workspaceID` by definition: the role is the person reaching Bloom from a client
    /// they started themselves, sitting in no workspace at all. Every call refused with "this
    /// connection is not speaking for one", after being advertised in `tools/list` as though it
    /// would work. `BridgeRole.owner` says as much in its own doc comment: not anything scoped to
    /// a workspace, because it has none to be scoped to.
    public let roles: Set<BridgeRole> = [.parent]

    public let tool = BridgeTool(
        name: "pane_rename",
        description: """
            Rename a pane in the workspace you are in. Use it when a tab is now about something \
            nameable, a terminal running one long build or a browser sitting on one page, so the \
            reader can find it again among tabs that are otherwise all called the same thing.

            'title' is what to call it and is required. 'kind' is one of \(PaneOrder.kindList) and \
            renames the pane showing that; leave it out to rename the pane the reader is focused \
            on.

            It renames one pane in your own workspace and takes no workspace argument. It is not \
            destructive: the reader can rename it back by double clicking the tab.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "description": .string("What to call the pane."),
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(PaneKind.allCases.map { .string($0.rawValue) }),
                    "description": .string(
                        "Which pane to rename. Omit for the one the reader is focused on."
                    ),
                ]),
            ]),
            "required": .array([.string("title")]),
        ])
    )

    /// Reads the two arguments, or says why it could not, in words a model can act on.
    ///
    /// Pure and static so the suite can hold the refusals without a window: what a model is told
    /// when it passes a blank name is a sentence somebody has to be able to read back.
    static func parse(title rawTitle: String?, kind rawKind: String?)
        -> Result<PaneRenameOrder, PaneRefusal> {
        guard let title = PaneOrder.name(from: rawTitle) else {
            return .failure(
                PaneRefusal(
                    "pane_rename needs a 'title' to give the pane. A blank one would leave a tab "
                        + "the reader cannot tell from any other."
                )
            )
        }

        let raw = rawKind?.trimmingCharacters(in: .whitespaces)
        guard let raw, !raw.isEmpty else { return .success(PaneRenameOrder(title: title)) }
        guard let kind = PaneKind(rawValue: raw) else {
            return .failure(
                PaneRefusal("Bloom has no pane called '\(raw)'. It opens \(PaneOrder.kindList).")
            )
        }
        return .success(PaneRenameOrder(title: title, kind: kind))
    }

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure(
                "pane_rename renames a pane in the workspace you are in, and this connection is "
                    + "not speaking for one."
            )
        }

        switch Self.parse(
            title: request.stringParam("title"), kind: request.stringParam("kind")
        ) {
        case .failure(let refusal):
            return .failure(refusal.sentence)
        case .success(let order):
            switch await rename(order.title, order.kind, workspaceID) {
            case .opened(let sentence): return BridgeToolResult(text: sentence)
            case .refused(let refusal): return .failure(refusal)
            }
        }
    }
}
