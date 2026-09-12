import Foundation
import Observation

/// Views review plans and observe durable server jobs. Losing a view or a response never cancels
/// a job or silently resubmits a mutation. Create a new session when the server identity changes.
@MainActor @Observable
public final class ServerMaintenanceSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Activity: Sendable { case idle, checking, preparing, submitting, polling }
    public private(set) var activity: Activity = .idle
    public private(set) var components: [ServerMaintenanceComponent] = []
    public private(set) var plan: ServerMaintenancePlan?
    public private(set) var jobs: [ServerMaintenanceJob] = []
    public private(set) var authorized = false
    public private(set) var failure: ServerMaintenanceFailure?
    public private(set) var capability: Bool?
    public private(set) var pendingMutationID: UUID?
    public var unsupported: Bool { capability == false }
    public var isLoading: Bool { activity == .checking || activity == .polling }
    public var isPreparing: Bool { activity == .preparing }
    public var isSubmitting: Bool { activity == .submitting }
    public var canStart: Bool {
        authorized && capability == true && activity == .idle && pendingMutationID == nil
            && plan?.isExpired() == false
    }
    public var hasActiveJobs: Bool { jobs.contains(where: \.isActive) }

    @ObservationIgnored private let client: any RemoteRequesting
    @ObservationIgnored private var credential: String?
    @ObservationIgnored private var pending: ServerMaintenanceRequest?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    public init(client: any RemoteRequesting, supported: Bool? = nil) {
        self.client = client; capability = supported
    }

    nonisolated public var description: String { "Server maintenance session" }
    nonisolated public var debugDescription: String { description }
    nonisolated public var customMirror: Mirror { Mirror(self, children: [:]) }

    public func observe(_ changed: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = changed; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
    private func notify() { for changed in Array(observers.values) { changed() } }

    /// The UI owns Keychain persistence. Nil keeps an already-unlocked credential in memory.
    public func refresh(credential: String? = nil) async {
        guard activity == .idle else { return }
        if let credential { self.credential = credential.isEmpty ? nil : credential }
        await read(action: .inspect, jobID: nil)
    }

    public func poll(jobID: String? = nil) async {
        guard activity == .idle, authorized else { return }
        await read(action: .status, jobID: jobID)
    }

    public func prepare(component: ServerMaintenanceComponentID) async {
        guard activity == .idle, authorized, capability == true, pendingMutationID == nil else { return }
        guard components.contains(where: { $0.id == component && $0.canUpdate }) else { return }
        plan = nil
        await mutate(ServerMaintenanceRequest(action: .prepare, component: component))
    }

    public func start(mode: ServerMaintenanceMode = .now) async {
        guard canStart, let plan else { return }
        await mutate(ServerMaintenanceRequest(action: .start, planID: plan.id, mode: mode))
    }

    public func cancel(jobID: String) async {
        guard activity == .idle, authorized, pendingMutationID == nil,
              jobs.contains(where: { $0.id == jobID && $0.canCancel && $0.isActive }) else { return }
        await mutate(ServerMaintenanceRequest(action: .cancel, jobID: jobID))
    }

    public func canRecover(jobID: String) -> Bool {
        activity == .idle && authorized && capability == true && pendingMutationID == nil
            && jobs.contains(where: { $0.id == jobID && $0.phase == .interrupted })
    }

    /// Recovery resumes the server's saved checkpoint. It never requests another installation.
    public func recover(jobID: String) async {
        guard canRecover(jobID: jobID) else { return }
        await mutate(ServerMaintenanceRequest(action: .recover, jobID: jobID))
    }

    /// Only an explicit user retry can reuse a mutation. Its action, plan, mode and UUID stay fixed.
    public func retryPendingMutation() async {
        guard activity == .idle, authorized, let pending, let id = pendingMutationID else { return }
        await mutate(pending, id: id)
    }

    public func discardPlan() {
        guard activity == .idle, pendingMutationID == nil else { return }
        plan = nil; notify()
    }

    /// Locking the local panel does not stop any job on the server. Pending intent contains no secret.
    public func clearCredential() {
        generation += 1; credential = nil; authorized = false; plan = nil; jobs = []
        failure = nil; notify()
    }

    private func read(action: ServerMaintenanceAction, jobID: String?) async {
        let generation = generation
        activity = action == .inspect ? .checking : .polling; failure = nil; notify()
        defer { activity = .idle; notify() }
        do {
            try await requireCapability()
            guard generation == self.generation else { return }
            let cursor = jobID.flatMap { id in jobs.first(where: { $0.id == id })?.nextSequence }
            let request = ServerMaintenanceRequest(action: action, credential: credential, jobID: jobID, afterSequence: cursor)
            let value = try await client.request(request.command())
            try Task.checkCancellation()
            guard generation == self.generation else { return }
            let response = try sanitised(ServerMaintenanceResponse.decode(value))
            accept(response, replacesComponents: action == .inspect)
            reconcilePending()
        } catch is CancellationError {
            // Cancelling a read belongs to the view. It says nothing about a durable server job.
        } catch {
            guard generation == self.generation else { return }
            failure = localFailure(error, uncertain: false)
        }
    }

    private func mutate(_ intent: ServerMaintenanceRequest, id: UUID = UUID()) async {
        let generation = generation
        var request = intent
        request.credential = credential
        pending = intent; pending?.credential = nil; pendingMutationID = id
        activity = intent.action == .prepare ? .preparing : .submitting; failure = nil; notify()
        defer { activity = .idle; notify() }
        do {
            let value = try await client.request(request.command(id: id))
            guard generation == self.generation else { return }
            let response = try sanitised(ServerMaintenanceResponse.decode(value))
            accept(response, replacesComponents: false)
            if response.authorized, response.error == nil {
                if intent.action == .prepare {
                    guard let prepared = response.plan, prepared.component == intent.component else {
                        throw ServerMaintenanceFailure(code: "invalid_response", message: "The server did not return the requested update plan.",
                            recovery: "Refresh maintenance before reviewing the update again.")
                    }
                    plan = prepared
                } else if intent.action == .start {
                    guard response.jobs.contains(where: { $0.planID == intent.planID }) else {
                        throw ServerMaintenanceFailure(code: "unconfirmed", message: "The update has not been confirmed.",
                            recovery: "Refresh to recover its job before retrying the saved request.")
                    }
                    plan = nil
                } else if intent.action == .recover {
                    guard response.jobs.contains(where: { $0.id == intent.jobID }) else {
                        throw ServerMaintenanceFailure(code: "unconfirmed", message: "Recovery has not been confirmed.",
                            recovery: "Refresh this update before retrying the saved recovery request.")
                    }
                }
            }
            pending = nil; pendingMutationID = nil
        } catch {
            guard generation == self.generation else { return }
            failure = localFailure(error, uncertain: true)
        }
    }

    private func requireCapability() async throws {
        if capability == nil {
            let value = try await client.request(.call("diagnostics"))
            try Task.checkCancellation()
            guard value["diagnostics"]?["_0"] != nil else {
                throw ServerMaintenanceFailure(code: "invalid_response", message: "Could not check the server’s maintenance support.",
                    recovery: "Reconnect and refresh maintenance.")
            }
            capability = value["diagnostics"]?["_0"]?["maintenanceManagement"] == .bool(true)
        }
        guard capability == true else {
            throw ServerMaintenanceFailure(code: "unsupported", message: "This server does not support supervised maintenance yet.",
                recovery: "Update Bloom Server using its installer before managing updates here.")
        }
    }

    private func accept(_ response: ServerMaintenanceResponse, replacesComponents: Bool) {
        authorized = response.authorized; failure = response.error
        if replacesComponents || !response.components.isEmpty { components = response.components }
        guard response.authorized else { plan = nil; jobs = []; return }
        for incoming in response.jobs {
            var value = incoming
            if let index = jobs.firstIndex(where: { $0.id == incoming.id }) {
                var logs = Dictionary(jobs[index].logs.map { ($0.sequence, $0) }, uniquingKeysWith: { _, latest in latest })
                for log in incoming.logs { logs[log.sequence] = log }
                value.logs = logs.values.sorted { $0.sequence < $1.sequence }
                value.nextSequence = max(jobs[index].nextSequence, incoming.nextSequence)
                jobs[index] = value
            } else { jobs.append(value) }
        }
        jobs.sort { $0.updatedAt > $1.updatedAt }
    }

    private func reconcilePending() {
        guard let pending else { return }
        if pending.action == .start, jobs.contains(where: { $0.planID == pending.planID }) {
            self.pending = nil; pendingMutationID = nil; plan = nil
        } else if pending.action == .recover, jobs.contains(where: { $0.id == pending.jobID && $0.phase.isTerminal && $0.phase != .interrupted }) {
            self.pending = nil; pendingMutationID = nil
        } else if pending.action == .cancel, jobs.contains(where: { $0.id == pending.jobID && $0.phase.isTerminal }) {
            self.pending = nil; pendingMutationID = nil
        }
    }

    private func localFailure(_ error: Error, uncertain: Bool) -> ServerMaintenanceFailure {
        if let failure = error as? ServerMaintenanceFailure {
            return ServerMaintenanceFailure(code: failure.code, message: redact(failure.message), recovery: redact(failure.recovery))
        }
        return ServerMaintenanceFailure(code: uncertain ? "unconfirmed" : "connection_failed",
            message: redact(error is CancellationError ? "The maintenance response was interrupted." : error.localizedDescription),
            recovery: uncertain ? "The server may already be working. Refresh its jobs first. A manual retry reuses the same request." : "Check the connection and refresh. Running updates remain on the server.")
    }

    private func redact(_ value: String) -> String {
        guard let credential, !credential.isEmpty else { return value }
        return value.replacingOccurrences(of: credential, with: "[redacted]")
    }

    private func sanitised(_ response: ServerMaintenanceResponse) -> ServerMaintenanceResponse {
        var value = response
        value.components = value.components.map { component in
            var component = component
            component.title = redact(component.title); component.detail = redact(component.detail)
            component.installedVersion = component.installedVersion.map(redact)
            component.availableVersion = component.availableVersion.map(redact)
            return component
        }
        if var plan = value.plan {
            plan.summary = redact(plan.summary); plan.restarts = plan.restarts.map(redact)
            plan.fromVersion = plan.fromVersion.map(redact); plan.targetVersion = redact(plan.targetVersion)
            value.plan = plan
        }
        value.jobs = value.jobs.map { job in
            var job = job
            job.message = job.message.map(redact); job.targetVersion = redact(job.targetVersion)
            job.logs = job.logs.map { ServerMaintenanceLog(sequence: $0.sequence, message: redact($0.message)) }
            return job
        }
        if let failure = value.error { value.error = localFailure(failure, uncertain: false) }
        return value
    }
}
