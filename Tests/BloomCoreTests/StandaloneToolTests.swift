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

    /// `/tmp` is a symlink to `/private/tmp` on this machine, and a project registered through one
    /// used to be a miss when named through the other. The `bloom://` link resolved symlinks and
    /// this did not, which is the divergence that put them on one answer.
    @Test("a path reached through a symlink is the same project", .scratchDirectory)
    func byPathThroughASymlink() throws {
        let real = TestScratch.unique("real-project")
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let link = TestScratch.unique("linked-project")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        let project = Repo(name: "real", path: real, defaultBranch: "main")

        #expect(BridgeProjectLookup.project(atPath: link, in: [project]) == project)
        #expect(BridgeProjectLookup.find(link, in: [project]) == .found(project))
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
        #expect(FolderPath.resolved(projects[0].path) == FolderPath.resolved(repo.path))
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
        #expect(FolderPath.resolved(registered) == FolderPath.resolved(repo.path))
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

        let verdict = await FolderVerdict.of(
            RepositoryStarter.inspect(worktree, workspacesRoot: root)
        )

        guard case .refuse(let refusal) = verdict, case .insideBloomsWorkspaces = refusal else {
            Issue.record("expected the worktree to be refused, and got \(verdict)")
            return
        }
        #expect(refusal.agentSentence.contains("one of Bloom's own workspaces"))
    }

    @Test("the home folder is refused even where it is a repository")
    func refusesHome() async throws {
        let repo = try await TempRepo()

        let verdict = await FolderVerdict.of(RepositoryStarter.inspect(repo.path, home: repo.path))

        #expect(verdict == .refuse(.homeDirectory))
        #expect(FolderRefusal.homeDirectory.agentSentence.contains("your whole home folder"))
    }

    /// A near miss on the name of Bloom's worktree root must not be read as being inside it.
    @Test("a sibling of the workspaces folder is not inside it")
    func prefixIsNotContainment() {
        #expect(!FolderPath.isInside("/a/workspaces-old/x", of: "/a/workspaces"))
        #expect(FolderPath.isInside("/a/workspaces/x", of: "/a/workspaces"))
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
        // One workspace, and nothing running in it. This assertion used to read
        // `"workspaces_running" : 1` over the very same fixture, which is the bug written down:
        // there is no session here at all, so nothing was ever running. See
        // `BridgeWorkspaceCensus`.
        #expect(result.text.contains("\"workspaces\" : 1"))
        #expect(result.text.contains("\"agents_running\" : 0"))
        #expect(result.text.contains("\"awaiting_permission\" : 0"))
        #expect(!result.text.contains("workspaces_running"))
        // The folder was never made, which is exactly the case this field exists to report.
        #expect(result.text.contains("\"on_disk\" : false"))
    }

    /// The disagreement this pair was reported for: an agent told four projects had a workspace
    /// running, then read `workspace_list`, found nothing running anywhere, and reported the two
    /// tools as contradicting each other. Both read the same table; only the name was wrong.
    ///
    /// Asserted across both tools in one test rather than in each tool's own suite, because the
    /// property is a relation between them and a test that only ever calls one cannot see it.
    @Test("its counts are the rows workspace_list prints, for every project at once")
    func agreesWithWorkspaceList() async throws {
        let store = try makeTestStore("list-agrees")
        let quiet = try await store.upsert(
            Repo(name: "quiet", path: "/tmp/quiet", defaultBranch: "main")
        )
        let busy = try await store.upsert(
            Repo(name: "busy", path: "/tmp/busy", defaultBranch: "main")
        )
        // Two idle workspaces, which exist and are running nothing.
        for index in 1...2 {
            _ = try await store.upsert(Workspace(
                repoID: quiet.id, name: "idle \(index)", branch: "b\(index)",
                path: "/tmp/quiet/\(index)", baseBranch: "main"
            ))
        }
        // One with an agent mid turn, one archived, which is counted nowhere.
        let working = try await store.upsert(Workspace(
            repoID: busy.id, name: "working", branch: "b3", path: "/tmp/busy/3", baseBranch: "main"
        ))
        var turn = Session(workspaceID: working.id, title: "First chat")
        turn.apply(.turnStarted)
        _ = try await store.upsert(turn)
        _ = try await store.upsert(Workspace(
            repoID: busy.id, name: "finished", branch: "b4", path: "/tmp/busy/4",
            baseBranch: "main", state: .archived
        ))

        let projects = try #require(
            JSONValue.parse(
                await ProjectListTool().call(request, as: .owner, store: store).text
            )?["projects"]?.arrayValue
        )

        for row in projects {
            let name = try #require(row["name"]?.stringValue)
            let listing = await WorkspaceListTool().call(
                MCPRequest(
                    id: .number(2),
                    method: "workspace_list",
                    params: .object(["project": .string(name)])
                ),
                as: .owner,
                store: store
            )
            let workspaces = try #require(JSONValue.parse(listing.text)?["workspaces"]?.arrayValue)

            #expect(row["workspaces"]?.intValue == workspaces.count)
            #expect(
                row["agents_running"]?.intValue
                    == workspaces.count { $0["agent_running"]?.boolValue == true }
            )
        }

        let quietRow = try #require(projects.first { $0["name"]?.stringValue == "quiet" })
        let busyRow = try #require(projects.first { $0["name"]?.stringValue == "busy" })
        // Two workspaces and nothing running in either, which is the reading the old key made
        // unsayable.
        #expect(quietRow["workspaces"]?.intValue == 2)
        #expect(quietRow["agents_running"]?.intValue == 0)
        // One workspace, not two: the archived one is counted in neither number.
        #expect(busyRow["workspaces"]?.intValue == 1)
        #expect(busyRow["agents_running"]?.intValue == 1)
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
        // `.ownerClient`, and not `.agent`: this is the owner asking, so nothing about it is
        // penned in. It is not `.user` either, because a tool asked rather than a hand, and the
        // call that asked has to be nameable so a retry of it does not cut a second worktree.
        #expect(recorder.origins.count == 1)
        #expect(recorder.origins.first?.isOwnerClient == true)
        #expect(recorder.origins.first?.isAgentSpawned == false)
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

    /// The eight is a cap on how many children one agent may have RUNNING, and it is the wrong
    /// shape for the owner: their workspaces accumulate over weeks, and a ceiling on how many
    /// they may have would refuse the eleventh workspace of a busy fortnight. What the owner's
    /// client is held to is a rate, and that is `OwnerStartRateTests` below.
    @Test("the parent's ceiling on running children does not apply to the owner")
    func notCappedTheParentsWay() async throws {
        let store = try makeTestStore("owner-uncapped")
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        for index in 0...WorkspaceStartAllowance.maximumChildren {
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
        #expect(recorder.origins.first?.isOwnerClient == true)
    }

    /// The answer a parent gets names no tool a parent cannot call. The owner's names the one
    /// that answers the question `workspace_start` deliberately leaves open.
    @Test("the owner is told where to look next, and a parent is not told about a tool it lacks")
    func theOwnerIsPointedAtTheListing() async throws {
        let store = try makeTestStore("owner-note")
        _ = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))

        let result = await Recorder().tool().call(
            request(["prompt": .string("Import the webhooks"), "project": .string("flare")]),
            as: .owner,
            store: store
        )

        #expect(!result.isError)
        #expect(result.text.contains("cannot wait for it from here"))
        #expect(result.text.contains("workspace_list"))
    }
}

