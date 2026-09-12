import Foundation
import Testing
@testable import BloomClient

struct CreationTests {
    private func project() throws -> RemoteProject {
        try JSONDecoder().decode(RemoteProject.self, from: Data(#"{"id":"repo","name":"Example","path":"/server/project","hidden":false,"defaultBranch":"main"}"#.utf8))
    }
    private func context(agents: [AgentKind] = [.codex]) -> RemoteWorkspaceContext {
        RemoteWorkspaceContext(branches: ["main"], branchPrefix: "user/", hasSetupScript: true,
            composer: RemoteComposerState(controls: ComposerControls(model: "gpt-test", agentKind: .codex), availableAgents: agents), files: [])
    }
    @Test func blankChatCreatesSessionWithoutSubmittingTheNameAsAPrompt() throws {
        let context = context()
        let request = try RemoteCreationRequest.planned(project: project(), name: "Explore", prompt: "  ", mode: .chat,
            context: context, controls: context.composer.controls, baseBranch: "main", checkout: nil, runSetupScript: false)
        #expect(request.name == "Explore" && request.prompt == nil && request.mode == nil)
        #expect(request.runSetupScript == false && request.baseBranch == "main")
    }
    @Test(arguments: [WorkspaceStartMode.terminal, .browser]) func nonAgentWorkspacesDoNotRequireAnInstalledAgent(mode: WorkspaceStartMode) throws {
        let context = context(agents: [])
        let request = try RemoteCreationRequest.planned(project: project(), name: "Preview", prompt: "Old chat draft", mode: mode,
            context: context, controls: context.composer.controls, baseBranch: nil, checkout: nil, runSetupScript: true)
        #expect(request.mode == mode && request.prompt == nil)
    }
    @Test func branchHeldElsewhereIsRefusedBeforeCreation() throws {
        let context = context()
        #expect(throws: ConnectionRefusal.self) {
            try RemoteCreationRequest.planned(project: project(), name: "Review", prompt: "", mode: .chat, context: context,
                controls: context.composer.controls, baseBranch: nil,
                checkout: .branch(ExistingBranch(name: "feature", isLocal: true, inUseBy: .workspace("Existing"))), runSetupScript: true)
        }
    }
    @Test @MainActor func uncertainCreationSurvivesRelaunchAndUnrelatedAcknowledgements() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pending.json")
        let store = PendingCreationStore(file: file)
        let command = RemoteCommand.call("create", ["_0": .object(["name": .string("Work")])])
        let prepared = try store.prepare(command, origin: "https://SERVER.example:443", scope: "workspace:repo")
        let reopened = PendingCreationStore(file: file)
        #expect(try reopened.pending(origin: "https://server.example", scope: "workspace:repo") == prepared)
        let replacement = RemoteCommand.call("create")
        #expect(try reopened.prepare(replacement, origin: "https://server.example", scope: "workspace:repo") == prepared)
        try reopened.acknowledge(replacement, origin: "https://server.example", scope: "workspace:repo")
        #expect(try reopened.pending(origin: "https://server.example", scope: "workspace:repo") == prepared)
        try reopened.acknowledge(prepared, origin: "https://server.example", scope: "workspace:repo")
        #expect(try reopened.pending(origin: "https://server.example", scope: "workspace:repo") == nil)
    }
    @Test @MainActor func malformedRecoveryAndCredentialOriginsCannotBeOverwritten() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pending.json")
        try Data("not json".utf8).write(to: file)
        let store = PendingCreationStore(file: file)
        #expect(throws: (any Error).self) { try store.prepare(.call("create"), origin: "https://server.example", scope: "repo") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
        #expect(throws: ConnectionFailure.self) { try store.pending(origin: "https://user:password@server.example", scope: "repo") }
    }
}
