import CryptoKit
import Foundation

/// What an agent asked Bloom to start, once the arguments have been read and checked.
///
/// A value rather than a dictionary handed onwards, so the checking happens once, here, and the
/// app side receives something that cannot be malformed. `WorkspaceStartRequest` is the seam this
/// eventually becomes; this is the tool's half of the translation.
public struct AgentWorkspaceOrder: Sendable, Hashable {
    public let prompt: String
    /// Nil lets Bloom name it the way it names any other workspace.
    public let name: String?
    public let baseBranch: String?
    /// Nil inherits whatever the calling session is using, which is almost always what is wanted:
    /// an agent asking for help wants help from the thing it already trusts.
    public let agent: AgentKind?

    public init(prompt: String, name: String? = nil, baseBranch: String? = nil, agent: AgentKind? = nil) {
        self.prompt = prompt
        self.name = name
        self.baseBranch = baseBranch
        self.agent = agent
    }
}

/// What the tool answers with once the workspace exists.
///
/// Deliberately small, and deliberately not a status. The call returns the moment the worktree and
/// the row exist; setup and the first turn are still ahead of it. Anything richer would invite the
/// caller to read it as "finished".
public struct StartedWorkspaceSummary: Sendable, Hashable {
    public let workspaceID: WorkspaceID
    public let name: String
    public let branch: String
    public let path: String

    public init(workspaceID: WorkspaceID, name: String, branch: String, path: String) {
        self.workspaceID = workspaceID
        self.name = name
        self.branch = branch
        self.path = path
    }
}

