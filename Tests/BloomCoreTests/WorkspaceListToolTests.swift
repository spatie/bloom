import Foundation
import Testing
@testable import BloomCore

/// `workspace_list`: what became of the workspaces the owner's client started.
///
/// The suite is store only, exactly as the tool is. Nothing here reaches gh or git, so the GitHub
/// half is covered by what the default answer promises about itself rather than by a network call:
/// the sentence that says GitHub was not asked is the field a model acts on, and a model that
/// reports "no pull request" off a default call is the failure this tool has to design against.
@Suite("workspace_list", .tags(.persistence), .scratchDirectory)
struct WorkspaceListToolTests {
    private func request(_ arguments: [String: JSONValue] = [:]) -> MCPRequest {
        MCPRequest(id: .number(1), method: "workspace_list", params: .object(arguments))
    }

    private func answer(_ result: BridgeToolResult) throws -> JSONValue {
        try #require(JSONValue.parse(result.text))
    }

    private func workspaces(_ result: BridgeToolResult) throws -> [JSONValue] {
        try #require(answer(result)["workspaces"]?.arrayValue)
    }

    private func named(_ name: String, in result: BridgeToolResult) throws -> JSONValue {
        try #require(workspaces(result).first { $0["name"]?.stringValue == name })
    }

    // MARK: Who may call it

    /// A child reports and does nothing else, and a parent is deliberately left out for now: a
    /// cheap status call is a polling loop, and `workspace_start` tells a parent in as many words
    /// not to sit and wait.
    @Test("only the owner sees it")
    func roleGate() {
        let toolbox = BridgeToolbox(handlers: [WorkspaceListTool()])

        #expect(toolbox.tools(for: .parent).isEmpty)
        #expect(toolbox.tools(for: .child).isEmpty)
        #expect(toolbox.tools(for: .owner).map(\.name) == ["workspace_list"])
        #expect(toolbox.handler(named: "workspace_list", for: .parent) == nil)
    }

    @Test("it is served by a Bloom with no app behind it, because it needs no seam into one")
    func isInTheStandardToolbox() {
        #expect(BridgeToolbox.standard.tools(for: .owner).map(\.name).contains("workspace_list"))
    }

    // MARK: What it answers

    @Test("an empty Bloom says so rather than answering with nothing")
    func emptyBloom() async throws {
        let store = try makeTestStore("list-empty")

        let result = await WorkspaceListTool().call(request(), as: .owner, store: store)

        #expect(!result.isError)
        #expect(try workspaces(result).isEmpty)
        #expect(result.text.contains("Bloom has no workspaces."))
    }

    @Test("a workspace answers with the columns a caller can act on")
    func theFields() async throws {
        let store = try makeTestStore("list-fields")
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        var workspace = Workspace(
            repoID: repo.id,
            name: "group occurrences",
            branch: "claude/group-occurrences",
            path: "/tmp/worktrees/group-occurrences",
            baseBranch: "main",
            additions: 41,
            deletions: 7,
            changedFiles: 3
        )
        workspace.unread = true
        _ = try await store.upsert(workspace)

        let result = await WorkspaceListTool().call(request(), as: .owner, store: store)
        let row = try named("group occurrences", in: result)

        #expect(row["id"]?.stringValue == workspace.id.rawValue)
        #expect(row["branch"]?.stringValue == "claude/group-occurrences")
        #expect(row["base_branch"]?.stringValue == "main")
        // The path is the point: it is what lets the caller stop asking Bloom for a diff.
        #expect(row["path"]?.stringValue == "/tmp/worktrees/group-occurrences")
        #expect(row["state"]?.stringValue == "active")
        #expect(row["setup_state"]?.stringValue == "pending")
        #expect(row["unread"]?.boolValue == true)
        #expect(row["diff"]?["additions"]?.intValue == 41)
        #expect(row["diff"]?["deletions"]?.intValue == 7)
        #expect(row["diff"]?["changed_files"]?.intValue == 3)
        #expect(row["project"]?["name"]?.stringValue == "flare")
        #expect(row["project"]?["id"]?.stringValue == repo.id.rawValue)
        #expect(row["created_by"]?.stringValue == "owner")
        #expect(row["created_at"]?.stringValue?.isEmpty == false)
    }

