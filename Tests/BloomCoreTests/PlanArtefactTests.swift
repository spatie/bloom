import Foundation
import Testing
@testable import BloomCore

@Suite("Plan artefacts", .scratchDirectory)
struct PlanArtefactTests {
    @Test("Provider replay is idempotent while refinements retain previous versions")
    func revisions() async throws {
        let store = try makeTestStore("plan-versions")
        let sessionID = SessionID.new()
        let first = try await store.recordPlan(sessionID: sessionID, sourceID: "item-1", markdown: "# First\nKeep this")
        let replay = try await store.recordPlan(sessionID: sessionID, sourceID: "item-1", markdown: "# First\nKeep this")
        let second = try await store.recordPlan(sessionID: sessionID, sourceID: "item-2", markdown: "# Revised\nNew approach")
        #expect(first?.id == replay?.id)
        #expect(second?.version == 2)
        let plans = try await store.planArtefacts(sessionID: sessionID)
        #expect(plans.map(\.markdown) == ["# First\nKeep this", "# Revised\nNew approach"])
    }

    @Test("Handoff retains the selected revision across later refinements and reopening")
    func immutableSource() async throws {
        let path = TestScratch.unique("plan-handoff") + ".sqlite"
        let store = try Store(path: path)
        let origin = SessionID.new()
        let destination = SessionID.new()
        let recorded = try await store.recordPlan(sessionID: origin, sourceID: "plan-1", markdown: "# Original\nDo this")
        let plan = try #require(recorded)
        try await store.markPlanImplementation(planID: plan.id, sessionID: origin, implementationSessionID: destination)
        _ = try await store.recordPlan(sessionID: origin, sourceID: "plan-2", markdown: "# Different\nDo that")
        let reopened = try Store(path: path)
        let source = try #require(await reopened.sourcePlan(sessionID: destination))
        #expect(source.id == plan.id)
        #expect(source.sessionID == origin)
        #expect(source.markdown == "# Original\nDo this")
        #expect(source.implementationPrompt.contains("revision 1"))
    }

    @Test("Empty plan events do not create a version")
    func empty() async throws {
        let store = try makeTestStore("plan-empty")
        let sessionID = SessionID.new()
        let recorded = try await store.recordPlan(sessionID: sessionID, sourceID: "empty", markdown: " \n")
        #expect(recorded == nil)
        #expect(try await store.planArtefacts(sessionID: sessionID).isEmpty)
    }

    @Test("Queued, failed-start and uncertain plan deliveries do not claim implementation")
    func implementationRequiresProviderAcceptance() async throws {
        let store = try makeTestStore("plan-acceptance")
        let origin = try await store.upsert(Session(workspaceID: nil, agentKind: .codex))
        let destination = try await store.upsert(Session(workspaceID: nil, agentKind: .codex))
        let saved = try await store.recordPlan(sessionID: origin.id, sourceID: "proposal", markdown: "# Plan\nBuild this")
        let plan = try #require(saved)
        let delivery = Delivery(targetSessionID: destination.id, body: plan.implementationPrompt)
        _ = try await store.enqueueDelivery(delivery, clearingDraftMatching: nil, sourcePlan: plan)
        #expect(try await store.sourcePlan(sessionID: destination.id)?.id == plan.id)
        #expect(try await store.planArtefacts(sessionID: origin.id).first?.implementationSessionID == nil)

        let firstClaim = try await store.claimDelivery(id: delivery.id)
        #expect(firstClaim)
        try await store.releaseDeliveryClaim(id: delivery.id)
        #expect(try await store.planArtefacts(sessionID: origin.id).first?.implementationSessionID == nil)

        let retryClaim = try await store.claimDelivery(id: delivery.id)
        #expect(retryClaim)
        try await store.beginDeliveryDispatch(id: delivery.id)
        #expect(try await store.planArtefacts(sessionID: origin.id).first?.implementationSessionID == nil)
        try await store.acceptDelivery(id: delivery.id, providerTurnID: "accepted-turn")
        #expect(try await store.planArtefacts(sessionID: origin.id).first?.implementationSessionID == destination.id)
        #expect(try await store.sourcePlan(sessionID: destination.id)?.implementationSessionID == destination.id)
    }
}
