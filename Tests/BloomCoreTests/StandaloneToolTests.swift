import Foundation
import Testing
@testable import BloomCore

/// Naming a project from outside Bloom, which no caller could do until the owner's own client
/// arrived and no caller inside a workspace is allowed to do now.
@Suite("Finding a project by name")
struct BridgeProjectLookupTests {
    private let flare = Repo(name: "flare", path: "/Users/me/dev/flare", defaultBranch: "main")
    private let bloom = Repo(name: "bloom", path: "/Users/me/dev/bloom", defaultBranch: "main")

    @Test("the name in the sidebar finds it, whatever case it is typed in")
    func byName() {
        #expect(BridgeProjectLookup.find("FLARE", in: [flare, bloom]) == .found(flare))
    }

    @Test("the path finds it, tilde and trailing slash and all")
    func byPath() {
        #expect(BridgeProjectLookup.find("/Users/me/dev/bloom/", in: [flare, bloom]) == .found(bloom))
        #expect(BridgeProjectLookup.find("/Users/me/dev/./flare", in: [flare, bloom]) == .found(flare))
    }

    @Test("the id finds it, which is what whoami and project_list both print")
    func byID() {
        #expect(BridgeProjectLookup.find(flare.id.rawValue, in: [flare, bloom]) == .found(flare))
    }

    /// Two projects may be called the same thing, and picking whichever sorted first would put a
    /// worktree in the wrong repository.
    @Test("two projects with one name are refused rather than guessed between")
    func ambiguous() {
        let other = Repo(name: "flare", path: "/Users/me/work/flare", defaultBranch: "main")

        let outcome = BridgeProjectLookup.find("flare", in: [flare, other])

        #expect(outcome == .ambiguous([flare, other]))
        let refusal = BridgeProjectLookup.refusal(for: "flare", outcome: outcome, projects: [flare, other])
        #expect(refusal?.contains("/Users/me/dev/flare") == true)
        #expect(refusal?.contains("/Users/me/work/flare") == true)
    }

    /// A client told only "no such project" guesses, and every guess is another call.
    @Test("a miss names what Bloom does have and where to go next")
    func missNamesTheAlternatives() {
        let outcome = BridgeProjectLookup.find("flair", in: [flare, bloom])
        let refusal = BridgeProjectLookup.refusal(for: "flair", outcome: outcome, projects: [flare, bloom])

        #expect(refusal?.contains("'flare'") == true)
        #expect(refusal?.contains("project_add") == true)
        #expect(refusal?.contains("will not start a workspace in a repository it does not know") == true)
    }

    @Test("with nothing registered it says so rather than listing nothing")
    func emptyBloom() {
        let outcome = BridgeProjectLookup.find("flare", in: [])

        #expect(BridgeProjectLookup.refusal(for: "flare", outcome: outcome, projects: [])?
            .contains("no projects yet") == true)
    }
}

/// Registering a repository from the bridge, and the four ways a path can be wrong.
@Suite("project_add", .tags(.persistence, .subprocess), .scratchDirectory)
struct ProjectAddToolTests {
    private func request(_ path: String) -> MCPRequest {
        MCPRequest(id: .number(1), method: "project_add", params: .object(["path": .string(path)]))
    }

    @Test("only the owner sees it, because a workspace agent has a project already")
    func roleGate() {
        let toolbox = BridgeToolbox(handlers: [ProjectAddTool()])

        #expect(toolbox.tools(for: .parent).isEmpty)
        #expect(toolbox.tools(for: .child).isEmpty)
        #expect(toolbox.tools(for: .owner).map(\.name) == ["project_add"])
    }

    @Test("a repository is registered and turns up in Bloom's projects")
    func addsARepository() async throws {
        let store = try makeTestStore("add")
        let repo = try await TempRepo()

        let result = await ProjectAddTool().call(request(repo.path), as: .owner, store: store)

        #expect(!result.isError)
        #expect(result.text.contains("\"state\" : \"added\""))
        let projects = try await store.repos()
        #expect(projects.count == 1)
        #expect(ProjectAddTrouble.resolved(projects[0].path) == ProjectAddTrouble.resolved(repo.path))
    }

    @Test("asking twice changes nothing and says so")
    func idempotent() async throws {
        let store = try makeTestStore("add-twice")
        let repo = try await TempRepo()
        _ = await ProjectAddTool().call(request(repo.path), as: .owner, store: store)

        let result = await ProjectAddTool().call(request(repo.path), as: .owner, store: store)

        #expect(!result.isError)
        #expect(result.text.contains("already_a_project"))
        #expect(try await store.repos().count == 1)
    }

