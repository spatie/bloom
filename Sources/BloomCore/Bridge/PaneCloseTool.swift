import Foundation

/// Closing a pane, as the pane's own close control and Cmd+Ctrl+W do it.
///
/// Injected for the reason `PaneOpening` and `PaneSplitting` are: a bridge handler runs off the
/// main actor and everything that takes a pane off the screen is in the main-actor UI graph. Nil
/// means the pane the reader is focused on, which is what the keyboard shortcut closes.
public typealias PaneClosing = @Sendable (PaneKind?, WorkspaceID) async -> PaneOutcome

/// `pane_close`: take a pane back off the screen.
///
/// ## Why it exists, having been left out
///
/// `pane_open` and `pane_split` both told the model that closing was the reader's to do, and that
/// was the wrong half of a pair. An agent that can open a browser to show somebody something can
/// see when it is finished with; making the person close it by hand is asking them to tidy up
/// after a tool. Asked for after "close the browser split" was met with "I can't".
///
/// ## What it will not do
///
/// It closes one pane, in the workspace whose agent is asking, and it names what it closed. It
/// will not close the last thing standing: a workspace with nothing in its centre column is a
/// window that looks broken, and an agent tidying up should not be able to produce one. It will
/// not close a review or a notes pane either, which are the two a workspace has exactly one of and
/// which hold the reader's own work rather than the agent's.
///
/// Nothing here is undoable by the tool. That is why it takes a kind rather than an id: a model
/// naming `browser` is describing something it can see the effect of, and a model handed pane ids
/// would be closing things by a number it guessed.
public struct PaneCloseTool: BridgeToolHandling {
    private let close: PaneClosing

    public init(_ close: @escaping PaneClosing) {
        self.close = close
    }

    public let roles: Set<BridgeRole> = [.parent, .owner]

    public let tool = BridgeTool(
        name: "pane_close",
        description: """
            Close a pane in the workspace you are in. Use it when you opened something to show \
            the person and it has served its purpose, so they are not left tidying up after you.

            'kind' is one of \(PaneOrder.kindList) and closes the pane showing that. Leave it out \
            to close the pane the reader is focused on.

            It refuses rather than leaving an empty window: the last pane standing stays. It will \
            not close the changed files or the notes, which are the reader's own rather than \
            yours. It closes one pane in your own workspace and takes no workspace argument.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(PaneKind.allCases.map { .string($0.rawValue) }),
                    "description": .string(
                        "Which pane to close. Omit for the one the reader is focused on."
                    ),
                ]),
            ]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure(
                "pane_close closes a pane in the workspace you are in, and this connection is not "
                    + "speaking for one."
            )
        }

        var kind: PaneKind?
        if let raw = request.stringParam("kind")?.trimmingCharacters(in: .whitespaces),
           !raw.isEmpty {
            guard let named = PaneKind(rawValue: raw) else {
                return .failure("Bloom has no pane called '\(raw)'. It opens \(PaneOrder.kindList).")
            }
            kind = named
        }

        switch await close(kind, workspaceID) {
        case .opened(let sentence): return BridgeToolResult(text: sentence)
        case .refused(let refusal): return .failure(refusal)
        }
    }
}
