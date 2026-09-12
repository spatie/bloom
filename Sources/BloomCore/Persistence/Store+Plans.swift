import Foundation

public extension Store {
    func queuePlanSource(_ plan: PlanArtefact, delivery: Delivery) throws {
        var source = plan
        source.implementationSessionID = nil
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        try setSetting("delivery.\(delivery.id).sourcePlan", encoded)
        try setSetting(PlanArtefact.sourceKey(sessionID: delivery.targetSessionID), encoded)
    }

    func acceptPlanSource(delivery: Delivery) throws {
        guard let value = try setting("delivery.\(delivery.id).sourcePlan") else { return }
        let plan = try JSONDecoder().decode(PlanArtefact.self, from: Data(value.utf8))
        try markPlanImplementation(planID: plan.id, sessionID: plan.sessionID,
                                   implementationSessionID: delivery.targetSessionID)
    }

    func planArtefacts(sessionID: SessionID) throws -> [PlanArtefact] {
        guard let value = try setting(PlanArtefact.storageKey(sessionID: sessionID)) else { return [] }
        return try JSONDecoder().decode([PlanArtefact].self, from: Data(value.utf8))
    }

    /// No suspension between the read and write: two completed plans cannot overwrite one
    /// another, and replaying a completed provider item never creates another revision.
    @discardableResult
    func recordPlan(sessionID: SessionID, sourceID: String, markdown: String) throws -> PlanArtefact? {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var plans = try planArtefacts(sessionID: sessionID)
        if let existing = plans.last(where: { $0.sourceID == sourceID && $0.markdown == text }) { return existing }
        let plan = PlanArtefact(sessionID: sessionID, sourceID: sourceID,
                                version: (plans.last?.version ?? 0) + 1, markdown: text)
        plans.append(plan)
        try setSetting(PlanArtefact.storageKey(sessionID: sessionID),
                       String(decoding: JSONEncoder().encode(plans), as: UTF8.self))
        return plan
    }

    func markPlanImplementation(
        planID: PlanArtefactID, sessionID: SessionID, implementationSessionID: SessionID
    ) throws {
        var plans = try planArtefacts(sessionID: sessionID)
        guard let index = plans.firstIndex(where: { $0.id == planID }) else { return }
        plans[index].implementationSessionID = implementationSessionID
        try setSetting(PlanArtefact.storageKey(sessionID: sessionID),
                       String(decoding: JSONEncoder().encode(plans), as: UTF8.self))
        // A full immutable revision on the destination keeps the source readable even if the
        // original conversation is subsequently archived or removed.
        try setSetting(PlanArtefact.sourceKey(sessionID: implementationSessionID),
                       String(decoding: JSONEncoder().encode(plans[index]), as: UTF8.self))
    }

    func sourcePlan(sessionID: SessionID) throws -> PlanArtefact? {
        guard let value = try setting(PlanArtefact.sourceKey(sessionID: sessionID)) else { return nil }
        return try JSONDecoder().decode(PlanArtefact.self, from: Data(value.utf8))
    }
}
