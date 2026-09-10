import Foundation
import Testing
import BloomClient
@testable import BloomCore

struct ServerUIBrokerTests {
    private func attach(_ broker: ServerUIBroker, workspace: String = "one", actions: [String] = ["pane_open"]) async throws -> RemoteUILease {
        let result = try await broker.handle(.attach(workspaceID: WorkspaceID(workspace), clientID: UUID(), actions: actions), registrationID: UUID())
        guard case .attached(let lease) = result else { throw ServerFailure("Expected lease") }
        return lease
    }
    private func poll(_ broker: ServerUIBroker, lease: RemoteUILease, wait: Bool = false) async throws -> RemoteUIBatch {
        let result = try await broker.handle(.poll(leaseID: lease.id, token: lease.token, wait: wait), registrationID: UUID())
        guard case .requests(let batch) = result else { throw ServerFailure("Expected requests") }
        return batch
    }

    @Test func onlyTheAttachedWorkspaceReceivesAndAnswersItsRequest() async throws {
        let broker = ServerUIBroker()
        let one = try await attach(broker), two = try await attach(broker, workspace: "two")
        let work = Task { await broker.perform(.init(name: "pane_open"), workspaceID: one.workspaceID) }
        let batch = try await poll(broker, lease: one, wait: true)
        let request = try #require(batch.requests.first)
        #expect(try await poll(broker, lease: two).requests.isEmpty)
        await #expect(throws: ServerFailure.self) {
            try await broker.handle(.respond(leaseID: two.id, token: two.token, requestID: request.id, result: .init(text: "wrong")), registrationID: UUID())
        }
        #expect(try await broker.handle(.claim(leaseID: one.id, token: one.token, requestID: request.id), registrationID: UUID()) == .claimed(true))
        _ = try await broker.handle(.respond(leaseID: one.id, token: one.token, requestID: request.id, result: .init(text: "opened")), registrationID: UUID())
        #expect(await work.value.text == "opened")
        await broker.shutdown()
    }

    @Test func attachmentCannotStealAnotherClientsLease() async throws {
        let broker = ServerUIBroker()
        let lease = try await attach(broker)
        await #expect(throws: ServerFailure.self) { try await attach(broker) }
        await #expect(throws: ServerFailure.self) {
            try await broker.handle(.poll(leaseID: lease.id, token: "wrong", wait: false), registrationID: UUID())
        }
        await broker.shutdown()
    }

    @Test func uncertainAttachmentRetriesReturnOnlyTheirOwnLease() async throws {
        let broker = ServerUIBroker(), id = UUID()
        let action = RemoteUIBridgeOperation.attach(workspaceID: WorkspaceID("one"), clientID: UUID(), actions: ["pane_open"])
        let first = try await broker.handle(action, registrationID: id)
        let second = try await broker.handle(action, registrationID: id)
        #expect(first == second)
        await #expect(throws: ServerFailure.self) { try await broker.handle(action, registrationID: UUID()) }
        await broker.shutdown()
    }

    @Test func missingOrUnsupportedClientsRefuseWithoutQueueingAnything() async throws {
        let broker = ServerUIBroker()
        #expect(await broker.perform(.init(name: "pane_open"), workspaceID: WorkspaceID("missing")).isError)
        let lease = try await attach(broker, actions: ["pane_list"])
        #expect(await broker.perform(.init(name: "pane_open"), workspaceID: lease.workspaceID).isError)
        #expect(try await poll(broker, lease: lease).requests.isEmpty)
        await broker.shutdown()
    }

    @Test func detachmentCancelsPendingActionsAndRejectsLateResponses() async throws {
        let broker = ServerUIBroker(), lease = try await attach(broker)
        let work = Task { await broker.perform(.init(name: "pane_open"), workspaceID: lease.workspaceID) }
        let request = try #require(try await poll(broker, lease: lease, wait: true).requests.first)
        _ = try await broker.handle(.detach(leaseID: lease.id, token: lease.token), registrationID: UUID())
        #expect(await work.value.isError)
        let replacement = try await attach(broker)
        await #expect(throws: ServerFailure.self) {
            try await broker.handle(.respond(leaseID: replacement.id, token: replacement.token, requestID: request.id, result: .init()), registrationID: UUID())
        }
        await broker.shutdown()
    }

    @Test func cancelledAgentRequestCannotBeAnsweredLater() async throws {
        let broker = ServerUIBroker(), lease = try await attach(broker)
        let work = Task { await broker.perform(.init(name: "pane_open"), workspaceID: lease.workspaceID) }
        let request = try #require(try await poll(broker, lease: lease, wait: true).requests.first)
        work.cancel()
        #expect(await work.value.isError)
        await #expect(throws: ServerFailure.self) {
            try await broker.handle(.respond(leaseID: lease.id, token: lease.token, requestID: request.id, result: .init()), registrationID: UUID())
        }
        await broker.shutdown()
    }

    @Test func claimingIsScopedAndCancelledQueuedRequestsCannotBeClaimed() async throws {
        let broker = ServerUIBroker(), one = try await attach(broker), two = try await attach(broker, workspace: "two")
        let work = Task { await broker.perform(.init(name: "pane_open"), workspaceID: one.workspaceID) }
        let request = try #require(try await poll(broker, lease: one, wait: true).requests.first)
        #expect(try await broker.handle(.claim(leaseID: two.id, token: two.token, requestID: request.id), registrationID: UUID()) == .claimed(false))
        await #expect(throws: ServerFailure.self) {
            try await broker.handle(.respond(leaseID: one.id, token: one.token, requestID: request.id, result: .init()), registrationID: UUID())
        }
        let claim = RemoteUIBridgeOperation.claim(leaseID: one.id, token: one.token, requestID: request.id)
        #expect(try await broker.handle(claim, registrationID: UUID()) == .claimed(true))
        #expect(try await broker.handle(claim, registrationID: UUID()) == .claimed(true))
        work.cancel()
        #expect(await work.value.isError)
        #expect(try await broker.handle(claim, registrationID: UUID()) == .claimed(false))
        await broker.shutdown()
    }

    @Test func unresponsiveClientHasABoundedDeadline() async throws {
        let broker = ServerUIBroker(requestTimeout: .milliseconds(1)), lease = try await attach(broker)
        let result = await broker.perform(.init(name: "pane_open"), workspaceID: lease.workspaceID)
        #expect(result.isError)
        #expect(result.text.contains("time"))
        await broker.shutdown()
    }

    @Test func duplicateResultIsIdempotentButDifferentResultIsRejected() async throws {
        let broker = ServerUIBroker(), lease = try await attach(broker)
        let work = Task { await broker.perform(.init(name: "pane_open"), workspaceID: lease.workspaceID) }
        let request = try #require(try await poll(broker, lease: lease, wait: true).requests.first)
        #expect(try await broker.handle(.claim(leaseID: lease.id, token: lease.token, requestID: request.id), registrationID: UUID()) == .claimed(true))
        let answer = RemoteUIBridgeOperation.respond(leaseID: lease.id, token: lease.token, requestID: request.id, result: .init(text: "opened"))
        _ = try await broker.handle(answer, registrationID: UUID())
        _ = try await broker.handle(answer, registrationID: UUID())
        #expect(await work.value.text == "opened")
        await #expect(throws: ServerFailure.self) {
            try await broker.handle(.respond(leaseID: lease.id, token: lease.token, requestID: request.id, result: .init(text: "different")), registrationID: UUID())
        }
        await broker.shutdown()
    }
}
