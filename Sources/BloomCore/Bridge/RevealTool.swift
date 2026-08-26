import Foundation

/// Moving the window's selection, which only the window can do.
///
/// One verb, like `WorkspaceTabSelecting` next to it: the seams that report carry none and the
/// seams that act carry exactly one. The name is resolved on this side of it, against the store,
/// so the app is handed an id and a sentence rather than a string to go looking for.
public typealias Revealing = @Sendable (Reveal) async -> RevealOutcome

/// `reveal`: point Bloom's window at a workspace, or at Home under a scope and a search.
///
/// ## Why this is the only verb Ask Bloom gained
///
/// The obvious missing tool is the one that cleans up. "Clean up the finished ones" is the second
/// thing anybody asks a chat that can see every workspace, and the honest answer to it is not an
/// archive tool. **Nothing on the bridge archives, deliberately:** archiving removes a worktree
/// and can offer up the branch with it, and the whole reason Bloom asks before archiving by hand
/// is that the answer is sometimes no. There is nobody on this connection to ask.
///
/// So the request ends here instead, with the eight candidates on screen, selected, and the owner
/// looking at them. It changes what is being looked at and one click puts it back, which is the
/// test `workspace_tab_select` already passes.
///
/// ## What it cannot do
///
/// It never creates what it navigates to, which is the rule `workspace_tab_select` argues at
/// length and this tool inherits whole: a workspace that is not there is a refusal carrying the
/// list of workspaces there are, never a workspace cut to satisfy the call. It archives nothing,
/// deletes nothing, and touches no file.
///
/// ## Why Bloom answers its own permission question for it
///
/// Because the alternative is worse than the risk. This is a selection change in the owner's own
/// window, asked for by the owner's own client, in a conversation the owner is sitting in front
/// of: what it costs is a glance, and the way back is a click. A prompt would put a question in
/// front of somebody who has just asked out loud to be shown something, and a hung ask is a hung
/// turn.
public struct RevealTool: BridgeToolHandling {
    private let reveal: Revealing

    public init(_ reveal: @escaping Revealing) {
        self.reveal = reveal
    }

    /// The owner and nobody else. A workspace agent moving the sidebar underneath somebody reading
    /// a different workspace is the interruption the whole pane family is scoped away from, and a
    /// child may not reach out of its worktree at all.
    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "reveal",
        description: """
            Point Bloom's window at something, exactly as clicking it in the sidebar would.

            Either name one workspace with 'workspace', or leave that out and narrow Home with \
            'project', 'scope' and 'search'. Not both: asking for a workspace and a Home narrowing \
            in the same call is refused rather than one of them quietly winning.

            It only ever selects what is already there. A name nothing answers to is refused with \
            the list of names there are; it will not create a workspace, and workspace_start is \
            what does that.

            This is how a request to tidy up ends. There is no tool that archives a workspace, on \
            purpose, because archiving removes a worktree and the answer to whether that is wanted \
            is sometimes no. Show the person the candidates and let them press the button.

            It changes what the person is looking at, so ask first if they are in the middle of \
            reading something.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Which workspace to show, by name or by the id workspace_list prints. "
                            + "Case does not matter. Refused when two workspaces share a name, so "
                            + "pass the id for those. Cannot be combined with the three below."
                    ),
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Narrow Home to one project, by name or by path, as project_list prints "
                            + "them."
                    ),
                ]),
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array(RevealChoice.offered.map { .string($0.rawValue) }),
                    "description": .string(
                        "Which of Home's chips to light: all, needsYou, running, live or archived."
                    ),
                ]),
                "search": .object([
                    "type": .string("string"),
                    "description": .string(
                        "What to type into Home's search field. It matches workspace names, "
                            + "branches, projects and what agents have said."
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
        let order: RevealOrder
        switch RevealChoice.parse(
            workspace: request.param("workspace"),
            project: request.param("project"),
            scope: request.param("scope"),
            search: request.param("search")
        ) {
        case .failure(let refusal): return .failure(refusal.sentence)
        case .success(let parsed): order = parsed
        }

        // Read in the same turn as the call, for the reason `workspace_tab_select` resolves its
        // number here: a workspace archived since the last listing would otherwise be revealed by
        // an id naming a row that has gone.
        let workspaces = (try? await store.workspaces()) ?? []
        let projects = (try? await store.repos()) ?? []

        let resolved: Reveal
        switch RevealChoice.resolve(order, workspaces: workspaces, projects: projects) {
        case .failure(let refusal): return .failure(refusal.sentence)
        case .success(let found): resolved = found
        }

        switch await reveal(resolved) {
        case .revealed(let sentence): return BridgeToolResult(text: sentence)
        case .refused(let sentence): return .failure(sentence)
        }
    }
}