extension AgentWorkspaceOrder {
    /// A name for this call that a repeat of it would produce again.
    ///
    /// `WorkspaceOrigin.spawnToolUseID` is documented as the thing that stops a retried spawn
    /// cutting a second worktree, and it could not do that job while it was a fresh UUID: two
    /// identical calls produced two ids and therefore two worktrees. **MCP does not carry the
    /// model's `tool_use` id to the server**, so the real one is not available to record and no
    /// amount of plumbing inside Bloom will make it appear.
    ///
    /// What is available is the call itself, and a retry is by definition the same call. Digesting
    /// it gives an id that repeats exactly when the thing it names repeats, which is the property
    /// the column was added for. The parent is in the digest so two workspaces asking for the same
    /// thing are two spawns, which they are.
    ///
    /// Truncated to sixteen hex characters. It is a dedup key inside one database, not a
    /// cryptographic commitment, and sixty-four characters of hex in a debug print helps nobody.
    func spawnID(parentWorkspaceID: WorkspaceID) -> String {
        let material = [
            parentWorkspaceID.rawValue,
            prompt,
            name ?? "",
            baseBranch ?? "",
            agent?.rawValue ?? "",
        ].joined(separator: "\u{0}")

        let digest = SHA256.hash(data: Data(material.utf8))

        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Starting a workspace, as the app does it.
///
/// Injected rather than called, because the tool runs off the main actor on a background task per
/// connection, and everything that makes a workspace actually *run* lives in the main-actor UI
/// graph: the model that streams setup into the transcript and sends the opening turn. A handler
/// that called `WorkspaceManager.start` on its own would create a worktree on disk that no agent
/// ever runs in, which is worse than refusing.
public typealias WorkspaceStarting =
    @Sendable (AgentWorkspaceOrder, BridgeIdentity, String) async throws -> StartedWorkspaceSummary

/// `workspace_start`: an agent asking Bloom for another workspace in the same project.
///
/// **Not `workspace_spawn`, and nothing here says "subagent".** A workspace an agent asked for is
/// an ordinary Bloom workspace with an ordinary agent in it, which is what `WorkspaceOrigin` says
/// in as many words and what the seam is called. The vocabulary is load-bearing: a name that
/// implied a lesser kind of workspace would be describing something Bloom does not have.
///
/// ## It returns before the work starts, on purpose
///
/// The call answers as soon as the worktree, the row and the session exist, which is seconds.
/// Setup and the opening turn run afterwards, under Bloom's own runners, while the caller carries
/// on with its own turn. Both keep running. Blocking until the child finished would hold the
/// caller's turn open for as long as the work took, and would hold this connection's serve loop
/// with it, so every later bridge call from that session would queue behind it.
///
/// ## Only a parent may call it
///
/// The role gate is the first lock and it hides the tool from a child's `tools/list` entirely, so
/// a child is never tempted by a tool it cannot use. The second lock is below: a caller whose own
/// workspace was started by an agent is refused even if it speaks raw MCP at the socket. One level
/// of nesting is the limit, and "has a parent" is the whole test, which is why there is no depth
/// counter to drift.
public struct WorkspaceStartTool: BridgeToolHandling {
    /// How many a single caller may have running at once.
    ///
    /// Not a safety limit, a sanity one: an agent that misreads its own instructions can ask for
    /// workspaces in a loop, and each one is a real worktree, a real process and real spend. Eight
    /// is more than anyone has wanted and small enough that a runaway is noticed rather than
    /// discovered on the next bill.
    public static let maximumChildren = 8

    private let start: WorkspaceStarting

    public init(start: @escaping WorkspaceStarting) {
        self.start = start
    }

    public let roles: Set<BridgeRole> = [.parent]

    public let tool = BridgeTool(
        name: "workspace_start",
        description: """
            Start another workspace in this project and give it a task. It is a real git worktree \
            on its own branch with its own agent, exactly like the one you are in, and it appears \
            in Bloom's sidebar for the owner to watch and review.

            Use it when a task splits into parts that do not need to see each other's edits, and \
            you want them worked on at the same time rather than one after another.

            It returns as soon as the workspace exists, not when its work is done. The new agent \
            starts on its own and keeps running while you carry on. There is no way to wait for \
            it from here, so do not ask for one and then sit idle: say what you started and get on \
            with your own work.

            The task you give it is all it gets. It cannot see this conversation, so write the \
            prompt as if to someone who has just opened the project for the first time.

            This costs real money and real disk. Start one because the work genuinely divides, \
            not to parallelise something you could do in a single pass. Only a workspace the owner \
            created can start others; a workspace that was itself started this way cannot.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The task, written for someone with no context beyond the project itself."
                    ),
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "What to call it in the sidebar. Leave it out and Bloom names it from the task."
                    ),
                ]),
                "base_branch": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Branch to cut from. Leave it out for the project's default branch."
                    ),
                ]),
                "agent": .object([
                    "type": .string("string"),
                    "enum": .array(AgentKind.runnable.map { .string($0.rawValue) }),
                    "description": .string(
                        "Which agent runs it. Leave it out to use the same one you are running on."
                    ),
                ]),
            ]),
            "required": .array([.string("prompt")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        // `params` here are already the call's arguments: the dispatch unwraps them so a handler
        // cannot forget to. See `BridgeDispatch.callTool`.
        guard let prompt = request.stringParam("prompt"),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure("workspace_start needs a prompt saying what the new workspace should do.")
        }

        // The second lock. The role gate already hid this tool from a child, so reaching here as
        // one means something spoke MCP at the socket directly.
        do {
            guard let caller = try await store.workspace(id: identity.workspaceID) else {
                return .failure("This workspace is no longer in Bloom's database.")
            }

            if caller.origin.isAgentSpawned {
                return .failure(
                    "This workspace was itself started by an agent, and those cannot start more. "
                        + "Do the work here, or report back and let the owner decide."
                )
            }

            if let refusal = try await tooMany(for: identity.workspaceID, store: store) {
                return .failure(refusal)
            }
        } catch {
            return .failure("Bloom could not read this workspace: \(error.readableMessage)")
        }

        let order = AgentWorkspaceOrder(
            prompt: prompt,
            name: filled(request.param("name")),
            baseBranch: filled(request.param("base_branch")),
            agent: agent(in: request)
        )

        if let requested = request.stringParam("agent"), order.agent == nil {
            return .failure(
                "Bloom cannot run '\(requested)'. It runs "
                    + AgentKind.runnable.map(\.rawValue).joined(separator: " and ")
                    + ". Leave the argument out to use the same agent you are running on."
            )
        }

        // A retry of the same call is the same call. See `AgentWorkspaceOrder.spawnID`.
        let spawnID = order.spawnID(parentWorkspaceID: identity.workspaceID)

        do {
            if let existing = try await alreadyStarted(spawnID: spawnID, store: store) {
                return .json(.object([
                    "workspace_id": .string(existing.id.rawValue),
                    "name": .string(existing.name),
                    "branch": .string(existing.branch),
                    "path": .string(existing.path),
                    "state": .string("already_started"),
                    "note": .string(
                        "You already asked for this one and it exists. Nothing new was created."
                    ),
                ]))
            }
        } catch {
            return .failure("Bloom could not check for a repeat of this call: \(error.readableMessage)")
        }

        do {
            let started = try await start(order, identity, spawnID)

            return .json(.object([
                "workspace_id": .string(started.workspaceID.rawValue),
                "name": .string(started.name),
                "branch": .string(started.branch),
                "path": .string(started.path),
                "state": .string("starting"),
                "note": .string(
                    "It is setting up and will start on its own. It does not report back, and you "
                        + "cannot wait for it from here. Carry on with your own work."
                ),
            ]))
        } catch {
            return .failure("Bloom could not start that workspace: \(error.readableMessage)")
        }
    }

    /// Whether this caller already has as many as it is allowed.
    ///
    /// Counted from the database rather than kept in memory, so it survives Bloom being reopened
    /// while the children are still running, and so two calls racing cannot both see the same
    /// stale number. Archived ones do not count: the limit is on what is running.
    private func tooMany(for workspaceID: WorkspaceID, store: Store) async throws -> String? {
        let live = try await store.workspaces(startedBy: workspaceID)

        guard live.count >= Self.maximumChildren else { return nil }

        return "You already have \(live.count) workspaces running, which is Bloom's limit. "
            + "Wait for some to be reviewed and archived before starting more."
    }

    /// The workspace an earlier run of this same call produced, if there is one and it is still
    /// here. An archived one does not count: asking again after archiving is asking again.
    private func alreadyStarted(spawnID: String, store: Store) async throws -> Workspace? {
        try await store.workspaces(spawnToolUseID: spawnID).first { $0.state != .archived }
    }

    private func filled(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The requested agent, or nil for "use the caller's". An unrecognised name is also nil, and
    /// the caller above turns that into a refusal rather than silently choosing for it.
    private func agent(in request: MCPRequest) -> AgentKind? {
        guard let raw = request.stringParam("agent") else { return nil }
        guard let kind = AgentKind(rawValue: raw), kind.canRunWorkspaces else { return nil }
        return kind
    }
}
