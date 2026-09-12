import Foundation

/// Host capacity and Docker's own rounded usage labels. Categories share layers and must not be summed.
public struct ServerStorageReport: Codable, Sendable, Equatable {
    public var checkedAt: Date
    public var totalBytes: Int64?
    public var freeBytes: Int64?
    public var dockerState: ServerStorageDockerState
    public var dockerMessage: String?
    public var usage: [ServerStorageUsage]
    public var notes: [String]

    public init(checkedAt: Date = Date(), totalBytes: Int64? = nil, freeBytes: Int64? = nil,
                dockerState: ServerStorageDockerState, dockerMessage: String? = nil,
                usage: [ServerStorageUsage] = [], notes: [String] = []) {
        self.checkedAt = checkedAt; self.totalBytes = totalBytes; self.freeBytes = freeBytes
        self.dockerState = dockerState; self.dockerMessage = dockerMessage
        self.usage = usage; self.notes = notes
    }
}

public enum ServerStorageDockerState: String, Codable, Sendable { case ready, unavailable, failed }

public struct ServerStorageUsage: Codable, Sendable, Equatable {
    public var kind: String
    public var totalCount: Int?
    public var activeCount: Int?
    public var sizeLabel: String
    public var reclaimableLabel: String?

    public init(kind: String, totalCount: Int? = nil, activeCount: Int? = nil, sizeLabel: String, reclaimableLabel: String? = nil) {
        self.kind = kind; self.totalCount = totalCount; self.activeCount = activeCount
        self.sizeLabel = sizeLabel; self.reclaimableLabel = reclaimableLabel
    }
}

public enum ServerStorageCleanupTarget: String, Codable, Sendable, CaseIterable, Hashable {
    case buildCache, unusedImages

    public var title: String {
        switch self {
        case .buildCache: "Build cache"
        case .unusedImages: "Unused images"
        }
    }

    public var detail: String {
        switch self {
        case .buildCache: "Remove unused Docker build cache. Later builds may take longer."
        case .unusedImages: "Remove Docker images not used by any container. They may need to be downloaded or rebuilt."
        }
    }
}

public enum ServerStorageCleanupStatus: String, Codable, Sendable { case completed, uncertain, failed }

public struct ServerStorageCleanupOutcome: Codable, Sendable, Equatable {
    public var target: ServerStorageCleanupTarget
    public var status: ServerStorageCleanupStatus
    public var message: String
    public var reclaimedLabel: String?

    public init(target: ServerStorageCleanupTarget, status: ServerStorageCleanupStatus, message: String, reclaimedLabel: String? = nil) {
        self.target = target; self.status = status; self.message = message; self.reclaimedLabel = reclaimedLabel
    }
}

public struct ServerStorageCleanupResult: Codable, Sendable, Equatable {
    public var outcomes: [ServerStorageCleanupOutcome]
    public var report: ServerStorageReport?
    public var interrupted: Bool
    public var needsAttention: Bool { interrupted || outcomes.contains { $0.status != .completed } }

    public init(outcomes: [ServerStorageCleanupOutcome], report: ServerStorageReport? = nil, interrupted: Bool = false) {
        self.outcomes = outcomes; self.report = report; self.interrupted = interrupted
    }
}