    /// The one word the sidebar mark shows, resolved by `WorkspaceStatus` and not restated here.
    /// Four workspaces in four states in one answer, because a listing that could only describe an
    /// idle workspace would be describing the case nobody calls it for.
    @Test("workspaces in different states are told apart, in the sidebar's own vocabulary")
    func statesAreToldApart() async throws {
        let store = try makeTestStore("list-states")
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )

        _ = try await store.upsert(Workspace(
            repoID: repo.id, name: "idle", branch: "b1", path: "/tmp/w1", baseBranch: "main"
        ))

        var changed = Workspace(
            repoID: repo.id, name: "changed", branch: "b2", path: "/tmp/w2", baseBranch: "main",
            additions: 12, deletions: 1, changedFiles: 2
        )
        changed.apply(.runFinished(succeeded: true, log: "ok"))
        _ = try await store.upsert(changed)

        var settingUp = Workspace(
            repoID: repo.id, name: "setting up", branch: "b3", path: "/tmp/w3", baseBranch: "main"
        )
        settingUp.apply(.runStarted)
        _ = try await store.upsert(settingUp)

        let busy = try await store.upsert(Workspace(
            repoID: repo.id, name: "busy", branch: "b4", path: "/tmp/w4", baseBranch: "main"
        ))
        var running = Session(workspaceID: busy.id, title: "First chat")
        running.apply(.turnStarted)
        _ = try await store.upsert(running)

        let blocked = try await store.upsert(Workspace(
            repoID: repo.id, name: "blocked", branch: "b5", path: "/tmp/w5", baseBranch: "main"
        ))
        var waiting = Session(workspaceID: blocked.id, title: "First chat")
        waiting.apply(.turnStarted)
        waiting.apply(.blocked)
        _ = try await store.upsert(waiting)

        let result = await WorkspaceListTool().call(request(), as: .owner, store: store)

