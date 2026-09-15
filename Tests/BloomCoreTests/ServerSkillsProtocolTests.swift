import Foundation
import Testing
import BloomClient
@testable import BloomCore

@Suite(.scratchDirectory)
struct ServerSkillsProtocolTests {
    @Test func reviewedSkillCommandsAreJournalledAndRetryDoesNotApplyTwice() async throws {
        let store = try makeTestStore("skill-protocol")
        let home = TestScratch.unique("home")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let service = ServerSkillsService(directory: home + "/managed", home: home)
        let runtime = ServerRuntime(store: store, installedAgents: { _ in [] },
            workspaceAdmissions: ServerWorkspaceAdmissions(), skillsService: service)
        let read = ServerRequest(.skills(.init(action: .inspect)))
        guard case .skills = await runtime.respond(to: read).result else { Issue.record("Expected a skill inventory"); return }
        #expect(try await store.setting("server.command.\(read.id.uuidString)") == nil)
        let file = ServerSkillFile(path: "review-test/SKILL.md", data: Data("---\nname: review-test\ndescription: A test skill\n---\nExplain the project.\n".utf8))
        let prepare = ServerRequest(.skills(.init(action: .previewImport, files: [file])))
        guard case .skills(let preview) = await runtime.respond(to: prepare).result,
              let plan = preview.plan else { Issue.record("Expected a review plan"); return }
        let apply = ServerRequest(.skills(.init(action: .apply, planID: plan.id, selectedSkillNames: ["review-test"], agents: [.claude])))
        let first = await runtime.respond(to: apply)
        let retried = await runtime.respond(to: apply)
        guard case .skills(let installed) = first.result, case .skills(let replay) = retried.result else {
            Issue.record("Expected installed skill result"); return
        }
        #expect(installed == replay)
        #expect(installed.skills.filter(\.isManaged).count == 1)
        let reused = ServerRequest(.skills(.init(action: .remove, skillID: "different", revision: "different")), id: apply.id)
        guard case .failure = await runtime.respond(to: reused).result else { Issue.record("A changed command must be refused"); return }
        await runtime.shutdown()
    }

    @Test func skillEnvelopeRoundTripsAndReadOperationsHaveNoMutationScope() throws {
        let request = ServerRequest(.skills(.init(action: .read, skillID: "example")))
        #expect(try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(!request.operation.mutates)
        #expect(request.operation.workspaceMutation == nil)
        #expect(ServerOperation.skills(.init(action: .previewGit, repositoryURL: "https://example.com/skills.git")).mutates)
    }

    @Test func olderDiagnosticsDoNotImplySkillsSupport() throws {
        let diagnostic = ServerDiagnostics(checkedAt: Date(), hostname: "test", operatingSystem: "test", account: "test", checks: [])
        #expect(diagnostic.skillManagement == nil)
    }
}
