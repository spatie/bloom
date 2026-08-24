import Foundation
import Testing
@testable import BloomCore

/// `workspace_merge`: asking a workspace's agent to land its pull request.
///
/// The suite is store only. GitHub is the injected `Reading`, so every refusal that depends on
/// what GitHub said can be pinned without a network, a repository or gh being installed, and the
/// send is an injected `WorkspaceMergeRequesting` that records what it was handed. What the far
/// side of that closure does with it is `WorkspaceModel.requestMerge`, which is the strip's own
/// path and is not copied anywhere here; what this suite can and does prove is that the tool hands
/// it the pull request and the method unaltered, and that nothing the caller typed goes with them.
@Suite("workspace_merge", .tags(.persistence), .scratchDirectory)
struct WorkspaceMergeToolTests {
    // MARK: Building one

    /// What the tool was asked to send, if anything.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(Workspace, PullRequest, GitHub.MergeMethod)] = []

        func record(_ workspace: Workspace, _ pullRequest: PullRequest, _ method: GitHub.MergeMethod) {
            lock.lock()
            defer { lock.unlock() }
            calls.append((workspace, pullRequest, method))
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }

        var last: (workspace: Workspace, pullRequest: PullRequest, method: GitHub.MergeMethod)? {
            lock.lock()
            defer { lock.unlock() }
            return calls.last
        }
    }

    private func tool(
        reading: WorkspacePullRequestReading? = nil,
        handoff: WorkspaceMergeHandoff = .turnBegun(chat: "Merge"),
        sent: Sent = Sent()
    ) -> WorkspaceMergeTool {
        let reading = reading ?? .found(Self.open(), local: nil)
        return WorkspaceMergeTool(read: { _ in reading }) { workspace, pullRequest, method in
            sent.record(workspace, pullRequest, method)
            return handoff
        }
    }

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .number(1), method: "workspace_merge", params: .object(arguments))
    }

    private static func open(
        number: Int = 42,
        state: String = "OPEN",
        isDraft: Bool = false,
        mergeable: String? = nil,
        checks: PullRequest.Checks = .passing
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: "Group occurrences by fingerprint",
            url: "https://github.com/spatie/flare/pull/\(number)",
            state: state,
            isDraft: isDraft,
            mergeable: mergeable,
            checks: checks,
            checksSummary: "12 checks passed",
            branch: "claude/group-occurrences"
        )
    }

    /// A workspace whose worktree is really there, because the tool checks the disk before it
    /// asks GitHub anything and a path under /tmp that nobody made is a different refusal.
    private func workspace(
        in store: Store,
        name: String = "group occurrences",
        branch: String = "claude/group-occurrences"
    ) async throws -> Workspace {
        let repo = try await store.upsert(
            Repo(name: "flare", path: TestScratch.unique("flare"), defaultBranch: "main")
        )
        let path = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: branch, path: path, baseBranch: "main"
        ))
    }

    private func answer(_ result: BridgeToolResult) throws -> JSONValue {
        try #require(JSONValue.parse(result.text))
    }

    // MARK: Who may call it, and what it may be told

    /// Owner only. A parent merging its own child's work is an agent publishing an agent's work
    /// with the review nobody performed, and a parent is scoped to its own worktree besides.
    @Test("only the owner sees it")
    func roleGate() {
        let toolbox = BridgeToolbox(handlers: [tool()])

        #expect(toolbox.tools(for: .parent).isEmpty)
        #expect(toolbox.tools(for: .child).isEmpty)
        #expect(toolbox.tools(for: .owner).map(\.name) == ["workspace_merge"])
        #expect(toolbox.handler(named: "workspace_merge", for: .parent) == nil)
        #expect(toolbox.handler(named: "workspace_merge", for: .child) == nil)
    }

    /// It needs the app, so a `BridgeServer` built without one must not offer it. The alternative
    /// is a tool in `tools/list` that can only fail.
    @Test("it is not in the standard toolbox, because it needs a seam into the app")
    func isNotStandard() {
        #expect(!BridgeToolbox.standard.tools(for: .owner).map(\.name).contains("workspace_merge"))
    }

    /// The second half of the old objection: a tool that sends the merge prompt is mechanically a
    /// tool that puts text in somebody's chat. This one takes an id and a choice of three, and
    /// nothing else, so there is no text for a caller to steer it with.
    @Test("it takes no free text, so it cannot be used to say something else to an agent")
    func noFreeText() throws {
        let properties = try #require(tool().tool.inputSchema["properties"]?.objectValue)

        #expect(Set(properties.keys) == ["workspace", "method"])
        #expect(properties["method"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
            == GitHub.MergeMethod.allCases.map(\.rawValue))
    }

    @Test("it will not merge without being told which workspace")
    func needsAWorkspace() async throws {
        let store = try makeTestStore("merge-no-workspace")

        let result = await tool().call(request([:]), as: .owner, store: store)

        #expect(result.isError)
        #expect(result.text.contains("workspace_merge needs the workspace"))
        #expect(result.text.contains("workspace_list"))
    }

    @Test("a merge method Bloom does not have is refused by name rather than merged some other way")
    func unknownMethod() async throws {
        let store = try makeTestStore("merge-bad-method")
        let target = try await workspace(in: store)
        let sent = Sent()

        let result = await tool(sent: sent).call(
            request(["workspace": .string(target.id.rawValue), "method": .string("fast-forward")]),
            as: .owner,
            store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("'fast-forward'"))
        #expect(result.text.contains("'squash'"))
        #expect(sent.count == 0)
    }

    // MARK: The workspace itself

    /// Nothing in Bloom resolves a workspace by name, because two are allowed to share one. So a
    /// caller that typed a name is told which id it meant rather than that its workspace is gone.
    @Test("a name where an id belongs is answered with the id")
    func nameInsteadOfID() async throws {
        let store = try makeTestStore("merge-name")
        let target = try await workspace(in: store)

        let result = await tool().call(
            request(["workspace": .string("group occurrences")]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("is the NAME of a workspace"))
        #expect(result.text.contains(target.id.rawValue))
    }

    @Test("two workspaces sharing a name are why this takes an id, and the refusal says so")
    func ambiguousName() async throws {
        let store = try makeTestStore("merge-ambiguous")
        _ = try await workspace(in: store, name: "retry", branch: "a")
        _ = try await workspace(in: store, name: "retry", branch: "b")

        let result = await tool().call(
            request(["workspace": .string("retry")]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("2 workspaces are called 'retry'"))
    }

    @Test("an id that means nothing at all points at workspace_list")
    func unknownID() async throws {
        let store = try makeTestStore("merge-unknown")

        let result = await tool().call(
            request(["workspace": .string("nope")]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("Bloom has no workspace with the id 'nope'"))
        #expect(result.text.contains("workspace_list"))
    }

    @Test("an archived workspace has no worktree to merge from and no agent to ask")
    func archived() async throws {
        let store = try makeTestStore("merge-archived")
        var target = try await workspace(in: store)
        target.state = .archived
        _ = try await store.upsert(target)
        let sent = Sent()

        let result = await tool(sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("that workspace is archived"))
        #expect(result.text.contains("Retrying will not help"))
        #expect(sent.count == 0)
    }

    @Test("an active workspace whose worktree has gone is a thing to report, not to retry")
    func worktreeGone() async throws {
        let store = try makeTestStore("merge-no-worktree")
        let repo = try await store.upsert(
            Repo(name: "flare", path: TestScratch.unique("flare"), defaultBranch: "main")
        )
        let target = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "gone",
            branch: "b",
            path: TestScratch.unique("never-made"),
            baseBranch: "main"
        ))

        let result = await tool().call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("worktree is no longer on disk"))
        #expect(result.text.contains("Retrying will not help"))
    }

    // MARK: Anything that would queue rather than start

    /// The promise this call makes is "a turn has begun". A message that queues is not that, so
    /// every hold `DeliveryHold` knows about is a refusal here rather than a queued message and a
    /// cheerful answer.
    @Test("a workspace mid turn is told to wait, and nothing is sent")
    func midTurn() async throws {
        let store = try makeTestStore("merge-mid-turn")
        let target = try await workspace(in: store)
        var session = Session(workspaceID: target.id, title: "First chat")
        session.apply(.turnStarted)
        _ = try await store.upsert(session)
        let sent = Sent()

        let result = await tool(sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("in the middle of a turn"))
        #expect(result.text.contains("workspace_list"))
        #expect(sent.count == 0)
    }

    @Test("an agent stopped on a permission question is not written into")
    func awaitingQuestion() async throws {
        let store = try makeTestStore("merge-question")
        let target = try await workspace(in: store)
        var session = Session(workspaceID: target.id, title: "First chat")
        session.apply(.turnStarted)
        session.apply(.blocked)
        _ = try await store.upsert(session)
        let sent = Sent()

        let result = await tool(sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("stopped on a permission question"))
        #expect(sent.count == 0)
    }

    @Test("a worktree still being set up is not merged from")
    func settingUp() async throws {
        let store = try makeTestStore("merge-setup")
        var target = try await workspace(in: store)
        target.apply(.runStarted)
        _ = try await store.upsert(target)

        let result = await tool().call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("setup script is still running"))
    }

    @Test("a failed setup means no agent was ever started, so retrying will not help")
    func setupFailed() async throws {
        let store = try makeTestStore("merge-setup-failed")
        var target = try await workspace(in: store)
        target.apply(.runStarted)
        target.apply(.runFinished(succeeded: false, log: "npm install exploded"))
        _ = try await store.upsert(target)

        let result = await tool().call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("setup script failed"))
        #expect(result.text.contains("Retrying will not help"))
    }

    // MARK: What GitHub said

    @Test("gh missing is said as gh missing, not as a pull request that is not there")
    func ghMissing() async throws {
        let store = try makeTestStore("merge-gh-missing")
        let target = try await workspace(in: store)

        let result = await tool(reading: .unavailable(.notInstalled)).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("`gh` is not installed"))
        #expect(result.text.contains("Retrying will not help"))
    }

    @Test("signing gh in is the owner's to do")
    func ghSignedOut() async throws {
        let store = try makeTestStore("merge-gh-signed-out")
        let target = try await workspace(in: store)

        let result = await tool(reading: .unavailable(.signedOut)).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("not signed in to GitHub"))
        #expect(result.text.contains("the owner's to do"))
    }

    /// The one refusal here that is worth retrying, and the only one that says so.
    @Test("a gh call that did not come back is the one thing worth asking again about")
    func ghSilent() async throws {
        let store = try makeTestStore("merge-gh-silent")
        let target = try await workspace(in: store)

        let result = await tool(reading: .failed("gh timed out after 20s")).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("gh timed out after 20s"))
        #expect(result.text.contains("asking again in a minute"))
    }

    /// Measured over the socket before it was fixed: a worktree with no remote came back with the
    /// whole `gh pr view` invocation, ten `--json` fields and all, inside the refusal.
    @Test("gh's own words reach the caller, and the command line Bloom built does not")
    func ghsWordsWithoutTheCommandLine() {
        let error = ShellError(
            command: "gh pr view b --json number,title,url,state,isDraft,mergeable",
            status: 1,
            stderr: "no git remotes found\n"
        )

        let plain = WorkspaceMergeTool.plainly(error)

        #expect(plain == "no git remotes found.")
        #expect(!plain.contains("--json"))
        #expect(!WorkspaceMergeTrouble.githubSilent(plain).sentence.contains("--json"))
        // One full stop after gh's line, not two. Measured over the socket.
        #expect(WorkspaceMergeTrouble.githubSilent(plain).sentence.contains("found. Nothing was sent"))
        #expect(WorkspaceMergeTrouble.githubSilent("gh gave up").sentence.contains("up. Nothing was sent"))
    }

    /// The `git init` shape of mistake, in this tool's terms: handed "there is nothing to merge",
    /// an agent with a Bash tool opens a pull request so the call will work.
    @Test("no pull request says not to open one")
    func noPullRequest() async throws {
        let store = try makeTestStore("merge-no-pr")
        let target = try await workspace(in: store)

        let result = await tool(reading: .noPullRequest).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("GitHub has no pull request for its branch"))
        #expect(result.text.contains("Do not open one to make this call succeed"))
    }

    // MARK: What GitHub will not take

    /// Merged, closed, conflicting and draft have nothing left to ask about, and the sentence
    /// that says why is `PullRequestStatus`'s own rather than a second wording beside it.
    @Test("a pull request GitHub will not take is refused in the gate's own words", arguments: [
        (Self.open(state: "MERGED"), "This pull request is already merged."),
        (Self.open(state: "CLOSED"), "This pull request was closed without merging."),
        (Self.open(mergeable: "CONFLICTING"), "Resolve the conflicts with the base branch first."),
        (Self.open(isDraft: true), "This pull request is still a draft."),
    ])
    func blocked(pullRequest: PullRequest, reason: String) async throws {
        let store = try makeTestStore("merge-blocked")
        let target = try await workspace(in: store)
        let sent = Sent()

        let result = await tool(reading: .found(pullRequest, local: nil), sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains(reason))
        #expect(result.text.contains(pullRequest.status.text))
        #expect(result.text.contains("Do not mark the pull request ready"))
        #expect(sent.count == 0)
    }

    /// Failing checks and a missing review are NOT refused, here or in the strip. `canMerge` is
    /// permissive on purpose and this tool does not tighten it: whether a red check should stop a
    /// merge is the repository's rule to enforce, and the agent is told to stop when it does.
    @Test("failing checks do not block it, exactly as they do not block the button")
    func failingChecksRideAlong() async throws {
        let store = try makeTestStore("merge-failing-checks")
        let target = try await workspace(in: store)
        let sent = Sent()

        let result = await tool(
            reading: .found(Self.open(checks: .failing), local: nil), sent: sent
        ).call(request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store)

        #expect(!result.isError)
        #expect(sent.count == 1)
    }

    // MARK: Work GitHub has not got

    /// Where this tool parts company with the button, and the whole of the reason. The strip lets
    /// the button stay live over local work because the confirmation puts the warning in front of
    /// a person. There is nobody on this connection to put it in front of.
    @Test("uncommitted work refuses rather than merging over it")
    func uncommittedWork() async throws {
        let store = try makeTestStore("merge-uncommitted")
        let target = try await workspace(in: store)
        let sent = Sent()
        let local = LocalWork(modifiedFiles: 2, untrackedFiles: 1)

        let result = await tool(reading: .found(Self.open(), local: local), sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("3 files to commit"))
        #expect(result.text.contains("commit and push it first"))
        #expect(result.text.contains("dialogue the owner has to accept"))
        #expect(sent.count == 0)
    }

    @Test("committed work that was never pushed refuses too, because the merge would miss it")
    func unpushedWork() async throws {
        let store = try makeTestStore("merge-unpushed")
        let target = try await workspace(in: store)
        let sent = Sent()
        let local = LocalWork(unpushedCommits: 2)

        let result = await tool(reading: .found(Self.open(), local: local), sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("2 commits to push"))
        #expect(result.text.contains("push it first"))
        #expect(sent.count == 0)
    }

    @Test("a clean worktree is merged from without comment")
    func cleanWorktree() async throws {
        let store = try makeTestStore("merge-clean")
        let target = try await workspace(in: store)
        let sent = Sent()

        let result = await tool(reading: .found(Self.open(), local: LocalWork()), sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(!result.isError)
        #expect(sent.count == 1)
    }

    // MARK: Every refusal heads off the same misreading

    /// `ProjectAddFailure`'s trick, aimed at this tool's own misreading: an agent reads "merge
    /// this" as permission to run `gh pr merge` itself. Every refusal says not to, because every
    /// one of them describes a state a merge run from somewhere else would have got past.
    @Test("every refusal says not to run the merge some other way")
    func everyRefusalSaysNotToDoItYourself() async throws {
        let troubles: [WorkspaceMergeTrouble] = [
            .unknownWorkspace(id: "x", alias: .none),
            .unknownWorkspace(id: "x", alias: .one(name: "n", id: "i")),
            .unknownWorkspace(id: "x", alias: .several(name: "n", count: 3)),
            .archived(workspace: "w"),
            .worktreeGone(workspace: "w"),
            .githubUnavailable(.notInstalled),
            .githubUnavailable(.signedOut),
            .githubSilent("gh fell over"),
            .noPullRequest(workspace: "w", branch: "b"),
            .blocked(workspace: "w", number: 1, headline: "Draft", reason: "It is a draft."),
            .localWork(workspace: "w", number: 1, detail: "1 file to commit", needsCommit: true),
            .wouldQueue(workspace: "w", hold: .setup),
            .wouldQueue(workspace: "w", hold: .setupFailed),
            .wouldQueue(workspace: "w", hold: .question),
            .wouldQueue(workspace: "w", hold: .turn),
            .wouldQueue(workspace: "w", hold: .none),
            .appRefused("It is still working."),
        ]

        for trouble in troubles {
            #expect(trouble.sentence.contains("Do not run `gh pr merge` yourself"))
            #expect(!trouble.sentence.contains("gh pr merge <"))
        }
    }

    // MARK: What comes back when a turn does begin

    /// The result must not be readable as "merged", because it is not: the call answers when the
    /// turn starts and the merging happens inside it.
    @Test("the answer says a turn has begun and never that anything is merged")
    func theAnswer() async throws {
        let store = try makeTestStore("merge-answer")
        let target = try await workspace(in: store)
        let sent = Sent()

        let result = await tool(handoff: .turnBegun(chat: "Merge"), sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        #expect(!result.isError)
        let json = try answer(result)
        #expect(json["state"]?.stringValue == "turn_started")
        #expect(json["workspace_id"]?.stringValue == target.id.rawValue)
        #expect(json["workspace"]?.stringValue == "group occurrences")
        #expect(json["chat"]?.stringValue == "Merge")
        #expect(json["pull_request"]?.intValue == 42)
        #expect(json["base_branch"]?.stringValue == "main")
        #expect(json["method"]?.stringValue == "squash merge")

        let note = try #require(json["note"]?.stringValue)
        #expect(note.hasPrefix("Nothing is merged."))
        #expect(note.contains("A turn has begun in 'group occurrences'"))
        #expect(note.contains("in the chat 'Merge'"))
        #expect(note.contains("workspace_list with include_github"))
        #expect(note.contains("GitHub is allowed to refuse"))
        // The one sentence in the whole answer with "merged" in it is the one denying it.
        #expect(!json["state"]!.stringValue!.contains("merge"))
    }

    @Test("squash is what it proposes, and the other two are carried through unaltered")
    func methods() async throws {
        let store = try makeTestStore("merge-methods")
        let target = try await workspace(in: store)

        for method in GitHub.MergeMethod.allCases {
            let sent = Sent()
            var arguments: [String: JSONValue] = ["workspace": .string(target.id.rawValue)]
            arguments["method"] = .string(method.rawValue)

            let result = await tool(sent: sent).call(request(arguments), as: .owner, store: store)

            #expect(!result.isError)
            #expect(sent.last?.method == method)
            #expect(try answer(result)["method"]?.stringValue == method.phrase)
        }

        let sent = Sent()
        _ = await tool(sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )
        #expect(sent.last?.method == .squash)
    }

    /// The pull request goes across untouched, which is what lets the far side build the same
    /// `MergePromptContext` the button builds. Nothing the caller typed travels with it.
    @Test("the workspace and the pull request reach the app exactly as Bloom read them")
    func handsOverWhatItRead() async throws {
        let store = try makeTestStore("merge-handover")
        let target = try await workspace(in: store)
        let sent = Sent()
        let pullRequest = Self.open(number: 71)

        _ = await tool(reading: .found(pullRequest, local: nil), sent: sent).call(
            request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store
        )

        // Field by field rather than whole. The workspace that crosses the seam is the row read
        // back out of SQLite, and a Date does not survive that trip to the last fraction of a
        // second, so comparing the values compares the clock as often as it compares the columns.
        let handed = try #require(sent.last)
        #expect(handed.workspace.id == target.id)
        #expect(handed.workspace.name == target.name)
        #expect(handed.workspace.branch == target.branch)
        #expect(handed.workspace.baseBranch == target.baseBranch)
        #expect(handed.workspace.path == target.path)
        #expect(handed.pullRequest == pullRequest)
    }

    /// The prompt an MCP caller triggers is the prompt the button composes. The far side of the
    /// seam is `WorkspaceModel.requestMerge`, which builds this context and renders it against the
    /// owner's template; what this pins is that everything that context needs has come across, so
    /// the two doors cannot be given different facts.
    @Test("what crosses the seam renders the merge prompt the button renders")
    func rendersTheButtonsPrompt() async throws {
        let store = try makeTestStore("merge-prompt")
        let target = try await workspace(in: store)
        let sent = Sent()
        let pullRequest = Self.open(number: 71)

        _ = await tool(reading: .found(pullRequest, local: nil), sent: sent).call(
            request([
                "workspace": .string(target.id.rawValue), "method": .string("squash"),
            ]),
            as: .owner,
            store: store
        )

        let handed = try #require(sent.last)
        let context = MergePromptContext(
            workspaceName: handed.workspace.name,
            number: handed.pullRequest.number,
            title: handed.pullRequest.title,
            branch: handed.pullRequest.branch,
            baseBranch: handed.workspace.baseBranch,
            method: handed.method
        )
        let render = context.render(
            template: PromptRegistry.definition(for: .mergePullRequest).defaultTemplate
        )

        #expect(render.missing.isEmpty)
        #expect(render.text.contains("#71"))
        #expect(render.text.contains("into main"))
        #expect(render.text.contains("squash merge"))
        #expect(render.text.contains("`--squash`"))
        #expect(render.text.contains("claude/group-occurrences"))
    }

    /// The app's own guard is the real one, and it is checked again on the main actor against the
    /// live transcripts. A turn that starts between this tool's look and that check comes back
    /// here rather than being sent into.
    @Test("the app refusing after all is relayed rather than reported as a turn")
    func appRefused() async throws {
        let store = try makeTestStore("merge-app-refused")
        let target = try await workspace(in: store)

        let result = await tool(
            handoff: .refused("group occurrences is still working. Wait for the turn to finish.")
        ).call(request(["workspace": .string(target.id.rawValue)]), as: .owner, store: store)

        #expect(result.isError)
        #expect(result.text.contains("Bloom did not send the merge request."))
        #expect(result.text.contains("is still working"))
    }
}
