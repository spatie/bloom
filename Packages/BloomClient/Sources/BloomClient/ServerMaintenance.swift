import Foundation

public enum ServerMaintenanceAction: String, Codable, Sendable { case inspect, prepare, start, status, cancel }
public enum ServerMaintenanceComponentID: String, Codable, Sendable, CaseIterable {
    case server, claude, codex, docker
    public var title: String {
        switch self {
        case .server: "Bloom Server"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .docker: "Docker"
        }
    }
}
public enum ServerMaintenanceMode: String, Codable, Sendable, CaseIterable { case now, whenIdle }

/// The credential is transport-only. Never persist this value in a command outbox or diagnostic.
public struct ServerMaintenanceRequest: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var action: ServerMaintenanceAction
    public var credential: String?
    public var component: ServerMaintenanceComponentID?
    public var planID: String?
    public var jobID: String?
    public var mode: ServerMaintenanceMode?
    public var afterSequence: Int?

    public init(action: ServerMaintenanceAction, credential: String? = nil, component: ServerMaintenanceComponentID? = nil,
                planID: String? = nil, jobID: String? = nil, mode: ServerMaintenanceMode? = nil, afterSequence: Int? = nil) {
        self.action = action; self.credential = credential; self.component = component
        self.planID = planID; self.jobID = jobID; self.mode = mode; self.afterSequence = afterSequence
    }

    public var description: String { "Server maintenance request (\(action.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["action": action.rawValue]) }

    public func command(id: UUID = UUID()) throws -> RemoteCommand {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
        return RemoteCommand(.object(["maintenance": .object(["_0": value])]), id: id)
    }
}

public struct ServerMaintenanceComponent: Codable, Sendable, Equatable, Identifiable {
    public var id: ServerMaintenanceComponentID
    public var title: String
    public var installedVersion: String?
    public var availableVersion: String?
    public var canUpdate: Bool
    public var detail: String

    public init(id: ServerMaintenanceComponentID, title: String, installedVersion: String? = nil,
                availableVersion: String? = nil, canUpdate: Bool, detail: String) {
        self.id = id; self.title = title; self.installedVersion = installedVersion
        self.availableVersion = availableVersion; self.canUpdate = canUpdate; self.detail = detail
    }
}

public struct ServerMaintenancePlan: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var component: ServerMaintenanceComponentID
    public var fromVersion: String?
    public var targetVersion: String
    public var summary: String
    public var restarts: [String]
    public var expiresAt: String

    public init(id: String, component: ServerMaintenanceComponentID, fromVersion: String? = nil,
                targetVersion: String, summary: String, restarts: [String], expiresAt: String) {
        self.id = id; self.component = component; self.fromVersion = fromVersion
        self.targetVersion = targetVersion; self.summary = summary; self.restarts = restarts; self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        let ordinary = formatter.date(from: expiresAt)
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let expiry = ordinary ?? formatter.date(from: expiresAt) else { return true }
        return expiry <= date
    }
}

public enum ServerMaintenancePhase: String, Codable, Sendable, CaseIterable {
    case queued, waiting, downloading, installing, restarting, verifying
    case succeeded, failed, rolledBack, cancelled, interrupted

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .rolledBack, .cancelled, .interrupted: true
        default: false
        }
    }

    public var needsAttention: Bool { self == .failed || self == .rolledBack || self == .interrupted }
    public var title: String {
        switch self {
        case .queued: "Queued"
        case .waiting: "Waiting for server to be idle"
        case .downloading: "Downloading"
        case .installing: "Installing"
        case .restarting: "Restarting"
        case .verifying: "Verifying"
        case .succeeded: "Updated"
        case .failed: "Update failed"
        case .rolledBack: "Previous version restored"
        case .cancelled: "Cancelled"
        case .interrupted: "Update interrupted"
        }
    }
}

public struct ServerMaintenanceLog: Codable, Sendable, Equatable, Identifiable {
    public var sequence: Int
    public var message: String
    public var id: Int { sequence }
    public init(sequence: Int, message: String) { self.sequence = sequence; self.message = message }
}

public struct ServerMaintenanceJob: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var planID: String
    public var component: ServerMaintenanceComponentID
    public var targetVersion: String
    public var phase: ServerMaintenancePhase
    public var logs: [ServerMaintenanceLog]
    /// Opaque per-job cursor. Echo it as `afterSequence` when requesting newer log entries.
    public var nextSequence: Int
    public var canCancel: Bool
    public var message: String?
    public var updatedAt: String
    public var isActive: Bool { !phase.isTerminal }

    public init(id: String, planID: String, component: ServerMaintenanceComponentID, targetVersion: String,
                phase: ServerMaintenancePhase, logs: [ServerMaintenanceLog] = [], nextSequence: Int = 0,
                canCancel: Bool, message: String? = nil, updatedAt: String) {
        self.id = id; self.planID = planID; self.component = component; self.targetVersion = targetVersion
        self.phase = phase; self.logs = logs; self.nextSequence = nextSequence
        self.canCancel = canCancel; self.message = message; self.updatedAt = updatedAt
    }
}

public struct ServerMaintenanceFailure: Codable, Sendable, Equatable, Error, LocalizedError {
    public var code: String
    public var message: String
    public var recovery: String
    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recovery }
    public var isAuthorizationFailure: Bool { code == "unauthorized" }
    public init(code: String, message: String, recovery: String) {
        self.code = code; self.message = message; self.recovery = recovery
    }
}

public struct ServerMaintenanceResponse: Codable, Sendable, Equatable {
    public var authorized: Bool
    public var components: [ServerMaintenanceComponent]
    public var plan: ServerMaintenancePlan?
    public var jobs: [ServerMaintenanceJob]
    public var error: ServerMaintenanceFailure?

    public init(authorized: Bool, components: [ServerMaintenanceComponent] = [], plan: ServerMaintenancePlan? = nil,
                jobs: [ServerMaintenanceJob] = [], error: ServerMaintenanceFailure? = nil) {
        self.authorized = authorized; self.components = components; self.plan = plan; self.jobs = jobs; self.error = error
    }

    public static func decode(_ value: JSONValue) throws -> Self {
        guard let payload = value["maintenance"]?["_0"] else {
            throw ServerMaintenanceFailure(code: "invalid_response", message: "The server did not return maintenance details.",
                recovery: "Check the server version and reconnect before trying again.")
        }
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(payload))
    }
}