/// The brake on the owner's own client, which had none.
///
/// `workspace_start` was uncapped for the owner and deduplicated for nobody but a parent, on the
/// reasoning that the Create sheet is not capped either. The sheet needs one human gesture per
/// workspace and this tool needs none, so an owner-role client that misread "start a workspace
/// for each failing test" against a suite with forty of them cut forty worktrees and nothing said
/// no.
@Suite("workspace_start: not too fast", .tags(.persistence), .scratchDirectory)
struct OwnerStartRateTests {
    private final class Recorder: @unchecked Sendable {
        var origins: [WorkspaceOrigin] = []

        func tool() -> WorkspaceStartTool {
            WorkspaceStartTool { [self] order, _, _, origin in
                origins.append(origin)
                return StartedWorkspaceSummary(
                    workspaceID: WorkspaceID(rawValue: "w-\(origins.count)"),
                    name: order.name ?? "Named by Bloom",
                    branch: "claude/named-by-bloom",
                    path: "/tmp/worktrees/w-new"
                )
            }
        }
    }

    private func request(_ prompt: String) -> MCPRequest {
        MCPRequest(
            id: .number(1),
            method: "workspace_start",
            params: .object(["prompt": .string(prompt), "project": .string("flare")])
        )
    }

    /// Rows written the way the tool's own workspaces are written: a spawn id, and no parent.
    @discardableResult
    private func alreadyStarted(
        _ count: Int, in repo: Repo, store: Store, ago: TimeInterval = 60
    ) async throws -> [Workspace] {
        var written: [Workspace] = []
        for index in 0..<count {
            written.append(try await store.upsert(Workspace(
                repoID: repo.id,
                name: "earlier \(index)",
                branch: "claude/earlier-\(index)",
                path: "/tmp/earlier-\(index)",
                baseBranch: "main",
                createdAt: Date().addingTimeInterval(-ago),
                origin: .ownerClient(spawnToolUseID: "earlier-\(index)")
            )))
        }
        return written
    }

