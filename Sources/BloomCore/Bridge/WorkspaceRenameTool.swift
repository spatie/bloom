import Foundation

/// Why `workspace_rename` would not act, in terms a model can act on.
///
/// Built to the standard `WorkspaceStartTrouble` and `QuickPromptTrouble` set, and for the same
/// reason: a model told "invalid input" tries the same call again. Every sentence names the
/// argument that was wrong, says whether retrying unchanged can help, and says what would have
/// worked instead.
public enum WorkspaceRenameTrouble: Error, Sendable, Equatable {
    /// No `name`, or nothing but whitespace in it.
    case noName
    /// A workspace agent named a workspace. Its own is the only one it may act in.
    case namedAnother(String)
    /// The owner's own client named none, and it is sitting in none either.
    case noWorkspaceNamed
    /// A name or an id that matches nothing. Carries what there is, so the next call can be right
    /// rather than another guess.
    case unknown(given: String, known: [String])
    /// Two workspaces answer to that name. Carries their ids, because that is the argument that
    /// cannot be ambiguous.
    case ambiguous(given: String, ids: [String])
    /// A caller with no workspace on its token reached the parent arm, which the role gate is
    /// supposed to make impossible. Answered rather than trusted, the way `pane_rename` answers it.
    case notInAWorkspace
    /// The row went away between being found and being written.
    case gone
    /// Anything the store threw, said plainly.
    case unexplained(String)

    public var sentence: String {
        switch self {
        case .noName:
            return """
                workspace_rename needs the 'name' to give the workspace, and it cannot be blank. \
                A workspace with no name is a row in the sidebar nobody can pick out, and there is \
                no field on this side of the socket to type one back into. Pass the name you want \
                it to have.
                """

        case .namedAnother(let given):
            return """
                workspace_rename renames the workspace you are in, which is the only one you may \
                act in, so it takes no 'workspace' argument. '\(given)' is not something this call \
                can change. Ask again without it.
                """

        case .noWorkspaceNamed:
            return """
                workspace_rename needs to be told which workspace to rename, because this \
                connection is not sitting in one. Pass 'workspace' with the name or the id \
                workspace_list prints.
                """

        case let .unknown(given, known):
            guard !known.isEmpty else {
                return """
                    Bloom has no workspaces at all, so there is nothing called '\(given)' to \
                    rename. Retrying will not change that.
                    """
            }
            return """
                Bloom has no workspace called '\(given)'. It has \
                \(BridgeWorkspaceLookup.list(known)). Retrying with the same name will fail the \
                same way: call workspace_list and pass a name or an id from its answer.
                """

        case let .ambiguous(given, ids):
            return """
                \(ids.count) workspaces are called '\(given)', so renaming one of them would be \
                renaming a workspace you did not name. Pass the id instead, which workspace_list \
                prints: \(BridgeWorkspaceLookup.list(ids)).
                """

        case .notInAWorkspace:
            return """
                workspace_rename renames the workspace you are in, and this connection is not \
                speaking for one.
                """

        case .gone:
            return """
                That workspace is no longer in Bloom, so nothing was renamed. Its row has gone, \
                which retrying will not undo.
                """

        case .unexplained(let message):
            return "Bloom could not rename that workspace: \(message)"
        }
    }
}

