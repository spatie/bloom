import Foundation
import Testing
@testable import BloomClient

struct RemoteLifecycleTests {
    @Test func catalogueAndTranscriptPreserveLifecycleStateAndDefaultOlderFields() throws {
        let archived = #"{"id":"archived","repoID":"repo","name":"Old work","branch":"old","setupState":"succeeded","setupLog":"","port":3000}"#
        let catalogue = try JSONDecoder().decode(RemoteCatalogue.self, from: Data("{\"repositories\":[],\"workspaces\":[],\"sessions\":[],\"archivedWorkspaces\":[\(archived)]}".utf8))
        #expect(catalogue.archivedWorkspaces.first?.id == WorkspaceID("archived"))
        #expect(try JSONDecoder().decode(RemoteCatalogue.self, from: Data(#"{"repositories":[],"workspaces":[],"sessions":[]}"#.utf8)).archivedWorkspaces.isEmpty)
        let base = #"{"session":{"id":"session","title":"Chat","model":"model","agentKind":"codex","state":"idle"},"messages":[],"pendingQuestions":[],"isBusy":false,"streamingText":"""#
        let current = try JSONDecoder().decode(RemoteTranscript.self, from: Data((base + #", "queuedPrompts":[{"id":"delivery","text":"Next task"}],"permissionDecisions":{"ask":"allowed"}}"#).utf8))
        var buffer = TranscriptBuffer()
        buffer.apply(current)
        #expect(buffer.queuedPrompts == [.init(id: DeliveryID("delivery"), text: "Next task")])
        #expect(buffer.permissionDecisions == ["ask": "allowed"])
        let old = try JSONDecoder().decode(RemoteTranscript.self, from: Data((base + "}").utf8))
        buffer.apply(old)
        #expect(buffer.queuedPrompts.isEmpty)
        #expect(buffer.permissionDecisions.isEmpty)
    }

    @Test func incompleteArchiveReportsFailClosed() throws {
        let incomplete = Data(#"{"hasUncommittedChanges":false,"untrackedFiles":[],"unpushedCommits":0,"isBranchMerged":true}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkspaceSafetyReport.self, from: incomplete) }
        let report = WorkspaceSafetyReport(hasUncommittedChanges: true, modifiedIgnoredFiles: [".env"])
        #expect(!report.isSafeToDiscard(deletingBranch: false))
        #expect(report.irreversibleLosses(deletingBranch: false) == ["uncommitted changes to tracked files"])
        #expect(!report.ignoredFileNotes.isEmpty)
    }

    @Test func lifecycleHelpersKeepExplicitIDsAndRequireAcknowledgement() async throws {
        let client = LifecycleClient()
        let service = RemoteWorkspaceService(client: client)
        let ids = [UUID(), UUID(), UUID()], confirmation = UUID(), workspace = WorkspaceID("work")
        try await service.cancelQueued(sessionID: SessionID("session"), deliveryID: DeliveryID("delivery"), commandID: ids[0])
        try await service.archive(workspaceID: workspace, confirmation: confirmation, commandID: ids[1])
        try await service.restore(workspaceID: workspace, commandID: ids[2])
        let sent = await client.commands
        #expect(sent.count == 3)
        #expect(sent.map(\.id) == ids)
        #expect(sent[0].operation["cancelQueued"]?["deliveryID"] == .string("delivery"))
        #expect(sent[1].operation["workspace"]?["action"]?["archive"]?["confirmation"] == .string(confirmation.uuidString))
        await client.setUnexpectedReply()
        await #expect(throws: ConnectionFailure.self) { try await service.restore(workspaceID: workspace, commandID: ids[2]) }
        #expect(await client.commands.count == 4)
        #expect(await client.commands.last == sent[2])
    }
}

private actor LifecycleClient: RemoteRequesting {
    var commands: [RemoteCommand] = []
    private var result: JSONValue = .object(["accepted": .object([:])])
    func setUnexpectedReply() { result = .object(["hello": .object(["name": .string("server")])]) }
    func request(_ command: RemoteCommand) async throws -> JSONValue { commands.append(command); return result }
}
