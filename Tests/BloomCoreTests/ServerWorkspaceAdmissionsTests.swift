import Foundation
import Testing
@testable import BloomCore

struct ServerWorkspaceAdmissionsTests {
    @Test func transitionRefusesNewMutationsAndWaitsForExistingTickets() async throws {
        let owner = ServerWorkspaceAdmissions(), id = WorkspaceID.new()
        let first = try owner.admit(id), second = try owner.admit(id)
        let transition = try owner.beginTransition(id)
        #expect(throws: ServerFailure.self) { try owner.admit(id) }
        #expect(throws: ServerFailure.self) { try owner.beginTransition(id) }
        let waiting = Task { try await transition.drain() }
        await waitUntil("archive waits for admitted work") { owner.waitingCount == 1 }
        first.release(); first.release()
        #expect(owner.waitingCount == 1)
        second.release()
        try await waiting.value
        transition.finish(closed: true)
        #expect(throws: ServerFailure.self) { try owner.admit(id) }
        let restoration = try owner.beginTransition(id)
        try await restoration.drain()
        restoration.finish(closed: false)
        let admitted = try owner.admit(id)
        admitted.release()
    }

    @Test func cancelledArchiveReopensWithoutLosingItsOutstandingMutations() async throws {
        let owner = ServerWorkspaceAdmissions(), id = WorkspaceID.new()
        let permit = try owner.admit(id)
        let cancelled = try owner.beginTransition(id)
        let waiting = Task { try await cancelled.drain() }
        await waitUntil("transition starts waiting") { owner.waitingCount == 1 }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        cancelled.finish(closed: false)
        let retry = try owner.beginTransition(id)
        let draining = Task { try await retry.drain() }
        await waitUntil("retry still owns previous mutation") { owner.waitingCount == 1 }
        cancelled.finish(closed: false)
        #expect(throws: ServerFailure.self) { try owner.admit(id) }
        permit.release()
        try await draining.value
        retry.finish(closed: false)
    }

    @Test func shutdownRejectsAdmissionAndCancelsTransitionsButStillDrainsTickets() async throws {
        let owner = ServerWorkspaceAdmissions(), id = WorkspaceID.new()
        let permit = try owner.admit(id)
        let transition = try owner.beginTransition(id)
        let waiting = Task { try await transition.drain() }
        await waitUntil("transition starts waiting") { owner.waitingCount == 1 }
        owner.stop()
        await #expect(throws: ServerFailure.self) { try await waiting.value }
        #expect(throws: ServerFailure.self) { try owner.admit(.new()) }
        permit.release()
        await owner.waitUntilIdle()
    }

    @Test func protocolMutationsShareOneWorkspaceRoutingPolicy() {
        let id = WorkspaceID.new(), session = SessionID.new()
        let direct: [ServerOperation] = [
            .workspace(workspaceID: id, action: .uploadFile(name: "a", data: Data())),
            .workspace(workspaceID: id, action: .runSetup),
            .workspace(workspaceID: id, action: .newSession(agent: .claudeCode, model: "sonnet", effort: "medium", permissionMode: .auto)),
            .terminalStream(workspaceID: id, name: "main"),
        ]
        for operation in direct { #expect(operation.workspaceMutation == .workspace(id)) }
        let conversations: [ServerOperation] = [
            .send(sessionID: session, text: "hello"), .stop(sessionID: session), .closeSession(sessionID: session),
            .setComposer(sessionID: session, controls: ComposerControls()),
            .cancelQueued(sessionID: session, deliveryID: .new()),
        ]
        for operation in conversations { #expect(operation.workspaceMutation == .session(session)) }
        for action in [ServerWorkspaceAction.archive(confirmation: UUID()), .restore, .archivePreview, .files] {
            #expect(ServerOperation.workspace(workspaceID: id, action: action).workspaceMutation == nil)
        }
    }
}