    @Test("a folder inside a repository registers the repository, not the folder")
    func resolvesToTheTopLevel() async throws {
        let store = try makeTestStore("add-inner")
        let repo = try await TempRepo()
        let inner = repo.path + "/src/deep"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)

        _ = await ProjectAddTool().call(request(inner), as: .owner, store: store)

        let registered = try await store.repos().first?.path ?? ""
        #expect(ProjectAddTrouble.resolved(registered) == ProjectAddTrouble.resolved(repo.path))
    }

    /// The refusal this tool exists to get right. An agent handed a bare "not a git repository"
    /// reaches for `git init` through its own Bash tool, so the sentence has to head that off.
    @Test("a folder that is not a repository is refused, and told not to make one")
    func refusesANonRepository() async throws {
        let store = try makeTestStore("add-plain")
        let folder = TestScratch.unique("plain")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let result = await ProjectAddTool().call(request(folder), as: .owner, store: store)

        #expect(result.isError)
        #expect(result.text.contains("git does not recognise it as a repository"))
        #expect(result.text.contains("neither will running git init"))
        #expect(try await store.repos().isEmpty)
    }

    @Test("nothing at the path, a file at the path and a relative path each get their own answer")
    func distinguishesTheOtherThree() async throws {
        let store = try makeTestStore("add-bad")
        let missing = await ProjectAddTool().call(
            request(TestScratch.unique("gone")), as: .owner, store: store
        )
        let file = TestScratch.unique("file") + ".txt"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let notADirectory = await ProjectAddTool().call(request(file), as: .owner, store: store)
        let relative = await ProjectAddTool().call(request("dev/flare"), as: .owner, store: store)

        #expect(missing.text.contains("there is nothing at that path"))
        #expect(notADirectory.text.contains("is a file, not a folder"))
        #expect(relative.text.contains("not an absolute path"))
    }

    /// A worktree Bloom cut is not a project. Registering one would give Bloom a project whose
    /// workspaces are worktrees of a worktree.
    @Test("one of Bloom's own workspaces is refused")
    func refusesAWorktree() async throws {
        let repo = try await TempRepo()
        let root = TestScratch.unique("workspaces")
        let worktree = root + "/feature"
        try await Shell.check("git", ["worktree", "add", "-q", "-b", "feature", worktree], cwd: repo.path)

        let trouble = await ProjectAddTrouble.diagnose(path: worktree, workspacesRoot: root)

        guard case .insideBloomsWorkspaces = trouble else {
            Issue.record("expected the worktree to be refused, and got \(String(describing: trouble))")
            return
        }
        #expect(trouble?.sentence.contains("one of Bloom's own workspaces") == true)
    }

    @Test("the home folder is refused even where it is a repository")
    func refusesHome() async throws {
        let repo = try await TempRepo()

        let trouble = await ProjectAddTrouble.diagnose(path: repo.path, home: repo.path)

        guard case .tooBroad(_, let what) = trouble else {
            Issue.record("expected the home folder to be refused, and got \(String(describing: trouble))")
            return
        }
        #expect(what == "your whole home folder")
    }

    /// A near miss on the name of Bloom's worktree root must not be read as being inside it.
    @Test("a sibling of the workspaces folder is not inside it")
    func prefixIsNotContainment() {
        #expect(!ProjectAddTrouble.isInside("/a/workspaces-old/x", of: "/a/workspaces"))
        #expect(ProjectAddTrouble.isInside("/a/workspaces/x", of: "/a/workspaces"))
    }
}

@Suite("project_list", .tags(.persistence), .scratchDirectory)
struct ProjectListToolTests {
    private let request = MCPRequest(id: .number(1), method: "project_list", params: nil)

    @Test("only the owner sees it, because it names every repository the owner works on")
    func roleGate() {
        let toolbox = BridgeToolbox(handlers: [ProjectListTool()])

        #expect(toolbox.tools(for: .parent).isEmpty)
        #expect(toolbox.tools(for: .child).isEmpty)
        #expect(toolbox.tools(for: .owner).map(\.name) == ["project_list"])
    }

    @Test("an empty Bloom says what to do rather than answering with nothing")
    func empty() async throws {
        let store = try makeTestStore("list-empty")

        let result = await ProjectListTool().call(request, as: .owner, store: store)

        #expect(!result.isError)
        #expect(result.text.contains("project_add"))
    }

