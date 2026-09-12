import Foundation
import Observation
import BloomClient

/// Native clients share credential pairing and session ownership. Recreate this object when the
/// verified server connection changes; maintenance jobs themselves remain owned by the server.
@MainActor @Observable
public final class ServerMaintenanceAccess {
    public let session: ServerMaintenanceSession
    public let serverID: String
    public private(set) var hasSavedCredential = false
    public private(set) var credentialFailure: String?
    public private(set) var isPairing = false

    public init(serverID: String, client: any RemoteRequesting) {
        self.serverID = serverID
        session = ServerMaintenanceSession(client: client)
    }

    public func refresh() async {
        guard !isPairing else { return }
        credentialFailure = nil
        do {
            let credential = try ServerMaintenanceCredentials.load(serverID: serverID)
            hasSavedCredential = credential != nil
            await session.refresh(credential: credential)
        } catch {
            credentialFailure = error.localizedDescription
        }
    }

    public func pair(token: String) async -> Bool {
        guard !isPairing, session.activity == .idle else { return false }
        isPairing = true
        defer { isPairing = false }
        credentialFailure = nil
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...4_096).contains(token.utf8.count), !token.contains(where: \.isWhitespace) else {
            credentialFailure = "Enter the maintenance key provided when this server was set up."
            return false
        }
        // A revoked key must be replaceable even after a lost update response. The session
        // keeps that request's identity; pairing only authenticates and reads job history.
        session.clearCredential()
        await session.refresh(credential: token)
        guard !Task.isCancelled, session.authorized, session.failure == nil else { return false }
        do {
            try ServerMaintenanceCredentials.save(token: token, serverID: serverID)
            hasSavedCredential = true
            return true
        } catch {
            credentialFailure = error.localizedDescription
            return false
        }
    }

    public func forget() throws {
        guard !isPairing, session.activity == .idle, session.pendingMutationID == nil else {
            throw ConnectionFailure("Wait for the maintenance request to be confirmed before removing access.")
        }
        try ServerMaintenanceCredentials.delete(serverID: serverID)
        session.clearCredential()
        hasSavedCredential = false
        credentialFailure = nil
    }
}
