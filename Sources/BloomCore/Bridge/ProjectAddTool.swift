import Foundation

/// `project_add`: registering a git repository that already exists as a Bloom project.
///
/// **Registering, and emphatically not creating.** The description and every refusal say so,
/// because the failure this tool has to design against is not a wrong path, it is a helpful agent:
/// told "add my projects", handed a folder git does not recognise and given a bare "not a git
/// repository", a model will reach for `git init` through its own Bash tool and make a repository
/// where the owner never asked for one, with whatever happened to be lying in the folder as its
/// first commit. `FolderRefusal.notARepositoryForAgent` is written to head that off in words
/// rather than to hope. Bloom has a whole sheet for turning a folder into a repository, with the
/// owner in front of it; the bridge does not get a shortcut past it.
///
/// **The rule is not this tool's.** It is `FolderVerdict.of`, which the owner's file panel asks
/// too. There were two lists of refusals for a while and they had already drifted: this one
/// refused one of Bloom's own worktrees and a home directory that happened to be a repository,
/// and the file panel registered both. What is left here is the half that is genuinely about
/// talking to a client, which is `agentSentence` instead of `sentence` and a JSON answer instead
/// of a window.
///
/// Owner only. A workspace agent works in the project it was started in, and a tool that let it
/// register another one would let it widen its own reach without anybody deciding to.
public struct ProjectAddTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "project_add",
        description: """
            Register a git repository that already exists as a project in Bloom, so workspaces \
            can be started in it. Takes the absolute path of the repository's folder.

            It only registers. It will not create a repository, and a folder that is not one \
            already is refused: do not run git init to make the call succeed, because whether a \
            folder should be a repository is the owner's decision. Adding a folder inside an \
            existing repository registers that repository, not the folder.

            Adding a project Bloom already has is not an error and changes nothing. This does not \
            copy, move or write anything inside the repository.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Absolute path of the git repository's folder, starting at / or ~."
                    ),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let path = request.stringParam("path")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return .failure("project_add needs the path of the git repository to register.")
        }

        let root: String
        switch await FolderVerdict.of(RepositoryStarter.inspect(path)) {
        case .alreadyRepository(let resolved):
            root = resolved
        case .refuse(let refusal):
            return .failure(refusal.agentSentence)
        case .offer:
            // The owner would be offered the sheet here. A client is not: see the head of this
            // file for what a model does with a bare "not a git repository".
            return .failure(FolderRefusal.notARepositoryForAgent(path: path))
        }

        do {
            // Asked before adding as well as answered after, so a repeat call can say plainly that
            // it changed nothing. `addRepository` is idempotent and returns the existing row, so
            // without this the second call would look exactly like the first.
            let known = try await store.repo(path: root) != nil

            let project = try await WorkspaceManager(store: store).addRepository(at: root)
            return .json(.object([
                "id": .string(project.id.rawValue),
                "name": .string(project.name),
                "path": .string(project.path),
                "default_branch": .string(project.defaultBranch),
                "state": .string(known ? "already_a_project" : "added"),
                "note": .string(
                    known
                        ? "Bloom already had this repository as a project. Nothing changed."
                        : "It is in Bloom's sidebar now. Start work in it with workspace_start."
                ),
            ]))
        } catch {
            return .failure("Bloom could not add that project: \(error.readableMessage)")
        }
    }
}
