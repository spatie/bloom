import Foundation
import Testing
@testable import BloomCore

@Suite("Plan approval", .scratchDirectory)
struct PlanApprovalTests {
    static let askLine = #"{"type":"control_request","request_id":"plan-1","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","tool_use_id":"plan-tool-1","input":{"plan":"Create two files, then edit the first."},"requires_user_interaction":true}}"#

    static func ask() throws -> PermissionAsk {
        try #require(PermissionAsk.decode(payload: Data(askLine.utf8)))
    }

    @Test("approving sends only the selected mode, scoped to this session", arguments: PlanApproval.modes)
    func approvalWire(mode: PermissionMode) throws {
        let ask = try Self.ask()
        let line = try PermissionAnswer.encode(ask: ask, decision: .approvePlan(mode: mode))
        let envelope = try #require(JSONValue.parse(line))
        let response = try #require(envelope["response"]?["response"])
        #expect(envelope["response"]?["request_id"]?.stringValue == ask.requestID)
        #expect(response["behavior"]?.stringValue == "allow")
        #expect(response["updatedInput"] == ask.input)
        #expect(response["updatedPermissions"] == .array([.object([
            "type": .string("setMode"), "mode": .string(mode.cliValue), "destination": .string("session"),
        ])]))
        #expect(PlanApproval.approvedMode(storedDecision: PermissionDecision.approvePlan(mode: mode).storedName) == mode)
    }

    @Test("plan decisions cannot grant permissions on an unrelated tool or keep implementation in Plan")
    func invalidDecisions() throws {
        var ordinary = try Self.ask()
        ordinary.toolName = "Write"
        #expect(throws: PlanApprovalError.self) {
            try PermissionAnswer.encode(ask: ordinary, decision: .approvePlan(mode: .bypassPermissions))
        }
        let plan = try Self.ask()
        for mode in [PermissionMode.plan, .autoReview] {
            #expect(throws: PlanApprovalError.self) {
                try PermissionAnswer.encode(ask: plan, decision: .approvePlan(mode: mode))
            }
        }
    }

    @Test("the offered mode survives transcript persistence without changing the tool input")
    func persistedOffer() throws {
        let ask = try Self.ask()
        let prepared = PlanApproval.preparing(ask, mode: .bypassPermissions)
        let restored = try #require(PermissionAsk.decode(payload: prepared.raw))
        #expect(restored.implementationMode == .bypassPermissions)
        #expect(restored.input == ask.input)
        #expect(restored.requestID == ask.requestID)
    }

    @Test("a plan can never be approved by an always-allow tool rule")
    func requiresPlanReview() throws {
        var ask = try Self.ask()
        ask.requiresUserInteraction = false
        ask.suggestions = [PermissionSuggestion(
            type: "addRules", behavior: "allow", rules: [PermissionRule(toolName: "ExitPlanMode")]
        )]
        #expect(!ask.canWiden)
    }

    @Test("keeping planning sends no permission updates")
    func keepPlanning() throws {
        let line = try PermissionAnswer.encode(
            ask: Self.ask(), decision: .deny(message: PlanApproval.keepPlanningMessage, endsTurn: false)
        )
        let response = try #require(JSONValue.parse(line)?["response"]?["response"])
        #expect(response["behavior"]?.stringValue == "deny")
        #expect(response["updatedPermissions"] == nil)
        #expect(response["interrupt"] == .bool(false))
    }

    private func session(in store: Store, mode: PermissionMode) async throws -> Session {
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/plan-repo"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/plan-workspace", baseBranch: "main"
        ))
        return try await store.upsert(Session(workspaceID: workspace.id, permissionMode: mode))
    }

    @Test("starting in Plan remembers the configured implementation mode")
    func startsInPlan() async throws {
        let store = try makeTestStore("plan-default")
        try await store.setSetting(AppDefaults.Key.permissionMode, PermissionMode.acceptEdits.rawValue)
        let session = try await session(in: store, mode: .plan)
        try await store.setSetting(AppDefaults.Key.permissionMode, PermissionMode.bypassPermissions.rawValue)
        #expect(try await store.planImplementationMode(sessionID: session.id, hasWorktree: true) == .acceptEdits)
        #expect(try await store.session(id: session.id)?.permissionMode == .plan)
    }

    @Test("entering Plan retains the last session choice through both preference write paths")
    func remembersSessionChoice() async throws {
        let store = try makeTestStore("plan-remember")
        let session = try await session(in: store, mode: .auto)
        try await store.updateSessionPreferences(id: session.id, permissionMode: .plan)
        #expect(try await store.planImplementationMode(sessionID: session.id, hasWorktree: true) == .auto)
        try await store.update(sessionID: session.id) { $0.permissionMode = .acceptEdits }
        try await store.update(sessionID: session.id) { $0.permissionMode = .plan }
        #expect(try await store.planImplementationMode(sessionID: session.id, hasWorktree: true) == .acceptEdits)
    }

    @Test("first-open Plan defaults replace a new chat's placeholder bypass mode")
    func firstOpenDefaults() async throws {
        let store = try makeTestStore("plan-first-open")
        let session = try await session(in: store, mode: AppDefaults.fallbackPermissionMode)
        try await store.updateSessionPreferences(
            id: session.id, permissionMode: .plan, implementationMode: .acceptEdits
        )
        #expect(try await store.planImplementationMode(sessionID: session.id, hasWorktree: true) == .acceptEdits)
        #expect(try await store.session(id: session.id)?.permissionMode == .plan)
    }

    @Test("a legacy session remembers its mode when entering Plan for the first time")
    func legacySession() async throws {
        let store = try makeTestStore("plan-legacy")
        let session = try await session(in: store, mode: .acceptEdits)
        try await store.setSetting(PlanApproval.modeKey(sessionID: session.id), nil)
        try await store.updateSessionPreferences(id: session.id, permissionMode: .plan)
        #expect(try await store.planImplementationMode(sessionID: session.id, hasWorktree: true) == .acceptEdits)
    }

    @Test("a chat without a worktree never inherits the app's bypass default")
    func noWorktree() async throws {
        let store = try makeTestStore("plan-no-worktree")
        let session = try await store.upsert(Session(workspaceID: nil, permissionMode: .plan))
        #expect(try await store.planImplementationMode(sessionID: session.id, hasWorktree: false) == .auto)
    }
}
