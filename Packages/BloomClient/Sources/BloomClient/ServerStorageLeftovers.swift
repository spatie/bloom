import Foundation

/// Docker resources left behind by one workspace that is no longer active.
///
/// Grouped by workspace rather than listed resource by resource, because that is the unit that
/// can be removed sensibly: a database volume taken without its container leaves a container that
/// fails on its next start, and a container taken without its volume leaves the data behind.
public struct ServerStorageLeftover: Codable, Sendable, Hashable, Identifiable {
    public enum Owner: String, Codable, Sendable {
        /// The workspace is archived on this server.
        case archived
        /// No workspace with this id exists on this server any more.
        case unknown
    }

    public var workspaceID: WorkspaceID
    public var workspaceName: String?
    public var owner: Owner
    public var resources: [WorkspaceDockerResource]

    public var id: WorkspaceID { workspaceID }

    public init(workspaceID: WorkspaceID, workspaceName: String? = nil, owner: Owner, resources: [WorkspaceDockerResource]) {
        self.workspaceID = workspaceID; self.workspaceName = workspaceName
        self.owner = owner; self.resources = resources
    }

    public var title: String {
        switch owner {
        case .archived: workspaceName.map { "\u{201C}\($0)\u{201D} (archived)" } ?? "An archived workspace"
        case .unknown: "A workspace no longer on this server"
        }
    }

    /// What is in it, and the compose project a reader would recognise from `docker ps`.
    public var detail: String {
        var text = WorkspaceDockerResource.summary(resources)
        let projects = Set(resources.compactMap(\.composeProject)).sorted()
        if !projects.isEmpty { text += " in " + projects.joined(separator: ", ") }
        let sizes = resources.compactMap { resource in resource.sizeLabel.map { "\(resource.name) \($0)" } }
        if !sizes.isEmpty { text += ". " + sizes.joined(separator: ", ") }
        return text
    }
}

/// The question asked before leftovers are removed, in the words the alert uses.
public struct ServerStorageLeftoverConfirmation: Sendable, Equatable {
    public var leftovers: [ServerStorageLeftover]
    public var serverName: String

    public init(leftovers: [ServerStorageLeftover], serverName: String) {
        self.leftovers = leftovers; self.serverName = serverName
    }

    public var title: String {
        leftovers.count == 1
            ? "Remove this workspace\u{2019}s containers and volumes on \(serverName)?"
            : "Remove \(leftovers.count) workspaces\u{2019} containers and volumes on \(serverName)?"
    }

    public var message: String {
        let resources = leftovers.flatMap(\.resources)
        return "This removes \(WorkspaceDockerResource.summary(resources)), including any databases and cached data "
            + "they hold. It cannot be undone, and restoring an archived workspace does not bring them back. "
            + "Shared images and build cache are kept."
    }

    public var confirmLabel: String { "Remove" }
}

public struct ServerStorageLeftoverOutcome: Codable, Sendable, Equatable {
    public var workspaceID: WorkspaceID
    public var status: ServerStorageCleanupStatus
    public var message: String

    public init(workspaceID: WorkspaceID, status: ServerStorageCleanupStatus, message: String) {
        self.workspaceID = workspaceID; self.status = status; self.message = message
    }
}

public struct ServerStorageLeftoverRemoval: Codable, Sendable, Equatable {
    public var outcomes: [ServerStorageLeftoverOutcome]
    public var report: ServerStorageReport?

    public var needsAttention: Bool { outcomes.contains { $0.status != .completed } }

    public init(outcomes: [ServerStorageLeftoverOutcome], report: ServerStorageReport? = nil) {
        self.outcomes = outcomes; self.report = report
    }
}
