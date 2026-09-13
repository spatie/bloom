import BloomClient
import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerSkillsServiceTests {
    private func fixture() throws -> (URL, ServerSkillsService) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("skills-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (home, ServerSkillsService(directory: home.appendingPathComponent("skills").path, home: home.path))
    }
    private func bundle(_ name: String = "review", text: String = "Review changes.") -> [ServerSkillFile] {
        [.init(path: name + "/SKILL.md", data: Data(("---\nname: \(name)\ndescription: Review code\n---\n" + text).utf8)),
         .init(path: name + "/scripts/check.sh", data: Data("#!/bin/sh\nprintf must-not-run".utf8), isExecutable: true)]
    }
    private func install(_ service: ServerSkillsService, files: [ServerSkillFile], agents: [ServerSkillAgent] = [.claude]) async throws -> ServerSkill {
        let preview = try await service.handle(.init(action: .previewImport, files: files))
        let plan = try #require(preview.plan)
        let result = try await service.handle(.init(action: .apply, planID: plan.id, selectedSkillNames: plan.skills.map(\.name), agents: agents))
        return try #require(result.skills.first { $0.isManaged })
    }

    @Test func importIsReviewedDisabledUntilAppliedAndSurvivesRestart() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let response = try await service.handle(.init(action: .previewImport, files: bundle()))
        let plan = try #require(response.plan)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/review").path))
        let detail = try await service.handle(.init(action: .read, planID: plan.id, skillID: plan.skills[0].id))
        #expect(detail.content?.contains("Review changes.") == true)
        let result = try await service.handle(.init(action: .apply, planID: plan.id, selectedSkillNames: ["review"], agents: [.claude, .codex]))
        let skill = try #require(result.skills.first { $0.isManaged })
        #expect(Set(skill.enabledAgents) == [.claude, .codex])
        let mode = try FileManager.default.attributesOfItem(atPath: skill.path + "/scripts/check.sh")[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        let restarted = ServerSkillsService(directory: home.appendingPathComponent("skills").path, home: home.path)
        let inspected = try await restarted.handle(.init(action: .inspect))
        #expect(inspected.skills.first { $0.id == skill.id }?.revision == skill.revision)
        let read = try await restarted.handle(.init(action: .read, skillID: skill.id))
        #expect(read.content == detail.content)
    }

    @Test func unmanagedCollisionCannotOverwriteOrPartiallyInstall() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ServerSkillDirectory(path: home.path).directory(".claude/skills/review", create: true)
        try root.write("SKILL.md", data: Data("Existing personal skill".utf8))
        let response = try await service.handle(.init(action: .previewImport, files: bundle()))
        let plan = try #require(response.plan)
        await #expect(throws: Error.self) {
            _ = try await service.handle(.init(action: .apply, planID: plan.id, selectedSkillNames: ["review"], agents: [.claude]))
        }
        #expect(try root.read("SKILL.md", limit: 100) == Data("Existing personal skill".utf8))
        let result = try await service.handle(.init(action: .inspect))
        #expect(result.skills.filter(\.isManaged).isEmpty)
        #expect(result.skills.first?.source == .unmanaged)
    }

    @Test func legacyCodexSkillsRemainVisibleAndCannotBeShadowed() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = try ServerSkillDirectory(path: home.path).directory(".codex/skills/review", create: true)
        try legacy.write("SKILL.md", data: Data("Legacy Codex skill".utf8))
        let result = try await service.handle(.init(action: .inspect))
        #expect(result.skills.first?.source == .unmanaged)
        #expect(result.skills.first?.enabledAgents == [.codex])
        await #expect(throws: Error.self) { _ = try await install(service, files: bundle(), agents: [.codex]) }
        #expect(try legacy.read("SKILL.md", limit: 100) == Data("Legacy Codex skill".utf8))
    }

    @Test func staleClientCannotUndoAnotherClientsEnableDecision() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = try await install(service, files: bundle())
        let changed = try await service.handle(.init(action: .setEnabled, skillID: original.id, revision: original.revision, agents: []))
        #expect(changed.skills.first?.enabledAgents.isEmpty == true)
        await #expect(throws: Error.self) {
            _ = try await service.handle(.init(action: .setEnabled, skillID: original.id, revision: original.revision, agents: [.codex]))
        }
        let current = try #require(changed.skills.first)
        _ = try await service.handle(.init(action: .remove, skillID: current.id, revision: current.revision))
        let result = try await service.handle(.init(action: .inspect))
        #expect(result.skills.isEmpty)
    }

    @Test func symlinkedAgentDirectoryCannotRedirectAnImport() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: outside)
        await #expect(throws: Error.self) { _ = try await install(service, files: bundle()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func invalidPathsOversizedInstructionsAndDuplicateNamesAreRejected() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in ["../SKILL.md", "review/../secret", "review/.env", "review/auth.json", "/review/SKILL.md", "review/.claude-plugin/plugin.json"] {
            await #expect(throws: Error.self) {
                _ = try await service.handle(.init(action: .previewImport, files: [.init(path: path, data: Data("secret".utf8))]))
            }
        }
        await #expect(throws: Error.self) {
            _ = try await service.handle(.init(action: .previewImport, files: [.init(path: "review/SKILL.md", data: Data(repeating: 65, count: 65_537))]))
        }
        await #expect(throws: Error.self) { _ = try await service.handle(.init(action: .previewImport, files: bundle() + bundle())) }
    }

    @Test func projectSkillsAreReadOnlyAndEscapeLinksAreNotRead() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = try ServerSkillDirectory(path: home.path).directory("workspace", create: true)
        let project = try workspace.directory(".agents/skills/project", create: true)
        try project.write("SKILL.md", data: Data("Project skill".utf8))
        let result = try await service.handle(.init(action: .inspect), workspacePath: home.path + "/workspace")
        let skill = try #require(result.skills.first)
        #expect(skill.source == .project)
        await #expect(throws: Error.self) { _ = try await service.handle(.init(action: .remove, skillID: skill.id, revision: skill.revision)) }
        #expect(try project.read("SKILL.md", limit: 100) == Data("Project skill".utf8))
        let managed = try await install(service, files: bundle())
        let changed = try await service.handle(.init(action: .setEnabled, skillID: managed.id, revision: managed.revision, agents: []),
                                               workspacePath: home.path + "/workspace")
        #expect(changed.skills.contains { $0.source == .project && $0.id == skill.id })
    }

    @Test func gitPlanPinsBytesAndNeverRefetchesDuringApply() async throws {
        let (home, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let bytes = bundle(text: "Pinned content")
        let service = ServerSkillsService(directory: home.path + "/skills", home: home.path) { _, _, _ in
            ServerSkillsGit.Snapshot(commit: String(repeating: "a", count: 40), files: bytes)
        }
        let response = try await service.handle(.init(action: .previewGit, repositoryURL: "https://github.com/example/skills.git", ref: "main"))
        let plan = try #require(response.plan)
        #expect(plan.commit == String(repeating: "a", count: 40))
        let result = try await service.handle(.init(action: .apply, planID: plan.id, selectedSkillNames: ["review"], agents: []))
        let skill = try #require(result.skills.first)
        #expect(skill.commit == plan.commit)
        #expect(skill.source == .git)
        #expect(skill.enabledAgents.isEmpty)
        let detail = try await service.handle(.init(action: .read, skillID: skill.id))
        #expect(detail.content?.contains("Pinned content") == true)
        let update = try await service.handle(.init(action: .previewGit, repositoryURL: skill.repositoryURL, collectionID: skill.collectionID))
        #expect(update.plan?.ref == "main")
    }

    @Test func indexWriteFailureRestoresPreviousLinksAndProvenance() async throws {
        let (home, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = try await install(initial, files: bundle())
        let failing = ServerSkillsService(directory: home.path + "/skills", home: home.path,
            fetch: { _, _, _ in throw ServerFailure("Unexpected download") },
            beforeIndexCommit: { throw ServerFailure("Simulated disk failure") })
        await #expect(throws: Error.self) {
            _ = try await failing.handle(.init(action: .setEnabled, skillID: original.id, revision: original.revision, agents: [.codex]))
        }
        let restarted = ServerSkillsService(directory: home.path + "/skills", home: home.path)
        let result = try await restarted.handle(.init(action: .inspect))
        #expect(result.skills.first?.enabledAgents == [.claude])
        #expect(result.skills.first?.revision == original.revision)
        #expect(!FileManager.default.fileExists(atPath: home.path + "/skills/transaction.json"))
    }

    @Test func interruptedPublicationRecoversOriginalSettingsOnRestart() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = try await install(service, files: bundle())
        let storage = try ServerSkillDirectory(path: home.path + "/skills")
        let before = try JSONDecoder().decode([ServerSkill].self, from: storage.read("index.json", limit: 4_194_304))
        var after = before
        after[0].enabledAgents = [.codex]
        try storage.write("transaction.json", data: JSONEncoder().encode(ServerSkillsService.Transaction(before: before, after: after)))
        let account = try ServerSkillDirectory(path: home.path)
        try account.directory(".claude/skills").unpublish(original.name, target: original.path)
        try account.directory(".agents/skills").publish(original.name, target: original.path)
        let restarted = ServerSkillsService(directory: home.path + "/skills", home: home.path)
        let result = try await restarted.handle(.init(action: .inspect))
        #expect(result.skills.first?.enabledAgents == [.claude])
        #expect(result.skills.first?.revision == original.revision)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLOOM_LIVE_SKILLS"] == "1"))
    func realPublicGitCollectionProducesPinnedSkillFilesWithoutCheckout() async throws {
        let (home, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let snapshot = try await ServerSkillsGit.fetch(repository: "https://github.com/vercel-labs/agent-skills.git", ref: "main", staging: home.path)
        #expect(snapshot.commit.count == 40)
        #expect(snapshot.files.contains { $0.path == "web-design-guidelines/SKILL.md" })
        #expect(snapshot.files.allSatisfy { !$0.path.contains(".git/") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func pendingReviewsAreBoundedAndUnsafeGitSchemesAreRejected() async throws {
        let (home, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        for _ in 0..<4 { _ = try await service.handle(.init(action: .previewImport, files: bundle())) }
        await #expect(throws: Error.self) { _ = try await service.handle(.init(action: .previewImport, files: bundle())) }
        for url in ["file:///etc", "ssh://server/skills", "https://token@github.com/example/skills", "https://github.com/example/skills?token=secret"] {
            #expect(throws: Error.self) { try ServerSkillsGit.validate(repository: url, ref: "main") }
        }
    }
}
