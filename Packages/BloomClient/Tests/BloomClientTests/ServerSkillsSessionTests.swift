import Foundation
import Testing
@testable import BloomClient

@MainActor struct ServerSkillsSessionTests {
    private let skill = ServerSkill(id: "skill-a", name: "review", description: "Review changes", source: .git,
        revision: "revision-a", enabledAgents: [.claude], fileCount: 1, byteCount: 20,
        repositoryURL: "https://github.com/example/skills", commit: "abc123", collectionID: "collection-a", path: "review")

    private func plan() -> ServerSkillsPlan {
        .init(id: "plan-a", source: .git, skills: [skill], repositoryURL: skill.repositoryURL,
            commit: skill.commit, collectionID: "collection-a", expiresAt: Date().addingTimeInterval(300), warnings: [])
    }

    @Test func unsupportedServerDoesNotReceiveSkillRequests() async {
        let client = SkillsClient(supported: false)
        let session = ServerSkillsSession(client: client)
        let success = await session.refresh()
        #expect(!success && session.unsupported)
        #expect(await client.commands().isEmpty)
    }

    @Test func uncertainApplyRetriesTheExactReviewedSelectionAndUUID() async {
        let client = SkillsClient(replies: [.response(.init(plan: plan())), .lost,
            .response(.init(skills: [skill])), .response(.init(skills: [skill]))])
        let session = ServerSkillsSession(client: client)
        await session.previewGit(repositoryURL: skill.repositoryURL!)
        let success = await session.apply(planID: "plan-a", selectedSkillNames: ["review"], agents: [.codex])
        #expect(!success && session.pendingMutationID != nil)
        let originalID = session.pendingMutationID
        await session.refresh()
        #expect(session.pendingMutationID == originalID)
        let blocked = await session.apply(planID: "plan-a", selectedSkillNames: ["review"], agents: [.claude])
        #expect(!blocked)
        let retried = await session.retryPendingMutation()
        let applies = await client.commands().filter { $0.operation["skills"]?["_0"]?["action"]?.stringValue == "apply" }
        #expect(retried && session.pendingMutationID == nil && session.plan == nil)
        #expect(applies.count == 2 && applies.first == applies.last)
        #expect(applies.first?.operation["skills"]?["_0"]?["agents"] == .array([.string("codex")]))
    }

    @Test func definiteRefusalClearsPendingRequestWithoutClaimingSuccess() async {
        let client = SkillsClient(replies: [.response(.init(plan: plan())), .refused])
        let session = ServerSkillsSession(client: client)
        await session.previewGit(repositoryURL: skill.repositoryURL!)
        let success = await session.apply(planID: "plan-a", selectedSkillNames: ["review"], agents: [])
        #expect(!success && session.pendingMutationID == nil)
        #expect(session.error == "Reviewed source changed.")
        #expect(session.plan?.id == "plan-a")
    }

    @Test func readingInstructionsPreservesInventoryAndReviewPlan() async {
        let client = SkillsClient(replies: [.response(.init(skills: [skill])), .response(.init(plan: plan())),
            .response(.init(content: "# Review\nInspect the changes."))])
        let session = ServerSkillsSession(client: client)
        await session.refresh()
        await session.previewGit(repositoryURL: skill.repositoryURL!)
        await session.readDetails(skillID: skill.id, planID: "plan-a")
        #expect(session.skills == [skill] && session.plan?.id == "plan-a")
        #expect(session.contentSkillID == skill.id && session.contentPlanID == "plan-a")
        #expect(session.content == "# Review\nInspect the changes.")
    }

    @Test func staleRevisionAndUnreviewedNamesNeverReachTheServer() async {
        let client = SkillsClient(replies: [.response(.init(skills: [skill])), .response(.init(plan: plan()))])
        let session = ServerSkillsSession(client: client)
        await session.refresh()
        let removed = await session.remove(skillID: skill.id, revision: "stale")
        #expect(!removed)
        await session.previewGit(repositoryURL: skill.repositoryURL!)
        let applied = await session.apply(planID: "plan-a", selectedSkillNames: ["unreviewed"], agents: [.claude])
        #expect(!applied)
        #expect(await client.commands().count == 2)
    }

