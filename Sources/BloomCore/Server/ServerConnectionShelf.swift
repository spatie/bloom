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
        do {
            let removed = Set(preferences.stringArray(forKey: key + ".removed") ?? [])
            profiles = try JSONDecoder().decode([ServerConnectionProfile].self, from: data).filter { !removed.contains($0.id) }
        } catch {
            preferences.set(data, forKey: key + ".unreadable")
            failure = "Some saved connections could not be read. The original list has been kept for recovery; your current connection is still available."
        }
    }

    /// A removed bundled preset must not silently return on the next launch. Explicitly adding
    /// that address again clears its tombstone, while drafts and key files keep their own lifetime.
    public func connectionValues(seed: [String: String]) -> [String: String] {
        let removed = Set(preferences.stringArray(forKey: key + ".removed") ?? [])
        var initial = seed
        if let profile = ServerConnectionProfile(values: seed), removed.contains(profile.id) { initial = [:] }
        var saved = preferences.dictionary(forKey: "server.connection") as? [String: String] ?? [:]
        if let profile = ServerConnectionProfile(values: saved), removed.contains(profile.id) {
            saved = saved.filter { !Self.connectionKeys.contains($0.key) }
        }
        return initial.merging(saved) { _, saved in saved }
    }

    @discardableResult
    public func remove(_ profile: ServerConnectionProfile) -> Bool {
        let updated = profiles.filter { $0.id != profile.id }
        do {
            let data = try JSONEncoder().encode(updated)
            var removed = Set(preferences.stringArray(forKey: key + ".removed") ?? [])
            removed.insert(profile.id)
            preferences.set(Array(removed).sorted(), forKey: key + ".removed")
            preferences.set(data, forKey: key)
            profiles = updated
            var current = preferences.dictionary(forKey: "server.connection") as? [String: String] ?? [:]
            if ServerConnectionProfile(values: current)?.id == profile.id {
                current = current.filter { !Self.connectionKeys.contains($0.key) }
                preferences.set(current, forKey: "server.connection")
            }
            var labels = preferences.dictionary(forKey: "server.labels") as? [String: String] ?? [:]
            let labelKey = profile.usesHTTPS ? "https:" + profile.httpsAddress : "ssh:" + profile.host + ":" + profile.directory
            labels[labelKey] = nil
            preferences.set(labels, forKey: "server.labels")
            return true
        } catch {
            failure = "The server connection could not be removed. Try again after reopening Bloom."
            return false
        }
    }

    private static let connectionKeys: Set<String> = [
        "usesHTTPS", "httpsAddress", "host", "executable", "directory", "identityFile", "knownHostsFile", "repository",
    ]

    public func remember(_ profile: ServerConnectionProfile) {
        let updated = ServerConnectionProfile.remembering(profile, in: profiles)
        let removed = preferences.stringArray(forKey: key + ".removed") ?? []
        guard updated != profiles || removed.contains(profile.id) else { return }
        do {
            let data = try JSONEncoder().encode(updated)
            preferences.set(data, forKey: key)
            profiles = updated
            preferences.set(removed.filter { $0 != profile.id }, forKey: key + ".removed")
        } catch { failure = "The server connection could not be saved. Try again after reopening Bloom." }
    }
}
