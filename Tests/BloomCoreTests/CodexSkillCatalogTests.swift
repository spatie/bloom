import Foundation
import Testing
@testable import BloomCore

@Suite struct CodexSkillCatalogTests {
    private actor FetchCount {
        var count = 0
        func fetch(failing: Bool) throws -> [SlashCommand] {
            count += 1
            if failing { throw CodexClientError.notInitialized }
            return []
        }
    }

    @Test(arguments: [false, true])
    func sharesAndCachesFetches(failing: Bool) async {
        let counter = FetchCount()
        let catalog = CodexSkillCatalog(fetch: { try await counter.fetch(failing: failing) })
        async let first = catalog.skills()
        async let second = catalog.skills()
        let results = await [first, second]
        let cached = await catalog.skills()
        #expect(await counter.count == 1)
        #expect(results.allSatisfy { $0 == (failing ? nil : []) })
        #expect(cached == (failing ? nil : []))
    }

    @Test func decodesEnabledSkillsForTheRequestedWorkspace() throws {
        let response = try #require(JSONValue.parse(#"""
        {"data":[{"cwd":"/work","skills":[
          {"name":"local","description":"Workspace skill","path":"/work/.agents/skills/local/SKILL.md","scope":"repo","enabled":true},
          {"name":"review","description":"Plugin skill","path":"/plugins/review/SKILL.md","scope":"user","enabled":true,"pluginId":"tools@market"},
          {"name":"disabled","path":"/disabled/SKILL.md","enabled":false}
        ]},{"cwd":"/other","skills":[{"name":"other","enabled":true}]}]}
        """#))
        let found = CodexSkillCatalog.decode(response, project: "/work")
        #expect(found.map(\.name) == ["local", "tools:review"])
        #expect(found.first?.scope == .project)
        #expect(found.last?.scope == .plugin("tools"))
        #expect(found.last?.path == "/plugins/review/SKILL.md")
    }

    @Test func successfulCodexListReplacesTheFallback() throws {
        let tree = try SlashCommandTests.Tree()
        try tree.skill(".codex/skills/disabled", name: "disabled", description: "Disabled by Codex")
        try tree.skill(".claude/skills/claude", name: "claude", description: "Claude skill")
        let found = SlashCommandIndex.discover(home: tree.home, project: tree.project, codexSkills: [])
        #expect(!found.contains { $0.name == "disabled" })
        #expect(found.contains { $0.name == "claude" })
    }

    @Test func fallbackHonoursCustomCodexHome() throws {
        let tree = try SlashCommandTests.Tree()
        try tree.skill("custom/skills/extra", name: "extra", description: "Custom home")
        try tree.skill(".codex/skills/default", name: "default", description: "Default home")
        let found = SlashCommandIndex.discover(
            home: tree.home, project: tree.project, codexHome: "\(tree.home)/custom"
        )
        #expect(found.contains { $0.name == "extra" })
        #expect(!found.contains { $0.name == "default" })
    }

    @Test func sharedSkillSymlinksDoNotDuplicateClaudeEntries() throws {
        let tree = try SlashCommandTests.Tree()
        try tree.skill(".claude/skills/shared", name: "shared", description: "Shared skill")
        try FileManager.default.createDirectory(
            atPath: "\(tree.home)/.agents", withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: "\(tree.home)/.agents/skills", withDestinationPath: "\(tree.home)/.claude/skills"
        )
        #expect(tree.discover().filter { $0.name == "shared" }.count == 1)
    }

    @Test func codexWorkspaceSkillWinsOverClaudeUserSkill() throws {
        let tree = try SlashCommandTests.Tree()
        try tree.skill(".claude/skills/review", name: "review", description: "User")
        let skill = SlashCommand(name: "review", detail: "Workspace", kind: .skill, scope: .project)
        let found = SlashCommandIndex.discover(home: tree.home, project: tree.project, codexSkills: [skill])
        #expect(found.filter { $0.name == "review" } == [skill])
    }
}