    @Test func reconnectKeepsPendingIntentAndDoesNotAutomaticallySubmitIt() async {
        let first = SkillsClient(replies: [.response(.init(plan: plan())), .lost])
        let session = ServerSkillsSession(client: first)
        await session.previewGit(repositoryURL: skill.repositoryURL!)
        await session.apply(planID: "plan-a", selectedSkillNames: ["review"], agents: [.claude])
        let command = await first.commands().last
        let replacement = SkillsClient(replies: [.response(.init(skills: [skill]))])
        session.reconnect(client: replacement)
        #expect(await replacement.commands().isEmpty)
        await session.retryPendingMutation()
        #expect(await replacement.commands().first == command)
        #expect(session.pendingMutationID == nil)
    }

    @Test func newerInstructionSelectionWinsOverAnOlderRead() async throws {
        let client = DelayedSkillsClient()
        let session = ServerSkillsSession(client: client)
        let old = Task { await session.readDetails(skillID: "old") }
        await client.waitForRead("old")
        let new = Task { await session.readDetails(skillID: "new") }
        await client.waitForRead("new")
        try await client.finish("new", content: "New instructions")
        #expect(await new.value)
        try await client.finish("old", content: "Old instructions")
        #expect(await old.value == false)
        #expect(session.contentSkillID == "new" && session.content == "New instructions")
        #expect(session.activity == .idle)
    }

    @Test func mutationsKeepTheSelectedWorkspaceScope() async {
        let client = SkillsClient(replies: [.response(.init(skills: [skill])), .response(.init(skills: [skill]))])
        let session = ServerSkillsSession(client: client, workspaceID: WorkspaceID("workspace-a"))
        await session.refresh()
        await session.setEnabled(skillID: skill.id, revision: skill.revision, agents: [.codex])
        let commands = await client.commands()
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.operation["skills"]?["_0"]?["workspaceID"]?.stringValue == "workspace-a" })
    }
}

private actor DelayedSkillsClient: RemoteRequesting {
    private var reads: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        if command.operation["diagnostics"] != nil {
            let diagnostics = ServerDiagnostics(checkedAt: Date(), hostname: "test", operatingSystem: "Linux", account: "bloom", checks: [], skillManagement: true)
            let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(diagnostics))
            return .object(["diagnostics": .object(["_0": json])])
        }
        let id = command.operation["skills"]?["_0"]?["skillID"]?.stringValue ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            reads[id] = continuation
            waiting.removeValue(forKey: id)?.resume()
        }
    }
    func waitForRead(_ id: String) async {
        if reads[id] != nil { return }
        await withCheckedContinuation { waiting[id] = $0 }
    }
    func finish(_ id: String, content: String) throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ServerSkillsResponse(content: content)))
        reads.removeValue(forKey: id)?.resume(returning: .object(["skills": .object(["_0": json])]))
    }
}

private actor SkillsClient: RemoteRequesting {
    enum Reply: Sendable { case response(ServerSkillsResponse), lost, refused }
    private let supported: Bool
    private var replies: [Reply]
    private var received: [RemoteCommand] = []
    init(supported: Bool = true, replies: [Reply] = []) { self.supported = supported; self.replies = replies }
    func commands() -> [RemoteCommand] { received }
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        if command.operation["diagnostics"] != nil {
            let diagnostics = ServerDiagnostics(checkedAt: Date(), hostname: "test", operatingSystem: "Linux", account: "bloom", checks: [], skillManagement: supported)
            return .object(["diagnostics": .object(["_0": try json(diagnostics)])])
        }
        received.append(command)
        guard !replies.isEmpty else { throw ConnectionFailure("Unexpected request.") }
        switch replies.removeFirst() {
        case .response(let response): return .object(["skills": .object(["_0": try json(response)])])
        case .lost: throw ConnectionFailure("Connection interrupted.")
        case .refused: throw ConnectionRefusal("Reviewed source changed.")
        }
    }
    private func json(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
