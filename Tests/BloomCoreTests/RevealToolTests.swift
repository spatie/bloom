import Testing
import Foundation
@testable import BloomCore

@Suite("Revealing something in the window", .tags(.persistence), .scratchDirectory)
struct RevealToolTests {
    // MARK: - Reading the arguments

    /// **Every expectation here names the scope**, and none of them writes a bare `HomeFilter()`.
    /// These two tests did lean on that default, and passed until the Home merge changed it from
    /// `.all` to `.live` underneath them: nothing overlapped textually, so the rebase was clean and
    /// the compiler had nothing to say. A test that inherits a default is a test whose meaning
    /// somebody else can change.
    @Test("naming no scope shows everything, and the answer says so")
    func noArguments() throws {
        let order = try parse()
        #expect(order == RevealOrder())
        #expect(order.scope == .all)
        let reveal = try resolve(order, workspaces: [], projects: [])
        #expect(reveal.target == .home(HomeFilter(query: "", projects: [], scope: .all)))
        #expect(reveal.sentence == "Bloom is on Home, showing All.")
    }

    /// The rule, pinned on its own so it cannot be changed by accident. Home rests on `.live`,
    /// which hides archived work, and the headline use of this verb is showing somebody the
    /// finished workspaces there is deliberately no tool to archive. A reveal that hid them would
    /// lie about what it revealed.
    @Test("a bare reveal is not what Home rests on")
    func unnamedScopeIsNotHomeDefault() {
        #expect(RevealChoice.scopeWhenUnnamed == .all)
        #expect(RevealChoice.scopeWhenUnnamed != HomeFilter().scope)
    }

    @Test("blank strings are the same as nothing at all")
    func blanksAreNothing() throws {
        let order = try parse(workspace: "   ", search: "")
        #expect(order.workspace == nil)
        #expect(order.search.isEmpty)
    }

    /// Either would be a defensible winner, which is exactly why neither may be: a caller that
    /// asked for both got one of them silently, and half the time it was the wrong one.
    @Test("a workspace and a Home narrowing together is refused rather than one winning")
    func refusesBothAtOnce() {
        for extra in [("project", "bloom"), ("search", "flake"), ("scope", "running")] {
            var arguments: [String: JSONValue] = ["workspace": .string("Fix the flake")]
            arguments[extra.0] = .string(extra.1)
            let outcome = RevealChoice.parse(
                workspace: arguments["workspace"],
                project: arguments["project"],
                scope: arguments["scope"],
                search: arguments["search"]
            )
            guard case .failure(let refusal) = outcome else {
                Issue.record("expected a refusal for \(extra.0)"); return
            }
            #expect(refusal.sentence.contains("ambiguous"))
        }
    }

