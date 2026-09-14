import Foundation
import Testing
@testable import BloomCore

@Suite("Project approvals by provider", .scratchDirectory)
struct ProviderPermissionGrantTests {
    private static func ask() -> PermissionAsk {
        PermissionAsk(
            requestID: "request", toolName: "Shell", input: .object(["command": .string("echo hello")]),
            suggestions: [PermissionSuggestion(
                type: "addRules", behavior: "allow",
                rules: [PermissionRule(toolName: "Shell", ruleContent: "echo hello")], raw: .object([:])
            )]
        )
    }

    @Test("identical rules cannot cross providers, even when given an unfiltered grant list",
          arguments: AgentKind.runnable)
    func matching(provider: AgentKind) {
        let ask = Self.ask()
        let rule = ask.rules[0]
        let grant = PermissionGrant.granting(rule, repoID: RepoID("repo"), agentKind: provider)
        for other in AgentKind.runnable {
            let matched = PermissionGrantIndex.match(ask: ask, agentKind: other, grants: [grant])
            #expect((matched != nil) == (other == provider))
        }
        var legacy = grant
        legacy.agentKind = nil
        #expect(PermissionGrantIndex.match(ask: ask, agentKind: provider, grants: [legacy]) == nil)
    }

    @Test("identical project approvals have separate identities, usage counts and revocation")
    func separateGrants() async throws {
        let store = try makeTestStore("provider-grants")
        let repo = try await store.upsert(Repo(name: "Project", path: "/tmp/provider-project"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/provider-workspace", baseBranch: "main"
        ))
        let ask = Self.ask()
        var saved: [PermissionGrant] = []
        for provider in AgentKind.runnable {
            let session = SessionGrants(store: store, workspaceID: workspace.id, agentKind: provider)
            #expect(await session.matching(ask) == nil)
            await session.record(.allow(scope: .project), from: ask)
            let match = try #require(await session.matching(ask))
            let grant = try #require(match.first)
            #expect(grant.agentKind == provider)
            saved.append(grant)
            await session.record(.allow(scope: .project), from: ask)
        }
        #expect(Set(saved.map(\.id)).count == AgentKind.runnable.count)
        #expect(try await store.permissionGrants(repoID: repo.id).count == saved.count)

        let first = try #require(saved.first)
        try await store.recordPermissionGrantUse(id: first.id)
        for grant in saved {
            let provider = try #require(grant.agentKind)
            let stored = try #require(await store.permissionGrants(repoID: repo.id, agentKind: provider).first)
            #expect(stored.useCount == (grant.id == first.id ? 1 : 0))
        }
        try await store.deletePermissionGrant(id: first.id)
        for grant in saved {
            let provider = try #require(grant.agentKind)
            let session = SessionGrants(store: store, workspaceID: workspace.id, agentKind: provider)
            #expect((await session.matching(ask) == nil) == (grant.id == first.id))
        }
    }

    @Test("old approvals stay visible but inactive through migration and schema repair", arguments: [false, true])
    func legacyGrants(currentStamp: Bool) async throws {
        let path = TestScratch.unique("provider-grants-migration") + ".sqlite"
        let original = try Store(path: path)
        let repo = try await original.upsert(Repo(name: "Project", path: "/tmp/legacy-provider-project"))
        let raw = try SQLiteDatabase(path: path)
        let version = try raw.readUserVersion()
        try raw.execute("""
        DROP INDEX permission_grants_provider_rule;
        ALTER TABLE permission_grants DROP COLUMN agent_kind;
        CREATE UNIQUE INDEX permission_grants_rule ON permission_grants(repo_id, tool_name, rule_content);
        """)
        try raw.run(
            "INSERT INTO permission_grants (id, repo_id, tool_name, rule_content, granted_at, use_count) VALUES (?, ?, ?, ?, ?, ?)",
            [.text("old-grant"), .text(repo.id), .text("Shell"), .text("echo hello"), .double(123), .int(7)]
        )
        if !currentStamp { try raw.setUserVersion(version - 1) }

        let migrated = try Store(path: path)
        let legacy = try #require(await migrated.permissionGrants(repoID: repo.id).first)
        #expect(legacy.id == PermissionGrantID("old-grant"))
        #expect(legacy.agentKind == nil)
        #expect(legacy.useCount == 7)
        #expect(legacy.grantedAt == Date(timeIntervalSince1970: 123))
        for provider in AgentKind.runnable {
            #expect(try await migrated.permissionGrants(repoID: repo.id, agentKind: provider).isEmpty)
            #expect(PermissionGrantIndex.match(ask: Self.ask(), agentKind: provider, grants: [legacy]) == nil)
            try await migrated.upsert(PermissionGrant.granting(
                Self.ask().rules[0], repoID: repo.id, agentKind: provider
            ))
        }

        // Replaying the migration must keep the same rule valid for several providers.
        try raw.setUserVersion(version - 1)
        let reopened = try Store(path: path)
        #expect(try await reopened.permissionGrants(repoID: repo.id).count == AgentKind.runnable.count + 1)
        for provider in AgentKind.runnable {
            #expect(try await reopened.permissionGrants(repoID: repo.id, agentKind: provider).count == 1)
        }
    }
}
