import Foundation
import Testing
@testable import BloomCore

/// The one place either backend asks what the project already approved.
///
/// This was four rules held twice, once per runner, and the suite that covered it covered each
/// runner's copy through a whole fake process. What is asserted here is the rules themselves: a
/// chat with no worktree grants nothing, a project grant answers the next question in the same
/// project and not in another one, and a decision that was not a project one writes nothing at all.
@Suite("Session grants", .tags(.persistence), .scratchDirectory)
struct SessionGrantsTests {
    private static func ask(tool: String = "Bash", rule: String? = "bin/test:*") -> PermissionAsk {
        let rules: [PermissionRule] = rule.map { [PermissionRule(toolName: tool, ruleContent: $0)] } ?? []
        return PermissionAsk(
            requestID: "req-1",
            toolName: tool,
            input: .object(["command": .string("bin/test --filter Permission")]),
            suggestions: rules.isEmpty ? [] : [PermissionSuggestion(
                type: "addRules",
                behavior: "allow",
                destination: "localSettings",
                rules: rules,
                raw: .object([:])
            )]
        )
    }

    /// A repo with a workspace in it, which is the whole shape a grant is keyed on.
    private static func project(_ store: Store) async throws -> (repo: Repo, workspace: Workspace) {
        let repo = try await store.upsert(Repo(name: "Bloom", path: "/tmp/bloom-\(newID())"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w-\(newID())", baseBranch: "main"
        ))
        return (repo, workspace)
    }

    @Test("the repo behind a chat is found from its workspace")
    func resolvesTheRepo() async throws {
        let store = try makeTestStore()
        let (repo, workspace) = try await Self.project(store)
        let grants = SessionGrants(store: store, workspaceID: workspace.id)

        #expect(await grants.repoID() == repo.id)
        // Twice, because the second answer comes out of the cache and has to be the same one.
        #expect(await grants.repoID() == repo.id)
    }

    /// Ask Bloom has no worktree, so it has no project, so it has no project scope. Nothing here
    /// may invent one, and nothing may crash looking for one.
    @Test("a chat with no worktree has no project to grant in")
    func chatWithNoWorkspace() async throws {
        let store = try makeTestStore()
        let grants = SessionGrants(store: store, workspaceID: nil)

        #expect(await grants.repoID() == nil)
        #expect(await grants.matching(Self.ask()) == nil)

        // And a decision that would otherwise have been written down writes nothing.
        await grants.record(.allow(scope: .project), from: Self.ask())
        #expect(try await store.permissionGrants().isEmpty)
    }

    @Test("a stored rule answers the next question in the same project")
    func matchesAStoredRule() async throws {
        let store = try makeTestStore()
        let (repo, workspace) = try await Self.project(store)
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"), repoID: repo.id
        ))
        let grants = SessionGrants(store: store, workspaceID: workspace.id)

        let matched = try #require(await grants.matching(Self.ask()))
        #expect(matched.count == 1)
        #expect(matched[0].displayText == "Bash(bin/test:*)")
    }

    /// A grant is keyed by repository and only by repository. Approving a command in one checkout
    /// must not answer for another, which is the whole reason `repoID` is looked up rather than
    /// assumed.
    @Test("a rule granted in one project does not answer in another")
    func doesNotCrossProjects() async throws {
        let store = try makeTestStore()
        let (repo, _) = try await Self.project(store)
        let (_, elsewhere) = try await Self.project(store)
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"), repoID: repo.id
        ))

        let grants = SessionGrants(store: store, workspaceID: elsewhere.id)
        #expect(await grants.matching(Self.ask()) == nil)
    }

    @Test("a project decision is written down, and a once-only one is not")
    func recordsOnlyProjectScope() async throws {
        let store = try makeTestStore()
        let (repo, workspace) = try await Self.project(store)
        let grants = SessionGrants(store: store, workspaceID: workspace.id)

        await grants.record(.allow(scope: .once), from: Self.ask())
        #expect(try await store.permissionGrants(repoID: repo.id).isEmpty)

        await grants.record(.allow(scope: .project), from: Self.ask())
        let stored = try await store.permissionGrants(repoID: repo.id)
        #expect(stored.count == 1)
        #expect(stored[0].displayText == "Bash(bin/test:*)")

        // And what was written answers the question it was written for.
        #expect(await grants.matching(Self.ask()) != nil)
    }

    /// The panel says when a rule was last used and how often, so a rule that answered a question
    /// has to be stamped. Both runners did this in a loop of their own.
    @Test("using a grant to answer a question counts the use")
    func countsUses() async throws {
        let store = try makeTestStore()
        let (repo, workspace) = try await Self.project(store)
        let grant = try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"), repoID: repo.id
        ))
        let grants = SessionGrants(store: store, workspaceID: workspace.id)

        await grants.recordUse(of: [grant])
        await grants.recordUse(of: [grant])

        let stored = try #require(await store.permissionGrants(repoID: repo.id).first)
        #expect(stored.useCount == 2)
        #expect(stored.lastUsedAt != nil)
    }

    /// Revocation bites on the next ask rather than on the next launch, which is what it means for
    /// the grants themselves never to be cached. Only the repo id is.
    @Test("a revoked rule stops answering immediately")
    func revocationIsImmediate() async throws {
        let store = try makeTestStore()
        let (repo, workspace) = try await Self.project(store)
        let grant = try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"), repoID: repo.id
        ))
        let grants = SessionGrants(store: store, workspaceID: workspace.id)
        #expect(await grants.matching(Self.ask()) != nil)

        try await store.deletePermissionGrant(id: grant.id)

        #expect(await grants.matching(Self.ask()) == nil)
    }

    /// An ask the CLI marked as not wideable must not be answered from a stored rule either, or
    /// the flag would mean nothing the second time the question came round.
    @Test("an ask that cannot be widened is never answered from a grant")
    func neverAnswersAnAskThatCannotWiden() async throws {
        let store = try makeTestStore()
        let (repo, workspace) = try await Self.project(store)
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"), repoID: repo.id
        ))
        let grants = SessionGrants(store: store, workspaceID: workspace.id)

        var ask = Self.ask()
        ask.suppressesAlwaysAllow = true
        #expect(await grants.matching(ask) == nil)
    }
}
