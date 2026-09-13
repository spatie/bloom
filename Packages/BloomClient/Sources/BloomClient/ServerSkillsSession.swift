import Foundation
import Observation

/// One server's skill inventory and reviewed mutations, shared by every native client.
/// Reconnect only to the same server. A different server needs a new session.
@MainActor @Observable
public final class ServerSkillsSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Activity: Sendable { case idle, loading, preparing, applying, changing }
    public private(set) var activity: Activity = .idle
    public private(set) var skills: [ServerSkill] = []
    public private(set) var plan: ServerSkillsPlan?
    public private(set) var warnings: [String] = []
    public private(set) var error: String?
    public private(set) var supported: Bool?
    public private(set) var pendingMutationID: UUID?
    public private(set) var content: String?
    public private(set) var contentSkillID: String?
    public private(set) var contentPlanID: String?
    public private(set) var detailSkill: ServerSkill?
    public var unsupported: Bool { supported == false }
    public var canMutate: Bool { supported == true && activity == .idle && pendingMutationID == nil }

    @ObservationIgnored private var client: any RemoteRequesting
    @ObservationIgnored private let workspaceID: WorkspaceID?
    @ObservationIgnored private var pending: (request: ServerSkillsRequest, command: RemoteCommand)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var detailReadGeneration: Int?
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    public init(client: any RemoteRequesting, workspaceID: WorkspaceID? = nil) {
        self.client = client; self.workspaceID = workspaceID
    }

    nonisolated public var description: String { "Server skills session" }
    nonisolated public var debugDescription: String { description }
    nonisolated public var customMirror: Mirror { Mirror(self, children: [:]) }

    public func observe(_ changed: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = changed; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
    private func notify() { for changed in Array(observers.values) { changed() } }

    /// A transport replacement never submits pending work. Its original command stays available
    /// for an explicit retry, including its UUID and the exact reviewed names and agent selection.
    public func reconnect(client: any RemoteRequesting) {
        generation += 1; self.client = client; supported = nil; activity = .idle
        error = nil; notify()
    }

    @discardableResult public func refresh() async -> Bool {
        await perform(.init(action: .inspect, workspaceID: workspaceID))
    }

    @discardableResult public func previewGit(repositoryURL: String, ref: String? = nil, collectionID: String? = nil) async -> Bool {
        guard readyForMutation() else { return false }
        plan = nil
        return await perform(.init(action: .previewGit, repositoryURL: repositoryURL, ref: ref, collectionID: collectionID))
    }

    @discardableResult public func previewImport(files: [ServerSkillFile]) async -> Bool {
        guard readyForMutation() else { return false }
        plan = nil
        return await perform(.init(action: .previewImport, files: files))
    }

    @discardableResult public func apply(planID: String, selectedSkillNames: [String], agents: [ServerSkillAgent]) async -> Bool {
        guard readyForMutation() else { return false }
        guard let plan, plan.id == planID, plan.expiresAt > Date() else {
            return fail("This skill preview has expired or changed. Review the source again before installing.")
        }
        guard !selectedSkillNames.isEmpty, Set(selectedSkillNames).isSubset(of: Set(plan.skills.map(\.name))) else {
            return fail("Choose at least one skill from this preview.")
        }
        return await perform(.init(action: .apply, workspaceID: workspaceID, planID: planID, selectedSkillNames: selectedSkillNames, agents: agents))
    }

    @discardableResult public func setEnabled(skillID: String, revision: String, agents: [ServerSkillAgent]) async -> Bool {
        guard readyForMutation(), validates(skillID: skillID, revision: revision) else { return false }
        return await perform(.init(action: .setEnabled, workspaceID: workspaceID, skillID: skillID, revision: revision, agents: agents))
    }

    @discardableResult public func remove(skillID: String, revision: String) async -> Bool {
        guard readyForMutation(), validates(skillID: skillID, revision: revision) else { return false }
        return await perform(.init(action: .remove, workspaceID: workspaceID, skillID: skillID, revision: revision))
    }

    @discardableResult public func readDetails(skillID: String, planID: String? = nil) async -> Bool {
        if activity != .idle {
            guard detailReadGeneration == generation else { return false }
            generation += 1; activity = .idle
        }
        let readGeneration = generation
        detailReadGeneration = readGeneration
        defer { if detailReadGeneration == readGeneration { detailReadGeneration = nil } }
        content = nil; detailSkill = nil; contentSkillID = skillID; contentPlanID = planID
        return await perform(.init(action: .read, workspaceID: workspaceID, planID: planID, skillID: skillID))
    }

    public func discardPlan() {
        guard activity == .idle, pendingMutationID == nil else { return }
        plan = nil; notify()
    }

    @discardableResult public func retryPendingMutation() async -> Bool {
        guard activity == .idle, let pending else { return false }
        return await perform(pending.request, retry: pending.command)
    }

    private func readyForMutation() -> Bool {
        guard activity == .idle else { return false }
        guard pendingMutationID == nil else {
            return fail("The previous request is not confirmed. Retry that request before making another change.")
        }
        return true
    }

    private func validates(skillID: String, revision: String) -> Bool {
        guard let skill = skills.first(where: { $0.id == skillID }), skill.isManaged else {
            return fail("This skill is not managed by Bloom. Change it in its original location.")
        }
        guard skill.revision == revision else { return fail("This skill changed. Refresh and review it before making another change.") }
        return true
    }

    private func fail(_ message: String) -> Bool { error = message; notify(); return false }

    private func perform(_ request: ServerSkillsRequest, retry: RemoteCommand? = nil) async -> Bool {
        guard activity == .idle else { return false }
        let generation = generation, client = client
        let mutation = request.action != .inspect && request.action != .read
        switch request.action {
        case .inspect, .read: activity = .loading
        case .previewGit, .previewImport: activity = .preparing
        case .apply: activity = .applying
        case .setEnabled, .remove: activity = .changing
        }
        error = nil; notify()
        defer { if generation == self.generation { activity = .idle; notify() } }
        var submitted = false
        do {
            if supported == nil {
                let diagnostics = try await client.request(.call("diagnostics"))
                guard generation == self.generation else { return false }
                supported = try ServerDiagnostics.decode(diagnostics).skillManagement == true
            }
            guard supported == true else { return fail("Update Bloom Server to manage skills from this device.") }
            try Task.checkCancellation()
            let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
            let command = retry ?? .call("skills", ["_0": payload])
            if mutation { pending = (request, command); pendingMutationID = command.id }
            submitted = true
            let result = try await client.request(command)
            guard generation == self.generation else { return false }
            guard let value = result["skills"]?["_0"] else { throw ConnectionFailure("The server did not return its skill response.") }
            let response = try JSONDecoder().decode(ServerSkillsResponse.self, from: JSONEncoder().encode(value))
            switch request.action {
            case .inspect, .apply, .setEnabled, .remove:
                skills = response.skills
                warnings = response.warnings
                if request.action == .apply { plan = nil }
            case .previewGit, .previewImport:
                guard let plan = response.plan else { throw ConnectionFailure("The server did not return a skill preview.") }
                self.plan = plan
            case .read:
                guard let content = response.content else { throw ConnectionFailure("The server did not return the skill instructions.") }
                self.content = content
                detailSkill = response.skills.first { $0.id == request.skillID }
            }
            if mutation { pending = nil; pendingMutationID = nil }
            return true
        } catch {
            guard generation == self.generation else { return false }
            if mutation, error is ConnectionRefusal { pending = nil; pendingMutationID = nil }
            if mutation, submitted, pendingMutationID != nil {
                return fail("The request is not confirmed. The server may have completed it. Retry uses the same request.\n\n" + error.localizedDescription)
            }
            if error is CancellationError { return false }
            return fail(error.localizedDescription)
        }
    }
}
