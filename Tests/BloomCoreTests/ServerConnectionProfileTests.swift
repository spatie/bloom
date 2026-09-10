import Foundation
import Testing
@testable import BloomCore

struct ServerConnectionProfileTests {
    private let ssh = ["host": "bloom@one", "executable": "/opt/bloom/server", "directory": "/var/lib/bloom",
                       "identityFile": "/Users/example/key", "knownHostsFile": "/Users/example/hosts"]

    @Test func addingAnotherServerPreservesFirstAndItsTrustStore() throws {
        let first = try #require(ServerConnectionProfile(values: ssh, label: "First"))
        var other = ssh; other["host"] = "bloom@two"
        let second = try #require(ServerConnectionProfile(values: other, label: "Second"))
        let saved = ServerConnectionProfile.remembering(second, in: [first])
        let restored = try JSONDecoder().decode([ServerConnectionProfile].self, from: JSONEncoder().encode(saved))
        #expect(restored == [first, second])
        #expect(restored.first?.endpoint == first.endpoint)
    }

    @Test func renamingOrRotatingAKeyUpdatesExistingServer() throws {
        let old = try #require(ServerConnectionProfile(values: ssh, label: "Old"))
        var rotated = ssh; rotated["identityFile"] = "/Users/example/new-key"; rotated["executable"] = "/opt/bloom/new-server"
        let new = try #require(ServerConnectionProfile(values: rotated, label: "New"))
        #expect(ServerConnectionProfile.remembering(new, in: [old]) == [new])
    }

    @Test func separateDataDirectoriesRemainDistinct() throws {
        let first = try #require(ServerConnectionProfile(values: ssh))
        var other = ssh; other["directory"] = "/var/lib/another-bloom"
        let second = try #require(ServerConnectionProfile(values: other))
        #expect(ServerConnectionProfile.remembering(second, in: [first]).count == 2)
    }

    @Test func migrationCopiesOnlyConnectionFields() throws {
        var legacy = ssh; legacy["accessToken"] = "not-a-real-token"; legacy["draft"] = "private draft"
        let profile = try #require(ServerConnectionProfile(values: legacy))
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        #expect(!encoded.contains("not-a-real-token"))
        #expect(!encoded.contains("private draft"))
        #expect(ServerConnectionProfile(values: ["host": "incomplete"]) == nil)
    }

    @MainActor @Test func corruptHistoryDoesNotLoseOutgoingConnection() throws {
        let suite = "be.spatie.bloom.test.connections.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let unreadable = Data("not valid JSON".utf8)
        preferences.set(unreadable, forKey: "server.savedConnections")
        let shelf = ServerConnectionShelf(preferences: preferences)
        let first = try #require(ServerConnectionProfile(values: ssh, label: "First"))
        var values = ssh; values["host"] = "bloom@second"
        let second = try #require(ServerConnectionProfile(values: values, label: "Second"))
        shelf.remember(first)
        shelf.remember(second)
        #expect(preferences.data(forKey: "server.savedConnections.unreadable") == unreadable)
        #expect(ServerConnectionShelf(preferences: preferences).profiles == [first, second])
    }
}