    private func fixture(_ label: String) async throws -> (Store, Repo) {
        let store = try makeTestStore(label)
        let repo = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        return (store, repo)
    }

    @Test("one short of the limit still starts")
    func underTheLimit() async throws {
        let (store, repo) = try await fixture("owner-rate-under")
        try await alreadyStarted(WorkspaceStartAllowance.maximumOwnerStarts - 1, in: repo, store: store)
        let recorder = Recorder()

        let result = await recorder.tool().call(request("one more"), as: .owner, store: store)

        #expect(!result.isError)
        #expect(recorder.origins.count == 1)
    }

    @Test("at the limit it is refused, and nothing is cut")
    func atTheLimit() async throws {
        let (store, repo) = try await fixture("owner-rate-at")
        try await alreadyStarted(WorkspaceStartAllowance.maximumOwnerStarts, in: repo, store: store)
        let recorder = Recorder()

        let result = await recorder.tool().call(request("one more"), as: .owner, store: store)

        #expect(result.isError)
        #expect(recorder.origins.isEmpty)
    }

    /// A model that has just been refused reads any mention of a window as a timer to wait out,
    /// and a model that waits and retries has turned a brake into a slower loop.
    @Test("the refusal says retrying will not help and says what to do instead")
    func theRefusalDoesNotInviteARetry() async throws {
        let (store, repo) = try await fixture("owner-rate-words")
        try await alreadyStarted(WorkspaceStartAllowance.maximumOwnerStarts, in: repo, store: store)

        let result = await Recorder().tool().call(request("one more"), as: .owner, store: store)

        #expect(result.text.contains("Calling again will be refused"))
        #expect(result.text.contains("do not retry and do not wait for it"))
        #expect(result.text.contains("Tell the owner what you have already started"))
        #expect(result.text.contains("15 minutes"))
        // No path inside Bloom, and no command line. See `WorkspaceStartTrouble`.
        #expect(!result.text.contains("/tmp/"))
        #expect(!result.text.contains("worktree add"))
    }

