import Foundation
import Testing
@testable import BloomClient

struct ServerMaintenanceTests {
    @Test func wireValuesRoundTripAndSecretsAreNotDescribed() throws {
        let request = ServerMaintenanceRequest(action: .start, credential: "test-secret", planID: "p1", mode: .whenIdle)
        let command = try request.command()
        let payload = try #require(command.operation["maintenance"]?["_0"])
        let decoded = try JSONDecoder().decode(ServerMaintenanceRequest.self, from: JSONEncoder().encode(payload))
        #expect(decoded.credential == "test-secret")
        #expect(decoded.mode == .whenIdle)
        #expect(!String(describing: request).contains("test-secret"))
        #expect(!String(reflecting: request).contains("test-secret"))
        #expect(!Mirror(reflecting: request).children.contains { $0.label == "credential" })
        for phase in ServerMaintenancePhase.allCases {
            let response = ServerMaintenanceResponse(authorized: true, components: [component], plan: plan,
                jobs: [job(phase: phase)], error: .init(code: "example", message: "Explanation", recovery: "Retry"))
            let roundTrip = try JSONDecoder().decode(ServerMaintenanceResponse.self, from: JSONEncoder().encode(response))
            #expect(roundTrip == response)
        }
    }

    @Test func exportProductionMaintenanceVectorsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["BLOOM_MAINTENANCE_VECTORS_PATH"] else { return }
        var vectors: [[String: JSONValue]] = []
        let requests: [ServerMaintenanceRequest] = [
            .init(action: .inspect), .init(action: .prepare, credential: "test-only", component: .server),
            .init(action: .start, credential: "test-only", planID: "p1", mode: .whenIdle),
            .init(action: .status, credential: "test-only", jobID: "j1", afterSequence: 0),
            .init(action: .cancel, credential: "test-only", jobID: "j1"),
        ]
        for request in requests {
            vectors.append(["name": .string("request-" + request.action.rawValue),
                            "value": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))])
        }
        for phase in ServerMaintenancePhase.allCases {
            let response = ServerMaintenanceResponse(authorized: true, components: [component], plan: plan, jobs: [job(phase: phase)])
            vectors.append(["name": .string("response-" + phase.rawValue),
                            "value": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(vectors).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @Test func onlySuccessfulPhaseIsSuccessAndExpiredPlansCannotStart() {
        #expect(ServerMaintenancePhase.rolledBack.isTerminal)
        #expect(ServerMaintenancePhase.rolledBack.needsAttention)
        #expect(ServerMaintenancePhase.cancelled.isTerminal)
        #expect(!ServerMaintenancePhase.cancelled.needsAttention)
        #expect(!ServerMaintenancePhase.restarting.isTerminal)
        #expect(!plan.isExpired(at: Date(timeIntervalSince1970: 0)))
        var expired = plan; expired.expiresAt = "1970-01-01T00:00:01.123Z"
        #expect(expired.isExpired(at: Date(timeIntervalSince1970: 2)))
        expired.expiresAt = "not a date"
        #expect(expired.isExpired())
    }

    @Test @MainActor func unsupportedServerNeverReceivesTheCredential() async {
        let client = MaintenanceFixtureClient([])
        let session = ServerMaintenanceSession(client: client, supported: false)
        await session.refresh(credential: "test-secret")
        #expect(session.unsupported)
        #expect(session.failure?.code == "unsupported")
        #expect(await client.commands.isEmpty)
    }

    @Test @MainActor func unavailableCapabilityDoesNotBecomeAnAuthenticationFailure() async {
        let client = MaintenanceFixtureClient([.raw(.object(["diagnostics": .object(["_0": .object([:])])]))])
        let session = ServerMaintenanceSession(client: client)
        await session.refresh(credential: "test-secret")
        #expect(session.unsupported)
        #expect(await client.commands.count == 1)
        #expect(await client.commands.first?.operation["diagnostics"] != nil)
    }

    @Test @MainActor func unauthorizedInspectionCannotPrepareOrExposeJobHistory() async {
        let denial = ServerMaintenanceFailure(code: "unauthorized", message: "Access key rejected", recovery: "Enter a valid key")
        let client = MaintenanceFixtureClient([.response(.init(authorized: false, components: [component], jobs: [job(phase: .queued)], error: denial))])
        let session = ServerMaintenanceSession(client: client, supported: true)
        await session.refresh(credential: "wrong-key")
        await session.prepare(component: .server)
        #expect(!session.authorized)
        #expect(session.jobs.isEmpty)
        #expect(session.failure?.isAuthorizationFailure == true)
        #expect(await client.commands.count == 1)
    }

    @Test @MainActor func lostStartResponseIsRecoveredByStatusWithoutResubmitting() async {
        let client = MaintenanceFixtureClient([.response(.init(authorized: true, components: [component])),
            .response(.init(authorized: true, plan: plan)), .lost,
            .response(.init(authorized: true, jobs: [job(phase: .restarting)]))])
        let session = ServerMaintenanceSession(client: client, supported: true)
        await session.refresh(credential: "test-secret")
        await session.prepare(component: .server)
        #expect(session.canStart)
        await session.start()
        #expect(session.pendingMutationID != nil)
        #expect(session.failure?.code == "unconfirmed")
        #expect(!session.canStart)
        await session.poll()
        #expect(session.pendingMutationID == nil)
        #expect(session.jobs.first?.phase == .restarting)
        #expect(session.hasActiveJobs)
        let requests = try? await client.requests()
        #expect(requests?.filter { $0.action == .start }.count == 1)
    }

    @Test @MainActor func explicitRetryUsesTheSameMutationIDAndIntent() async throws {
        let client = MaintenanceFixtureClient([.response(.init(authorized: true, components: [component])),
            .response(.init(authorized: true, plan: plan)), .lost,
            .response(.init(authorized: true, jobs: [job(phase: .waiting)]))])
        let session = ServerMaintenanceSession(client: client, supported: true)
        await session.refresh(credential: "test-secret")
        await session.prepare(component: .server)
        await session.start(mode: .whenIdle)
        let id = try #require(session.pendingMutationID)
        await session.retryPendingMutation()
        let starts = await client.commands.filter { $0.operation["maintenance"]?["_0"]?["action"] == .string("start") }
        #expect(starts.count == 2)
        #expect(starts.allSatisfy { $0.id == id })
        #expect(starts[0] == starts[1])
        #expect(session.pendingMutationID == nil)
        #expect(session.jobs.first?.phase == .waiting)
    }

    @Test @MainActor func cancellationRequiresServerPermissionAndPollMergesLogs() async throws {
        var initial = job(phase: .installing)
        initial.logs = [.init(sequence: 1, message: "First")]; initial.nextSequence = 1; initial.canCancel = false
        var finished = job(phase: .rolledBack)
        finished.logs = [.init(sequence: 2, message: "Restored")]; finished.nextSequence = 2
        let client = MaintenanceFixtureClient([.response(.init(authorized: true, jobs: [initial])),
            .response(.init(authorized: true, jobs: [finished]))])
        let session = ServerMaintenanceSession(client: client, supported: true)
        await session.refresh(credential: "test-secret")
        await session.cancel(jobID: initial.id)
        #expect(await client.commands.count == 1)
        await session.poll(jobID: initial.id)
        #expect(session.jobs.first?.logs.map(\.message) == ["First", "Restored"])
        #expect(session.jobs.first?.phase.needsAttention == true)
        let requests = try await client.requests()
        #expect(requests.last?.afterSequence == 1)
        #expect(!session.hasActiveJobs)
    }

    @Test @MainActor func responseDiagnosticsCannotEchoCredentialAndLockDropsPrivateState() async {
        var value = job(phase: .failed); value.logs = [.init(sequence: 1, message: "Do not leak test-secret")]
        let client = MaintenanceFixtureClient([.response(.init(authorized: true, jobs: [value]))])
        let session = ServerMaintenanceSession(client: client, supported: true)
        await session.refresh(credential: "test-secret")
        #expect(session.jobs.first?.logs.first?.message == "Do not leak [redacted]")
        #expect(String(reflecting: session) == "Server maintenance session")
        session.clearCredential()
        #expect(!session.authorized)
        #expect(session.jobs.isEmpty)
        #expect(session.plan == nil)
    }

    private var component: ServerMaintenanceComponent {
        .init(id: .server, title: "Bloom Server", installedVersion: "1", availableVersion: "2", canUpdate: true, detail: "Ready")
    }
    private var plan: ServerMaintenancePlan {
        .init(id: "p1", component: .server, fromVersion: "1", targetVersion: "2", summary: "Update server",
              restarts: ["Bloom Server"], expiresAt: "2999-01-01T00:00:00Z")
    }
    private func job(phase: ServerMaintenancePhase) -> ServerMaintenanceJob {
        .init(id: "j1", planID: "p1", component: .server, targetVersion: "2", phase: phase,
              canCancel: !phase.isTerminal, updatedAt: "2026-09-12T12:00:00Z")
    }
}

private actor MaintenanceFixtureClient: RemoteRequesting {
    enum Reply: Sendable { case response(ServerMaintenanceResponse), raw(JSONValue), lost }
    private var replies: [Reply]
    var commands: [RemoteCommand] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func request(_ command: RemoteCommand) throws -> JSONValue {
        commands.append(command)
        guard !replies.isEmpty else { throw ConnectionFailure("Unexpected request") }
        switch replies.removeFirst() {
        case .response(let response):
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
            return .object(["maintenance": .object(["_0": value])])
        case .raw(let value): return value
        case .lost: throw ConnectionFailure("Connection lost")
        }
    }
    func requests() throws -> [ServerMaintenanceRequest] {
        try commands.compactMap { command in
            guard let value = command.operation["maintenance"]?["_0"] else { return nil }
            return try JSONDecoder().decode(ServerMaintenanceRequest.self, from: JSONEncoder().encode(value))
        }
    }
}