        #expect(try named("idle", in: result)["status"]?.stringValue == WorkspaceStatus.clean.rawValue)
        #expect(try named("changed", in: result)["status"]?.stringValue == WorkspaceStatus.changed.rawValue)
        #expect(try named("setting up", in: result)["status"]?.stringValue == WorkspaceStatus.settingUp.rawValue)
        #expect(try named("busy", in: result)["status"]?.stringValue == WorkspaceStatus.running.rawValue)
        #expect(try named("busy", in: result)["agent_running"]?.boolValue == true)
        #expect(try named("blocked", in: result)["status"]?.stringValue == WorkspaceStatus.awaitingPermission.rawValue)
        #expect(try named("blocked", in: result)["awaiting_permission"]?.boolValue == true)
        #expect(try named("blocked", in: result)["status_label"]?.stringValue == WorkspaceStatus.awaitingPermission.label)
        #expect(try named("idle", in: result)["agent_running"]?.boolValue == false)
    }

    /// Quoted from `DeliveryHold`, which is the gate the composer and the drain both ask. A second
    /// copy of that reasoning here is a second copy to drift.
    @Test("a queued message carries the hold's own sentence for why it is not moving")
    func theHoldIsQuoted() async throws {
        let store = try makeTestStore("list-hold")
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "busy",
            branch: "b",
            path: "/tmp/w",
            baseBranch: "main",
            setupState: .running
        ))
        var session = Session(workspaceID: workspace.id, title: "First chat")
        session.apply(.turnStarted)
        _ = try await store.upsert(session)
        _ = try await store.enqueueDelivery(
            Delivery(targetSessionID: session.id, body: "and one more thing")
        )

        let result = await WorkspaceListTool().call(request(), as: .owner, store: store)
        let row = try named("busy", in: result)
        let chat = try #require(row["sessions"]?[0])

        #expect(row["queued_messages"]?.intValue == 1)
        #expect(chat["queued_messages"]?.intValue == 1)
        #expect(chat["hold_note"]?.stringValue == DeliveryHold.setup.sentence(on: .claudeCode))
        #expect(chat["state"]?.stringValue == "running")
        #expect(chat["title"]?.stringValue == "First chat")
        #expect(chat["agent"]?.stringValue == AgentKind.claudeCode.rawValue)
    }

    /// **This test used to assert the opposite**, with a running turn producing "Goes when this
    /// turn ends". It does not any more, and the note going quiet is the honest half: a message a
    /// caller sends into a running Claude Code chat goes into that turn rather than waiting behind
    /// it, so a note telling the caller to wait would be this tool asking for a delay it does not
    /// need. `queued_messages` still says what is in front of it.
    @Test("a running turn holds nothing to say on a backend that takes a message mid turn")
    func aRunningTurnSaysNothing() async throws {
        let store = try makeTestStore("list-hold-mid-turn")
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "busy", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        var session = Session(workspaceID: workspace.id, title: "First chat")
        session.apply(.turnStarted)
        _ = try await store.upsert(session)

        let result = await WorkspaceListTool().call(request(), as: .owner, store: store)
        let row = try named("busy", in: result)
        let chat = try #require(row["sessions"]?[0])

        #expect(chat["state"]?.stringValue == "running")
        #expect(chat["hold_note"] == nil)
        #expect(AgentKind.claudeCode.acceptsMidTurnMessage)
    }

    /// A workspace stopped on a question is the one state that gets worse the longer it is left,
    /// so the listing says what was asked rather than only that something was.
    @Test("an unanswered question is named, with the tool and the summary the CLI sent")
    func theQuestionIsNamed() async throws {
        let store = try makeTestStore("list-question")
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "blocked", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        var session = Session(workspaceID: workspace.id, title: "First chat")
        session.apply(.turnStarted)
        session.apply(.blocked)
        _ = try await store.upsert(session)
        let ask = try #require(PermissionAsk.decode(payload: Data(PermissionAskTests.realAsk.utf8)))
        try await store.appendPermissionAsk(sessionID: session.id, ask: ask)

        let result = await WorkspaceListTool().call(request(), as: .owner, store: store)
        let question = try #require(named("blocked", in: result)["sessions"]?[0]?["questions"]?[0])

        #expect(question["tool"]?.stringValue == ask.label)
        #expect(question["summary"]?.stringValue == ask.summary)
    }

    @Test("who asked for it is told the same way whoami tells it")
    func parentageIsReported() async throws {
        let store = try makeTestStore("list-parentage")
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        let parent = try await store.upsert(Workspace(
            repoID: repo.id, name: "parent", branch: "b1", path: "/tmp/w1", baseBranch: "main"
        ))
        _ = try await store.upsert(Workspace(
            repoID: repo.id, name: "child", branch: "b2", path: "/tmp/w2", baseBranch: "main",
            origin: .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_01")
        ))
        _ = try await store.upsert(Workspace(
            repoID: repo.id, name: "from a client", branch: "b3", path: "/tmp/w3", baseBranch: "main",
            origin: .ownerClient(spawnToolUseID: "toolu_02")
        ))

        let result = await WorkspaceListTool().call(request(), as: .owner, store: store)

        #expect(try named("parent", in: result)["created_by"]?.stringValue == "owner")
        #expect(try named("from a client", in: result)["created_by"]?.stringValue == "owner")
        let child = try named("child", in: result)
        #expect(child["created_by"]?["agent_in_workspace"]?.stringValue == parent.id.rawValue)
        #expect(child["created_by"]?["spawn_tool_use_id"]?.stringValue == "toolu_01")
    }

    // MARK: What it leaves out, and says it left out

    /// The refusal this tool exists to head off. A model that called this and then told the owner
    /// "none of them have a pull request" would be reporting the absence of a question as the
    /// absence of an answer.
    @Test("the default answer says GitHub was not asked")
    func theDefaultSaysItDidNotLook() async throws {
        let store = try makeTestStore("list-nogithub")
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        _ = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))

        let result = await WorkspaceListTool().call(request(), as: .owner, store: store)

        #expect(result.text.contains("GitHub was not asked"))
        #expect(result.text.contains("include_github"))
        #expect(try named("w", in: result)["pull_request"] == nil)
    }

    @Test("the description says what the default price does not buy")
    func theDescriptionSaysWhatItDoesNotInclude() {
        let description = WorkspaceListTool().tool.description

        #expect(description.contains("GitHub is not consulted"))
        #expect(description.contains("do not report that a workspace has no pull request"))
        #expect(description.contains("slow on a long list"))
        #expect(description.contains("Read only"))
    }

    @Test("archived workspaces are out by default and in when asked for")
    func archived() async throws {
        let store = try makeTestStore("list-archived")
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        _ = try await store.upsert(Workspace(
            repoID: repo.id, name: "live", branch: "b1", path: "/tmp/w1", baseBranch: "main"
        ))
        var gone = Workspace(
            repoID: repo.id, name: "gone", branch: "b2", path: "/tmp/w2", baseBranch: "main"
        )
        gone.archive()
        _ = try await store.upsert(gone)

        let byDefault = await WorkspaceListTool().call(request(), as: .owner, store: store)
        let withArchived = await WorkspaceListTool().call(
            request(["include_archived": .bool(true)]), as: .owner, store: store
        )

        #expect(try workspaces(byDefault).count == 1)
        #expect(byDefault.text.contains("Archived workspaces are not in this list."))
        #expect(try workspaces(withArchived).count == 2)
        #expect(try named("gone", in: withArchived)["state"]?.stringValue == "archived")
    }

    // MARK: Naming a project

    @Test("a named project narrows it, and the name is resolved the way every other tool does")
    func narrowingByProject() async throws {
        let store = try makeTestStore("list-project")
        let flare = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        let bloom = try await store.upsert(
            Repo(name: "bloom", path: "/tmp/bloom", defaultBranch: "main")
        )
        _ = try await store.upsert(Workspace(
            repoID: flare.id, name: "in flare", branch: "b1", path: "/tmp/w1", baseBranch: "main"
        ))
        _ = try await store.upsert(Workspace(
            repoID: bloom.id, name: "in bloom", branch: "b2", path: "/tmp/w2", baseBranch: "main"
        ))

        let byName = await WorkspaceListTool().call(
            request(["project": .string("FLARE")]), as: .owner, store: store
        )
        let byPath = await WorkspaceListTool().call(
            request(["project": .string("/tmp/bloom/")]), as: .owner, store: store
        )

        #expect(try workspaces(byName).map { $0["name"]?.stringValue } == ["in flare"])
        #expect(try workspaces(byPath).map { $0["name"]?.stringValue } == ["in bloom"])
    }

    /// Refused in `BridgeProjectLookup`'s existing words, which name what Bloom does have. A
    /// caller told only "no such project" guesses, and every guess is another call.
    @Test("a project Bloom does not have is refused, and told what it does have")
    func unknownProject() async throws {
        let store = try makeTestStore("list-unknown")
        _ = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))

        let result = await WorkspaceListTool().call(
            request(["project": .string("flair")]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("'flare'"))
    }

    @Test("a project with nothing in it says so rather than answering with an empty list alone")
    func emptyProject() async throws {
        let store = try makeTestStore("list-empty-project")
        _ = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))

        let result = await WorkspaceListTool().call(
            request(["project": .string("flare")]), as: .owner, store: store
        )

        #expect(!result.isError)
        #expect(result.text.contains("no workspaces in 'flare'"))
    }
}
