import Foundation

/// Read-only confirmation supplied by the host. Clients return its identifier unchanged.
/// Every risk field is required: an incomplete report must never look safe to archive.
public struct RemoteArchivePreview: Decodable, Sendable {
    public let id: UUID
    public let workspace: RemoteWorkspace
    public let report: WorkspaceSafetyReport
    public let hazards: ArchiveHazards
    public let createdAt: Date
}

extension RemoteCommand {
    public static func cancelQueued(sessionID: SessionID, deliveryID: DeliveryID, id: UUID = UUID()) -> Self {
        Self(.object(["cancelQueued": .object(["sessionID": .string(sessionID.rawValue), "deliveryID": .string(deliveryID.rawValue)])]), id: id)
    }

    public static func archive(workspaceID: WorkspaceID, confirmation: UUID, id: UUID = UUID()) -> Self {
        workspace(workspaceID, action: "archive", arguments: ["confirmation": .string(confirmation.uuidString)], id: id)
    }

    public static func restore(workspaceID: WorkspaceID, id: UUID = UUID()) -> Self {
        workspace(workspaceID, action: "restore", id: id)
    }

    fileprivate static func workspace(_ id: WorkspaceID, action: String, arguments: [String: JSONValue] = [:], id commandID: UUID = UUID()) -> Self {
        Self(.object(["workspace": .object(["workspaceID": .string(id.rawValue), "action": .object([action: .object(arguments)])])]), id: commandID)
    }
}

extension RemoteWorkspaceService {
    public func archivePreview(workspaceID: WorkspaceID) async throws -> RemoteArchivePreview {
        let result = try await client.request(.workspace(workspaceID, action: "archivePreview"))
        guard let payload = result["archivePreview"]?["_0"] else {
            throw ConnectionFailure("The server did not return an archive confirmation. No workspace was archived.")
        }
        let preview = try JSONDecoder().decode(RemoteArchivePreview.self, from: JSONEncoder().encode(payload))
        guard preview.workspace.id == workspaceID else {
            throw ConnectionFailure("The server returned an archive confirmation for a different workspace. Refresh before trying again.")
        }
        return preview
    }

    /// Keep commandID when retrying an uncertain request. These methods never retry automatically.
    public func cancelQueued(sessionID: SessionID, deliveryID: DeliveryID, commandID: UUID = UUID()) async throws {
        try await acceptLifecycleCommand(.cancelQueued(sessionID: sessionID, deliveryID: deliveryID, id: commandID))
    }

    public func archive(workspaceID: WorkspaceID, confirmation: UUID, commandID: UUID = UUID()) async throws {
        try await acceptLifecycleCommand(.archive(workspaceID: workspaceID, confirmation: confirmation, id: commandID))
    }

    public func restore(workspaceID: WorkspaceID, commandID: UUID = UUID()) async throws {
        try await acceptLifecycleCommand(.restore(workspaceID: workspaceID, id: commandID))
    }

    private func acceptLifecycleCommand(_ command: RemoteCommand) async throws {
        let result = try await client.request(command)
        guard result == .object(["accepted": .object([:])]) else {
            throw ConnectionFailure("The server did not confirm this change. Retry with the same command ID.")
        }
    }
}