    /// Rolling, and not a ceiling. The workspaces of a busy fortnight are not a runaway.
    @Test("workspaces started before the window do not count")
    func theWindowRolls() async throws {
        let (store, repo) = try await fixture("owner-rate-rolls")
        try await alreadyStarted(
            WorkspaceStartAllowance.maximumOwnerStarts * 3,
            in: repo,
            store: store,
            ago: WorkspaceStartAllowance.ownerWindow + 60
        )
        let recorder = Recorder()

        let result = await recorder.tool().call(request("one more"), as: .owner, store: store)

        #expect(!result.isError)
        #expect(recorder.origins.count == 1)
    }

    /// The Create sheet needs a gesture per workspace, so its rows are not what this counts. A
    /// person who made a dozen by hand this morning must not find the tool refusing them one.
    @Test("workspaces made in Bloom's own window do not count against the tool")
    func handMadeWorkspacesDoNotCount() async throws {
        let (store, repo) = try await fixture("owner-rate-sheet")
        for index in 0..<(WorkspaceStartAllowance.maximumOwnerStarts * 2) {
            _ = try await store.upsert(Workspace(
                repoID: repo.id,
                name: "by hand \(index)",
                branch: "b\(index)",
                path: "/tmp/hand-\(index)",
                baseBranch: "main"
            ))
        }
        let recorder = Recorder()

        let result = await recorder.tool().call(request("one more"), as: .owner, store: store)

        #expect(!result.isError)
        #expect(recorder.origins.count == 1)
    }

    /// Archiving frees a parent's allowance, because that limit is on what is running. It does
    /// not free this one, because a worktree that was cut was cut.
    @Test("archiving one does not hand the allowance back")
    func archivingDoesNotFreeTheWindow() async throws {
        let (store, repo) = try await fixture("owner-rate-archived")
        let earlier = try await alreadyStarted(
            WorkspaceStartAllowance.maximumOwnerStarts, in: repo, store: store
        )
        for var workspace in earlier {
            workspace.state = .archived
            _ = try await store.upsert(workspace)
        }

        let result = await Recorder().tool().call(request("one more"), as: .owner, store: store)

        #expect(result.isError)
    }

    /// A retried call is the same call. It must answer with the workspace the first one made,
    /// and it must not be told it has hit a limit: a duplicate that looked like a refusal would
    /// send a model looking for a problem that is not there.
    @Test("a repeat of the same call answers with what it already made, and cuts nothing")
    func aRetryIsNotASecondStart() async throws {
        let (store, repo) = try await fixture("owner-rate-retry")
        let recorder = Recorder()
        _ = await recorder.tool().call(request("Import the webhooks"), as: .owner, store: store)
        let spawnID = try #require(recorder.origins.first?.spawnToolUseID)
        // What the app writes once the start has happened, which is what the second call finds.
        _ = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "Import the webhooks",
            branch: "claude/import-the-webhooks",
            path: "/tmp/import",
            baseBranch: "main",
            origin: .ownerClient(spawnToolUseID: spawnID)
        ))

        let again = await recorder.tool().call(
            request("Import the webhooks"), as: .owner, store: store
        )

        #expect(!again.isError)
        #expect(again.text.contains("already_started"))
        #expect(again.text.contains("Nothing new was created"))
        #expect(recorder.origins.count == 1)
    }

    /// The digest has to answer for the project too. The owner names one out loud, so the same
    /// prompt against two projects is two asks, and a key that ignored it would answer the second
    /// with the first one's workspace.
    @Test("the same prompt in another project is another call")
    func theProjectIsInTheKey() throws {
        let order = AgentWorkspaceOrder(prompt: "Import the webhooks")

        #expect(
            order.spawnID(ownerProject: RepoID("r1")) == order.spawnID(ownerProject: RepoID("r1"))
        )
        #expect(order.spawnID(ownerProject: RepoID("r1")) != order.spawnID(ownerProject: RepoID("r2")))
        #expect(
            order.spawnID(ownerProject: RepoID("r1"))
                != order.spawnID(parentWorkspaceID: WorkspaceID("r1"))
        )
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
