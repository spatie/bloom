import Foundation
import Observation

/// Connection history stays on this Mac; the server remains authoritative for workspace data.
@MainActor @Observable
public final class ServerConnectionShelf {
    public private(set) var profiles: [ServerConnectionProfile] = []
    public private(set) var failure: String?
    private let preferences: UserDefaults
    private let key = "server.savedConnections"

    public init(preferences: UserDefaults) {
        self.preferences = preferences
        guard let data = preferences.data(forKey: key) else { return }
        do { profiles = try JSONDecoder().decode([ServerConnectionProfile].self, from: data) } catch {
            preferences.set(data, forKey: key + ".unreadable")
            failure = "Some saved connections could not be read. The original list has been kept for recovery; your current connection is still available."
        }
    }

    public func remember(_ profile: ServerConnectionProfile) {
        let updated = ServerConnectionProfile.remembering(profile, in: profiles)
        guard updated != profiles else { return }
        do {
            let data = try JSONEncoder().encode(updated)
            preferences.set(data, forKey: key)
            profiles = updated
        } catch { failure = "The server connection could not be saved. Try again after reopening Bloom." }
    }
}
