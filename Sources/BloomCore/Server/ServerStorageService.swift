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

    public init(directory: String) {
        self.directory = directory
        docker = ServerStorageDocker()
        disk = Self.diskUsage
    }

    init(directory: String, docker: ServerStorageDocker, disk: @escaping Disk) {
        self.directory = directory; self.docker = docker; self.disk = disk
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
            return ServerStorageReport(checkedAt: Date(), totalBytes: space.total, freeBytes: space.free,
                dockerState: .ready, dockerMessage: nil, usage: usage, notes: Self.notes)
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

    static func arguments(_ target: ServerStorageCleanupTarget) -> [String] {
        switch target {
        case .buildCache: ["builder", "prune", "--all", "--force"]
        case .unusedImages: ["image", "prune", "--all", "--force"]
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