    @Test("a scope Home does not have is refused, with the ones it does")
    func unknownScope() {
        guard case .failure(let refusal) = RevealChoice.parse(
            workspace: nil, project: nil, scope: .string("finished"), search: nil
        ) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("finished"))
        #expect(refusal.sentence.contains("needsYou"))
    }

    /// Home's two search-only chips narrow a search by what kind of thing matched, so a reveal
    /// arriving with no query would light a chip that shows nothing.
    @Test("the search-only chips are not on offer")
    func searchOnlyScopesAreNotOffered() {
        #expect(!RevealChoice.offered.contains(.workspaces))
        #expect(!RevealChoice.offered.contains(.transcripts))
        #expect(RevealChoice.offered == [.all, .needsYou, .running, .live, .archived])
    }

    // MARK: - Resolving a name

    @Test("a workspace is found by name, and by id")
    func findsWorkspace() throws {
        let (workspaces, projects) = world()
        let byName = try resolve(try parse(workspace: "fix the flake"), workspaces: workspaces, projects: projects)
        #expect(byName.target == .workspace(workspaces[0].id))
        #expect(byName.sentence.contains("Fix the flake"))
        #expect(byName.sentence.contains("bloom"))

        let byID = try resolve(
            try parse(workspace: workspaces[1].id.rawValue), workspaces: workspaces, projects: projects
        )
        #expect(byID.target == .workspace(workspaces[1].id))
    }

    /// It never creates what it navigates to, which is the rule `workspace_tab_select` argues and
    /// this tool inherits whole.
    @Test("a name nothing answers to is refused with the names there are")
    func refusesUnknownWorkspace() throws {
        let (workspaces, projects) = world()
        guard case .failure(let refusal) = RevealChoice.resolve(
            try parse(workspace: "Ship it"), workspaces: workspaces, projects: projects
        ) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("Ship it"))
        #expect(refusal.sentence.contains("Fix the flake"))
    }

    @Test("two workspaces with one name is refused, and asks for the id")
    func refusesAmbiguousWorkspace() throws {
        var (workspaces, projects) = world()
        workspaces.append(Workspace(
            repoID: projects[1].id, name: "Fix the flake", branch: "b3", path: "/p3", baseBranch: "main"
        ))
        guard case .failure(let refusal) = RevealChoice.resolve(
            try parse(workspace: "Fix the flake"), workspaces: workspaces, projects: projects
        ) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("2 workspaces"))
        #expect(refusal.sentence.contains("id"))
    }

    @Test("a refusal stops listing before it becomes a directory")
    func refusalListIsCapped() {
        let names = (1...25).map { "workspace \($0)" }
        let listed = RevealChoice.list(names)
        #expect(listed.contains("workspace 10"))
        #expect(!listed.contains("workspace 11"))
        #expect(listed.contains("15 more"))
    }

    // MARK: - Home

    @Test("a project, a scope and a search become one filter, and one sentence")
    func homeFilter() throws {
        let (workspaces, projects) = world()
        let reveal = try resolve(
            try parse(project: "bloom", scope: "archived", search: "parser"),
            workspaces: workspaces,
            projects: projects
        )
        #expect(reveal.target == .home(HomeFilter(
            query: "parser", projects: [projects[0].id], scope: .archived
        )))
        #expect(reveal.sentence.contains("bloom"))
        #expect(reveal.sentence.contains("Archived"))
        #expect(reveal.sentence.contains("parser"))
        // The scope is in every sentence, including the one nobody chose. See `homeSentence`.
        #expect(try resolve(try parse(), workspaces: [], projects: []).sentence.contains("All"))
    }

    @Test("a project is found by path as well as by name")
    func projectByPath() throws {
        let (workspaces, projects) = world()
        let reveal = try resolve(
            try parse(project: projects[1].path), workspaces: workspaces, projects: projects
        )
        #expect(reveal.target == .home(HomeFilter(
            query: "", projects: [projects[1].id], scope: .all
        )))
        #expect(reveal.sentence.contains("mailcoach"))
    }

    @Test("a project nothing answers to is refused with the projects there are")
    func refusesUnknownProject() throws {
        let (workspaces, projects) = world()
        guard case .failure(let refusal) = RevealChoice.resolve(
            try parse(project: "flare"), workspaces: workspaces, projects: projects
        ) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("flare"))
        #expect(refusal.sentence.contains("mailcoach"))
    }

    // MARK: - The tool

    @Test("it is the owner's tool and nobody else's")
    func ownerOnly() {
        #expect(RevealTool { _ in .refused("no") }.roles == [.owner])
    }

    /// Navigation, asked for by the owner's own client, in a conversation the owner is sitting in
    /// front of. A prompt here would hang a turn to protect a glance.
    @Test("Bloom answers its own question for it")
    func selfApproved() {
        #expect(BridgeToolApproval.isSelfApproved(toolName: BridgeToolApproval.toolPrefix + "reveal"))
        // And the ones that destroy or publish are still deliberately not.
        #expect(!BridgeToolApproval.selfApproved.contains("workspace_merge"))
        #expect(!BridgeToolApproval.selfApproved.contains("project_add"))
    }

    @Test("it hands the window an id and a sentence, and answers with the sentence")
    func callsThrough() async throws {
        let store = try makeTestStore("reveal")
        let repo = try await store.upsert(Repo(name: "bloom", path: "/tmp/bloom"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Fix the flake", branch: "b", path: "/p", baseBranch: "main"
        ))

        let recorder = Recorder()
        let tool = RevealTool { reveal in
            await recorder.record(reveal)
            return .revealed(reveal.sentence)
        }
        let result = await tool.call(
            MCPRequest(
                id: .integer(1),
                method: "reveal",
                params: .object(["workspace": .string("Fix the flake")])
            ),
            as: .owner,
            store: store
        )

        #expect(!result.isError)
        #expect(result.text.contains("Fix the flake"))
        #expect(await recorder.reveals.map(\.target) == [.workspace(workspace.id)])
    }

    @Test("a window that is not there yet refuses rather than pretending")
    func refusesWhenTheWindowIsNotThere() async throws {
        let store = try makeTestStore("reveal-no-window")
        let tool = RevealTool { _ in .refused("Bloom is still starting up.") }
        let result = await tool.call(
            MCPRequest(id: .integer(1), method: "reveal", params: .object([:])),
            as: .owner,
            store: store
        )
        #expect(result.isError)
        #expect(result.text == "Bloom is still starting up.")
    }

    // MARK: - Support

    private func parse(
        workspace: String? = nil,
        project: String? = nil,
        scope: String? = nil,
        search: String? = nil
    ) throws -> RevealOrder {
        let outcome = RevealChoice.parse(
            workspace: workspace.map { .string($0) },
            project: project.map { .string($0) },
            scope: scope.map { .string($0) },
            search: search.map { .string($0) }
        )
        guard case .success(let order) = outcome else {
            throw RevealTestTrouble.refused
        }
        return order
    }

    private func resolve(
        _ order: RevealOrder,
        workspaces: [Workspace],
        projects: [Repo]
    ) throws -> RevealPlan {
        guard case .success(let reveal) = RevealChoice.resolve(
            order, workspaces: workspaces, projects: projects
        ) else {
            throw RevealTestTrouble.refused
        }
        return reveal
    }

    private func world() -> ([Workspace], [Repo]) {
        let bloom = Repo(name: "bloom", path: "/tmp/bloom")
        let mailcoach = Repo(name: "mailcoach", path: "/tmp/mailcoach")
        return (
            [
                Workspace(
                    repoID: bloom.id, name: "Fix the flake", branch: "b1", path: "/p1",
                    baseBranch: "main"
                ),
                Workspace(
                    repoID: mailcoach.id, name: "Warm the cache", branch: "b2", path: "/p2",
                    baseBranch: "main"
                ),
            ],
            [bloom, mailcoach]
        )
    }

    private enum RevealTestTrouble: Error { case refused }

    private actor Recorder {
        var reveals: [RevealPlan] = []

        func record(_ reveal: RevealPlan) { reveals.append(reveal) }
    }
}