/// `workspace_rename`: give a workspace the name the work in it turned out to be about.
///
/// ## The report that produced it
///
/// An agent nine commits into an app redesign found its workspace still called "test", which is
/// what the owner had typed into the create window before either of them knew what the branch would
/// become. It had `pane_rename` for a tab and `workspace_start` takes a name for a workspace that
/// does not exist yet, and there was nothing for the one it was standing in, so it stopped and
/// asked the owner to double click the row in the sidebar. That is a person interrupted for a
/// label, and the sidebar was lying about what was in the worktree until they got round to it.
///
/// The name is worth more than a tab's is, which is the argument for having this at all rather
/// than treating it as `pane_rename`'s smaller cousin. A tab is furniture inside one workspace; a
/// workspace's name is what the sidebar, Home, the notifications, the Dock badge's tooltip and
/// every one of these tools calls it, and it is the only thing a person scanning twelve rows reads.
///
/// ## Who may call it
///
/// `.parent` and `.owner`, and they are shaped differently on purpose.
///
/// A parent renames **its own** workspace and takes no argument saying which, exactly as the pane
/// family does: the token says which workspace is asking, so there is nothing to forge, mistype or
/// hold on to after it has gone stale. A `workspace` argument from a parent is refused rather than
/// ignored, which is the rule `workspace_start` already applies to `project`: a call that named
/// another workspace and quietly got this one would look like it worked.
///
/// The owner's client must name one, because it is sitting in no workspace and nothing else says
/// which. That is not a widening of `BridgeRole.owner`'s "nothing scoped to a workspace": that
/// clause is about what can be implied on its behalf, and `reveal` and `workspace_merge` are both
/// already tools that owner calls by naming a workspace out loud.
///
/// Not `.child`. A child reports and that is all, here as everywhere, and a child is a workspace
/// an agent asked for with a name that agent chose in the same breath.
///
/// ## Why it is self-approved
///
/// It is on `BridgeToolApproval.selfApproved`, and the test is the one that list applies to
/// everything on it: what would a person weigh, and can they undo it.
///
/// There is nothing to weigh. It writes one column of one row, it destroys nothing, it moves no
/// file and it publishes nothing, and the change is on the screen in front of the reader the
/// moment it lands, in the row they are looking at. Undoing it is a double click on that row and
/// typing the old name, which is where this began; and because the answer carries the previous
/// name back, undoing it from the far side of the socket is one more call with that string in it.
/// That is the property `quick_prompt_delete` is credited with and still refused for, and the
/// difference is what is being overwritten: a quick prompt is a paragraph the owner wrote by hand,
/// and a workspace name is a label Bloom itself proposed most of the time.
///
/// The cost of asking, on the other hand, is the whole of the reported bug. A parent runs
/// unattended, an unanswered ask hangs the turn, and a turn hung on a label is the failure
/// `BridgeToolApproval`'s own head describes: a feature whose first use hangs unless somebody
/// happens to be looking is a feature that does not work.
///
/// ## The race it does not have, and why
///
/// A workspace started from the create window with no name wears a plant codename while a model is
/// asked what to call it, and that answer can land seconds into the first turn, which is exactly
/// when an agent that has read the task is likeliest to call this. It cannot overwrite what this
/// wrote: `WorkspaceNaming.mayApplyName` compares the row's name against the exact placeholder
/// that was handed over, so any name that is not still the codename stops the automatic rename
/// dead. It was written for a person renaming the row while the model was thinking, and an agent
/// renaming it over the socket is the same event through another door.
public struct WorkspaceRenameTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.parent, .owner]

    public let tool = BridgeTool(
        name: "workspace_rename",
        description: """
            Rename a workspace. Use it when what the workspace turned out to be about is not what \
            it is called, which is most workspaces called 'test', 'fix' or after a branch that has \
            since grown. The name is what the sidebar, Home and every other tool here calls it, so \
            a wrong one is wrong everywhere.

            'name' is what to call it and is required. It cannot be blank.

            If you are working in a workspace, this renames yours and there is nothing else to \
            pass: do not name a workspace, it will be refused. From a client of the owner's own, \
            pass 'workspace' with the name or the id workspace_list prints, and a name two \
            workspaces share is refused rather than guessed at.

            It renames and nothing else. The branch, the worktree and the pull request keep the \
            names they have, and nothing on disk moves. It is not destructive: the answer carries \
            the name the workspace had, so calling again with that puts it back, and the owner can \
            double click the row in the sidebar and type over it.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("What to call the workspace."),
                ]),
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Which workspace to rename, by name or by the id workspace_list prints. "
                            + "Only from the owner's own client. An agent working in a workspace "
                            + "renames its own and must leave this out."
                    ),
                ]),
            ]),
            "required": .array([.string("name")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let name = WorkspaceName.given(request.stringParam("name")) else {
            return .failure(WorkspaceRenameTrouble.noName.sentence)
        }

        let workspace: Workspace
        switch await find(named: WorkspaceName.given(request.stringParam("workspace")),
                          as: identity, store: store) {
        case .failure(let trouble): return .failure(trouble.sentence)
        case .success(let found): workspace = found
        }

        // Nothing to write, and said so rather than reported as a rename. `InPlaceRename` discards
        // an unchanged name in the sidebar for the same reason: an identical UPDATE still fires the
        // store's update hook, so it would cost every observer a reload to change nothing. Not a
        // refusal, because the caller asked for a state the workspace is already in and got it.
        guard workspace.name != name else {
            return .json(answer(workspace: workspace, was: workspace.name, changed: false))
        }

        do {
            guard let renamed = try await store.update(workspaceID: workspace.id, { $0.name = name })
            else {
                return .failure(WorkspaceRenameTrouble.gone.sentence)
            }
            return .json(answer(workspace: renamed, was: workspace.name, changed: true))
        } catch {
            return .failure(WorkspaceRenameTrouble.unexplained(error.readableMessage).sentence)
        }
    }

    /// Which workspace this call is about, or why there is not one.
    ///
    /// The two arms are the two roles and they do not overlap: a parent may not name one and the
    /// owner's client must. Archived workspaces are included in what the owner may name, because
    /// the archive lists them by name too and a workspace somebody finished and mislabelled is
    /// exactly the one worth correcting; being told "there is no such workspace" about a row that
    /// is plainly on the screen is the worse answer.
    private func find(
        named: String?,
        as identity: BridgeIdentity,
        store: Store
    ) async -> Result<Workspace, WorkspaceRenameTrouble> {
        guard identity.role == .owner else {
            if let named { return .failure(.namedAnother(named)) }
            guard let workspaceID = identity.workspaceID else { return .failure(.notInAWorkspace) }
            do {
                guard let own = try await store.workspace(id: workspaceID) else {
                    return .failure(.gone)
                }
                return .success(own)
            } catch {
                return .failure(.unexplained(error.readableMessage))
            }
        }

        guard let named else { return .failure(.noWorkspaceNamed) }
        let workspaces: [Workspace]
        do {
            workspaces = try await store.workspaces(includeArchived: true)
        } catch {
            return .failure(.unexplained(error.readableMessage))
        }

        switch BridgeWorkspaceLookup.find(named, among: workspaces) {
        case .found(let workspace):
            return .success(workspace)
        case .unknown:
            return .failure(.unknown(given: named, known: workspaces.map(\.name)))
        case .ambiguous(let matches):
            return .failure(.ambiguous(given: named, ids: matches.map(\.id.rawValue)))
        }
    }

    /// What the caller is told, and the one field that makes this reversible.
    ///
    /// `previous_name` is not decoration. It is the whole of why this tool is self-approved: an
    /// undo that costs one call is what turns a write nobody was asked about into a write nobody
    /// needs to have been asked about. The note says so in words as well, because a model reading
    /// a field called `previous_name` does not necessarily read it as an offer.
    private func answer(workspace: Workspace, was: String, changed: Bool) -> JSONValue {
        .object([
            "workspace_id": .string(workspace.id.rawValue),
            "name": .string(workspace.name),
            "previous_name": .string(was),
            "branch": .string(workspace.branch),
            "renamed": .bool(changed),
            "note": .string(changed
                ? "The sidebar is showing '\(workspace.name)'. Nothing else moved: the branch is "
                    + "still '\(workspace.branch)' and so is the worktree. To put the old name "
                    + "back, call workspace_rename again with '\(was)'."
                : "It was already called '\(workspace.name)', so nothing was written."),
        ])
    }
}
