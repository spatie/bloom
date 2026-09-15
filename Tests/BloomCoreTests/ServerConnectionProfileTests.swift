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

    @MainActor @Test func removalPreservesOtherServersDraftsAndLocalPreferences() throws {
        let suite = "be.spatie.bloom.test.removal.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = try #require(ServerConnectionProfile(values: ssh, label: "First"))
        var other = ssh; other["host"] = "bloom@two"
        let second = try #require(ServerConnectionProfile(values: other, label: "Second"))
        let shelf = ServerConnectionShelf(preferences: preferences)
        shelf.remember(first)
        shelf.remember(second)
        var current = ssh; current["localRepository"] = "/local/repository"; current["repository"] = "/remote/repository"
        preferences.set(current, forKey: "server.connection")
        preferences.set(["ssh:bloom@one:/var/lib/bloom": "First", "ssh:bloom@two:/var/lib/bloom": "Second"], forKey: "server.labels")
        let draft = Data("preserved conversation draft".utf8)
        preferences.set(draft, forKey: "server.scopedDrafts")
        let removed = shelf.remove(first)
        #expect(removed)
        let restored = ServerConnectionShelf(preferences: preferences)
        #expect(restored.profiles == [second])
        #expect(restored.connectionValues(seed: ssh)["host"] == nil)
        #expect(restored.connectionValues(seed: ssh)["identityFile"] == nil)
        #expect(restored.connectionValues(seed: ssh)["localRepository"] == "/local/repository")
        #expect(preferences.data(forKey: "server.scopedDrafts") == draft)
        #expect(preferences.dictionary(forKey: "server.labels") as? [String: String] == ["ssh:bloom@two:/var/lib/bloom": "Second"])
    }

    @MainActor @Test func removedPresetStaysRemovedAcrossRebuildsAndCanBeExplicitlyAddedAgain() throws {
        let suite = "be.spatie.bloom.test.preset-removal.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = try #require(ServerConnectionProfile(values: ssh))
        let shelf = ServerConnectionShelf(preferences: preferences)
        shelf.remember(first)
        let removed = shelf.remove(first)
        #expect(removed)
        var newBuild = ssh; newBuild["executable"] = "/updated/server"; newBuild["identityFile"] = "/rotated/key"
        let reopened = ServerConnectionShelf(preferences: preferences)
        #expect(reopened.connectionValues(seed: newBuild).isEmpty)
        #expect(reopened.profiles.isEmpty)
        // Interrupted preference writes cannot restore a removed item through the saved list.
        preferences.set(try JSONEncoder().encode([first]), forKey: "server.savedConnections")
        #expect(ServerConnectionShelf(preferences: preferences).profiles.isEmpty)
        // A stale saved current entry must not override the removal tombstone either.
        preferences.set(ssh, forKey: "server.connection")
        #expect(reopened.connectionValues(seed: newBuild).isEmpty)
        reopened.remember(first)
        #expect(ServerConnectionShelf(preferences: preferences).connectionValues(seed: ssh)["host"] == "bloom@one")
        #expect(ServerConnectionShelf(preferences: preferences).profiles == [first])
    }

    @MainActor @Test func removingAnotherProfileDoesNotClearCurrentServer() throws {
        let suite = "be.spatie.bloom.test.other-removal.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = try #require(ServerConnectionProfile(values: ssh))
        var other = ssh; other["host"] = "bloom@two"
        let second = try #require(ServerConnectionProfile(values: other))
        let shelf = ServerConnectionShelf(preferences: preferences)
        shelf.remember(first)
        shelf.remember(second)
        preferences.set(other, forKey: "server.connection")
        let removed = shelf.remove(first)
        #expect(removed)
        #expect(shelf.connectionValues(seed: ssh) == other)
        #expect(shelf.profiles == [second])
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