    @Test("each project carries what a caller needs to name it and to judge it")
    func lists() async throws {
        let store = try makeTestStore("list")
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        _ = try await store.upsert(Workspace(
            repoID: repo.id, name: "one", branch: "b1", path: "/tmp/one", baseBranch: "main"
        ))
        _ = try await store.upsert(Workspace(
            repoID: repo.id, name: "two", branch: "b2", path: "/tmp/two", baseBranch: "main",
            state: .archived
        ))

        let result = await ProjectListTool().call(request, as: .owner, store: store)

        #expect(result.text.contains("\"name\" : \"flare\""))
        #expect(result.text.contains("\"default_branch\" : \"main\""))
        // One running, because the limit and the reading are both about what is live.
        #expect(result.text.contains("\"workspaces_running\" : 1"))
        // The folder was never made, which is exactly the case this field exists to report.
        #expect(result.text.contains("\"on_disk\" : false"))
    }
}

/// `workspace_start` reached by the owner's own client, which names a project and has no
/// workspace of its own.
@Suite("workspace_start from outside Bloom", .tags(.persistence), .scratchDirectory)
struct OwnerWorkspaceStartTests {
    private final class Recorder: @unchecked Sendable {
        var projects: [Repo] = []
        var origins: [WorkspaceOrigin] = []

        func tool() -> WorkspaceStartTool {
            WorkspaceStartTool { [self] order, project, _, origin in
                projects.append(project)
                origins.append(origin)
                return StartedWorkspaceSummary(
                    workspaceID: WorkspaceID(rawValue: "w-new"),
                    name: order.name ?? "Named by Bloom",
                    branch: "claude/named-by-bloom",
                    path: "/tmp/worktrees/w-new"
                )
            }
        }
    }

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .number(1), method: "workspace_start", params: .object(arguments))
    }

    @Test("a named project is resolved and the workspace is recorded as the owner's own")
    func startsInANamedProject() async throws {
        let store = try makeTestStore("owner-start")
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("Import the webhooks"), "project": .string("flare")]),
            as: .owner,
            store: store
        )

        #expect(!result.isError)
        #expect(recorder.projects.map(\.id) == [repo.id])
        // `.user`, and not `.agent`: this is the owner asking, so it is indistinguishable from a
        // workspace made in the Create sheet, which is what it is.
        #expect(recorder.origins == [.user])
    }

    @Test("a call with no project is refused, because nothing else says where the work goes")
    func needsAProject() async throws {
        let store = try makeTestStore("owner-noproject")
        _ = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing")]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("project_list"))
        #expect(recorder.projects.isEmpty)
    }

    @Test("a project Bloom does not have is refused, and nothing is registered on the way")
    func onlyKnownProjects() async throws {
        let store = try makeTestStore("owner-unknown")
        _ = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing"), "project": .string("/Users/me/somewhere-else")]),
            as: .owner,
            store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("no project called"))
        #expect(recorder.projects.isEmpty)
        #expect(try await store.repos().count == 1)
    }

    /// A workspace agent's project is decided for it. A call that named another one and quietly
    /// got its own would look like it worked.
    @Test("a caller inside a workspace may not name a project")
    func aWorkspaceMayNotNameOne() async throws {
        let store = try makeTestStore("owner-parent-names")
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "chat"))
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing"), "project": .string("flare")]),
            as: BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .parent),
            store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("does not take a project here"))
        #expect(recorder.projects.isEmpty)
    }

    /// The eight is a cap on what one agent can ask for on its own initiative. The owner is not
    /// an agent and the Create sheet is not capped either.
    @Test("the owner is not capped the way a parent's workspaces are")
    func notCapped() async throws {
        let store = try makeTestStore("owner-uncapped")
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        for index in 0...WorkspaceStartTool.maximumChildren {
            _ = try await store.upsert(Workspace(
                repoID: repo.id, name: "w\(index)", branch: "b\(index)",
                path: "/tmp/w\(index)", baseBranch: "main"
            ))
        }
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("one more"), "project": .string("flare")]),
            as: .owner,
            store: store
        )

        #expect(!result.isError)
        #expect(recorder.origins == [.user])
    }
}

@Suite("whoami from outside Bloom", .tags(.persistence), .scratchDirectory)
struct OwnerWhoamiTests {
    /// Bloom and Bloom Dev both listen, on their own sockets, and a configuration pointing at the
    /// wrong one works perfectly in the wrong database. Naming the database is what tells them
    /// apart.
    @Test("it names the copy of Bloom that answered and what it is holding")
    func namesTheDatabase() async throws {
        let store = try makeTestStore("whoami-owner")
        _ = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))

        let result = await WhoamiTool().call(
            MCPRequest(id: .number(1), method: "whoami", params: nil), as: .owner, store: store
        )

        #expect(!result.isError)
        #expect(result.text.contains("\"role\" : \"owner\""))
        #expect(result.text.contains(store.path))
        #expect(result.text.contains("\"projects\" : 1"))
    }

    @Test("every role can ask it, which is what makes it the way to confirm a new connection")
    func everyRole() {
        #expect(WhoamiTool().roles == [.parent, .child, .owner])
    }
}
