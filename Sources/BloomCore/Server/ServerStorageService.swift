import BloomClient
import Foundation

/// Docker owns reachability and shared-layer deletion decisions. Bloom exposes only two
/// explicit cleanup categories, never a filesystem traversal or a general prune operation.
public actor ServerStorageService {
    typealias Disk = @Sendable (String) -> (total: Int64?, free: Int64?)
    private let directory: String
    private let docker: ServerStorageDocker
    private let disk: Disk
    private var cleaning = false
    /// Every workspace row, archived included, which is what leftovers are told apart by. Absent
    /// in a service built without a store, which then lists no leftovers rather than calling
    /// every workspace unknown.
    private let workspaces: (@Sendable () async throws -> [Workspace])?
    /// The same verified private engine, as archive and leftover removal reach it.
    nonisolated let workspaceDocker: WorkspaceDocker

    public init(directory: String, workspaces: (@Sendable () async throws -> [Workspace])? = nil) {
        self.directory = directory
        docker = ServerStorageDocker()
        disk = Self.diskUsage
        self.workspaces = workspaces
        workspaceDocker = WorkspaceDocker(storage: docker)
    }

    init(directory: String, docker: ServerStorageDocker, disk: @escaping Disk, workspaces: (@Sendable () async throws -> [Workspace])? = nil) {
        self.directory = directory; self.docker = docker; self.disk = disk
        self.workspaces = workspaces
        workspaceDocker = WorkspaceDocker(storage: docker)
    }

    public func inspect() async -> ServerStorageReport {
        let space = disk(directory)
        do {
            let docker = self.docker
            let values = try await RemoteReadDeadline.run(timeout: .seconds(30)) { try await docker.usage() }
            let usage = values.map {
                ServerStorageUsage(kind: $0.kind, totalCount: $0.totalCount, activeCount: $0.activeCount,
                    sizeLabel: $0.size, reclaimableLabel: $0.reclaimable)
            }
            let leftovers = await listLeftovers()
            return ServerStorageReport(checkedAt: Date(), totalBytes: space.total, freeBytes: space.free,
                dockerState: .ready, dockerMessage: nil, usage: usage, notes: Self.notes,
                leftovers: leftovers.value, leftoversMessage: leftovers.message)
        } catch {
            let failure = error as? ServerStorageDocker.Failure
            let unavailable = failure == .unsupported || failure == .missing || failure == .unsafe
            return ServerStorageReport(checkedAt: Date(), totalBytes: space.total, freeBytes: space.free,
                dockerState: unavailable ? .unavailable : .failed,
                dockerMessage: failure?.localizedDescription ?? "Docker storage could not be measured. Check the connection and refresh.",
                usage: [], notes: Self.notes)
        }
    }

    public func clean(_ targets: [ServerStorageCleanupTarget]) async throws -> ServerStorageCleanupResult {
        guard !targets.isEmpty, targets.count <= 2, Set(targets).count == targets.count else {
            throw ServerFailure("Choose each storage cleanup category at most once.")
        }
        guard !cleaning else { throw ServerFailure("Storage cleanup is already running. Wait for it to finish, then refresh.") }
        cleaning = true
        defer { cleaning = false }
        // Leave at most thirty seconds for the final report inside the client's cleanup budget.
        let deadline = ProcessInfo.processInfo.systemUptime + 240
        var outcomes: [ServerStorageCleanupOutcome] = []
        var interrupted = false
        for target in targets {
            var launched = false
            do {
                try Task.checkCancellation()
                let validationTime = min(10, deadline - ProcessInfo.processInfo.systemUptime)
                guard validationTime > 0 else { throw ServerStorageDocker.Failure.unavailable }
                let docker = self.docker
                try await RemoteReadDeadline.run(timeout: .seconds(validationTime)) { try await docker.validate() }
                try Task.checkCancellation()
                let operationTime = min(120, deadline - ProcessInfo.processInfo.systemUptime)
                guard operationTime > 0 else { throw ServerStorageDocker.Failure.unavailable }
                launched = true
                let output = try await docker.run(docker.engineArguments(Self.arguments(target)), docker.configuration.environment, operationTime, 262_144)
                try Task.checkCancellation()
                guard output.status == 0 else {
                    let detail = ServerSetupDiagnostics.optional(output.text, limit: 2_048)
                    outcomes.append(.init(target: target, status: .uncertain,
                        message: "Docker cleanup exited with status \(output.status). Some cleanup may already have completed. Refresh storage before retrying."
                            + (detail.map { "\n" + $0 } ?? ""), reclaimedLabel: nil))
                    interrupted = true
                    break
                }
                outcomes.append(.init(target: target, status: .completed,
                    message: target == .buildCache ? "Unused build cache was removed. Future builds may take longer." :
                        "Unused images were removed. Future workspaces may need to download or rebuild them.",
                    reclaimedLabel: ServerStorageDocker.reclaimed(output.text)))
            } catch {
                let failure = error as? ServerStorageDocker.Failure
                let message = launched ? "Cleanup could not be confirmed. Docker may have removed some data and may still be finishing. Refresh storage before retrying." :
                    failure?.localizedDescription ?? "Cleanup did not start for this category. Check the connection and refresh storage."
                outcomes.append(.init(target: target, status: launched ? .uncertain : .failed, message: message, reclaimedLabel: nil))
                interrupted = true
                break
            }
        }
        // A cancelled call must not spawn a second process to obtain a prettier final report.
        // Completed category outcomes remain truthful even if a later one was interrupted.
        let report = Task.isCancelled || interrupted ? nil : await inspect()
        return ServerStorageCleanupResult(outcomes: outcomes, report: report, interrupted: interrupted)
    }

    /// Removes the leftovers of each workspace named, from a listing taken now.
    ///
    /// The client sends workspace ids and never resource names, and the list is taken again here
    /// rather than trusted from the report it was reviewed on: a workspace restored since then is
    /// active again and has to lose nothing, and a name remembered from a minute ago can belong to
    /// a container created since.
    public func removeLeftovers(_ ids: [WorkspaceID]) async throws -> ServerStorageLeftoverRemoval {
        guard !ids.isEmpty, ids.count <= 500, Set(ids).count == ids.count else {
            throw ServerFailure("Choose each workspace\u{2019}s leftovers at most once.")
        }
        guard let workspaces else { throw ServerFailure("This server cannot list leftover containers and volumes.") }
        guard !cleaning else { throw ServerFailure("Storage cleanup is already running. Wait for it to finish, then refresh.") }
        cleaning = true
        defer { cleaning = false }
        let docker = workspaceDocker
        let current: [ServerStorageLeftover]
        do {
            let entries = try await RemoteReadDeadline.run(timeout: .seconds(60)) { try await docker.inventory() }
            current = ServerStorageLeftovers.classify(entries, workspaces: try await workspaces())
        } catch {
            throw ServerFailure("Leftover containers and volumes could not be listed, so nothing was removed. Refresh storage and try again.")
        }
        var outcomes: [ServerStorageLeftoverOutcome] = []
        for id in ids {
            guard !Task.isCancelled else { break }
            guard let leftover = current.first(where: { $0.workspaceID == id }) else {
                outcomes.append(.init(workspaceID: id, status: .failed,
                    message: "Nothing was removed. The workspace is active again, or its containers and volumes are already gone."))
                continue
            }
            do {
                try await docker.remove(leftover.resources)
                outcomes.append(.init(workspaceID: id, status: .completed,
                    message: "Removed " + WorkspaceDockerResource.summary(leftover.resources) + "."))
            } catch {
                outcomes.append(.init(workspaceID: id, status: .uncertain,
                    message: error.localizedDescription + " Some of them may already be gone. Refresh storage before retrying."))
            }
        }
        let report = Task.isCancelled ? nil : await inspect()
        return ServerStorageLeftoverRemoval(outcomes: outcomes, report: report)
    }

    /// `nil` with no message when this service has no workspace list, and `nil` with a message
    /// when the listing failed, so the panel can say which.
    private func listLeftovers() async -> (value: [ServerStorageLeftover]?, message: String?) {
        guard let workspaces else { return (nil, nil) }
        do {
            let docker = workspaceDocker
            let entries = try await RemoteReadDeadline.run(timeout: .seconds(60)) { try await docker.inventory(measuringSizes: true) }
            return (ServerStorageLeftovers.classify(entries, workspaces: try await workspaces()), nil)
        } catch {
            return (nil, "Leftover containers and volumes could not be listed. Refresh to try again.")
        }
    }

    static func arguments(_ target: ServerStorageCleanupTarget) -> [String] {
        switch target {
        case .buildCache: ["builder", "prune", "--all", "--force"]
        case .unusedImages: ["image", "prune", "--all", "--force"]
        }
    }

    /// Free space on the filesystem holding Bloom's data, where the private Docker data root lives.
    nonisolated func diskSpace() -> (total: Int64?, free: Int64?) { disk(directory) }

    /// One background prune for `ServerDockerHousekeeper`, through the same verified private engine
    /// as a manual cleanup. It holds the cleanup flag so the two never run over each other, and it
    /// answers false instead of throwing because nobody is waiting on it.
    func housekeepingPrune(_ prune: ServerDockerHousekeeping.Prune) async -> Bool {
        guard !cleaning else { return false }
        cleaning = true
        defer { cleaning = false }
        do {
            let docker = self.docker
            try await RemoteReadDeadline.run(timeout: .seconds(10)) { try await docker.validate() }
            let output = try await docker.run(docker.engineArguments(prune.arguments), docker.configuration.environment, 120, 262_144)
            return output.status == 0
        } catch {
            return false
        }
    }

    private static let notes = [
        "Docker reports rounded sizes. Image and build-cache layers can overlap, so these categories must not be added together.",
        "Reclaimable build cache is an estimate. Space recovered depends on shared layers and work running during cleanup.",
        "Cleanup keeps containers, volumes, workspaces, uploads, account credentials and swap. Images referenced by running or stopped containers are retained.",
    ]

    private static func diskUsage(_ directory: String) -> (total: Int64?, free: Int64?) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory),
              let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
              total > 0, (0...total).contains(free) else { return (nil, nil) }
        return (total, free)
    }
}
