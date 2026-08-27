import Testing
import Foundation
@testable import BloomCore

/// The `hosts` table, and the rule the whole of `Store` runs on: `insert` creates a row, and a
/// narrow writer changes the columns it names and no others.
///
/// The isolation half is `WorkspaceWriteIsolationTests` written for this table, and it is not a
/// theoretical worry here either. A probe takes twenty seconds; renaming a server takes as long as
/// somebody types. Those two overlap on the first afternoon anybody uses this.
@Suite("Servers in the store", .tags(.persistence), .scratchDirectory)
struct ServerStoreTests {
    private func destination(_ text: String) throws -> SSHDestination {
        try SSHDestination.parse(text)
    }

    private func seed(_ store: Store, _ text: String = "deploy@vps.example.com") async throws -> Server {
        let target = try destination(text)
        return try await store.insert(Server(label: target.suggestedLabel, destination: target))
    }

    @Test("a server round trips")
    func roundTrip() async throws {
        let store = try makeTestStore("servers")
        let server = try await seed(store)

        let stored = try #require(try await store.server(id: server.id))
        #expect(stored.label == "vps")
        #expect(stored.destination.user == "deploy")
        #expect(stored.destination.host == "vps.example.com")
        #expect(stored.state == .unknown)
        #expect(stored.detail.isEmpty)
        #expect(stored.bloomdVersion == nil)
        #expect(stored.probedAt == nil)
    }

    @Test("a port survives the round trip")
    func portRoundTrips() async throws {
        let store = try makeTestStore("servers")
        let server = try await seed(store, "deploy@vps.example.com:2222")
        let stored = try #require(try await store.server(id: server.id))
        #expect(stored.destination.port == 2222)
    }

    @Test("servers come back in the order they were added")
    func order() async throws {
        let store = try makeTestStore("servers")
        _ = try await seed(store, "a@one")
        _ = try await seed(store, "a@two")
        _ = try await seed(store, "a@three")
        #expect(try await store.servers().map(\.destination.host) == ["one", "two", "three"])
    }

    /// Two rows for one destination would each keep their own idea of that machine's state and
    /// each write it over the other's.
    @Test("the same destination cannot be added twice")
    func destinationIsUnique() async throws {
        let store = try makeTestStore("servers")
        _ = try await seed(store)
        await #expect(throws: (any Error).self) { _ = try await seed(store) }
    }

    // MARK: - The two writers

    /// The pair that overlap in real use: a probe lands while somebody is renaming the row it is
    /// about. Neither may undo the other.
    @Test("a probe and a rename do not undo each other")
    func writersDoNotCollide() async throws {
        let store = try makeTestStore("servers")
        let server = try await seed(store)

        // The pane reads the row and opens a rename field. Meanwhile the probe finishes.
        try await store.recordProbe(
            serverID: server.id,
            verdict: ServerVerdict(state: .ready, detail: "No GitHub CLI on it."),
            bloomdVersion: "1",
            at: Date(timeIntervalSince1970: 1_000)
        )
        // And now the rename lands, holding a copy of the row from before the probe.
        try await store.update(serverID: server.id) { $0.label = "production" }

        let stored = try #require(try await store.server(id: server.id))
        #expect(stored.label == "production")
        #expect(stored.state == .ready)
        #expect(stored.detail == "No GitHub CLI on it.")
        #expect(stored.bloomdVersion == "1")
        #expect(stored.probedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("a probe leaves the label and the destination alone")
    func probeLeavesThePersonsColumnsAlone() async throws {
        let store = try makeTestStore("servers")
        let server = try await seed(store)
        try await store.update(serverID: server.id) { $0.label = "production" }

        try await store.recordProbe(
            serverID: server.id,
            verdict: ServerVerdict(state: .unreachable, detail: "No answer."),
            bloomdVersion: nil
        )

        let stored = try #require(try await store.server(id: server.id))
        #expect(stored.label == "production")
        #expect(stored.destination.host == "vps.example.com")
        #expect(stored.state == .unreachable)
    }

    /// `probed_at` means "when this row last learned something". Moving it when a look STARTS
    /// would make a server that has been unreachable for a week read as checked a second ago.
    @Test("starting a probe does not move the last probed time")
    func probingDoesNotMoveTheClock() async throws {
        let store = try makeTestStore("servers")
        let server = try await seed(store)
        try await store.recordProbe(
            serverID: server.id,
            verdict: ServerVerdict(state: .unreachable, detail: "No answer."),
            bloomdVersion: nil,
            at: Date(timeIntervalSince1970: 500)
        )

        try await store.markServerProbing(serverID: server.id)

        let stored = try #require(try await store.server(id: server.id))
        #expect(stored.state == .probing)
        // The old sentence goes, because it is about a look that is being replaced.
        #expect(stored.detail.isEmpty)
        #expect(stored.probedAt == Date(timeIntervalSince1970: 500))
    }

    @Test("a probe of a server that has been deleted lands on nothing and says so")
    func probeOfAMissingRow() async throws {
        let store = try makeTestStore("servers")
        let server = try await seed(store)
        try await store.deleteServer(id: server.id)

        let landed = try await store.recordProbe(
            serverID: server.id,
            verdict: ServerVerdict(state: .ready),
            bloomdVersion: "1"
        )
        #expect(landed == nil)
        #expect(try await store.servers().isEmpty)
    }

    @Test("deleting a server takes only that one")
    func delete() async throws {
        let store = try makeTestStore("servers")
        let first = try await seed(store, "a@one")
        _ = try await seed(store, "a@two")

        try await store.deleteServer(id: first.id)
        #expect(try await store.servers().map(\.destination.host) == ["two"])
    }

    /// The migration list is replayed from zero by several tests here, and by every user whose
    /// database predates a step. A `CREATE TABLE IF NOT EXISTS` has to survive that over rows that
    /// already exist, which is the shape every other step in `Store.migrate` is written in and the
    /// reason it is written that way.
    @Test("replaying the migration keeps the rows that are already there")
    func migrationReplays() async throws {
        let path = TestScratch.unique("hosts-migration") + ".sqlite"
        let store = try Store(path: path)
        let target = try destination("deploy@vps.example.com")
        let server = try await store.insert(Server(label: "vps", destination: target))
        try await store.recordProbe(
            serverID: server.id,
            verdict: ServerVerdict(state: .ready),
            bloomdVersion: "1"
        )

        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        let stored = try #require(try await reopened.server(id: server.id))
        #expect(stored.label == "vps")
        #expect(stored.state == .ready)
        #expect(stored.bloomdVersion == "1")
    }

    /// A write to this table has to reach a subscriber, or a second window would go on drawing a
    /// server that has been removed.
    @Test("the table has a domain, so a write is published")
    func hasADomain() {
        #expect(StoreDomain(rawValue: "hosts") == .hosts)
        #expect(StoreDomain.allCases.contains(.hosts))
    }

    /// A row edited by hand in `sqlite3` should still be visible and still deletable, rather than
    /// dropping out of the list with no explanation.
    @Test("a destination that will not parse still comes back as a row")
    func unparseableRow() async throws {
        let store = try makeTestStore("servers")
        let server = try await seed(store)
        try await store.update(serverID: server.id) {
            $0.destination = SSHDestination(user: nil, host: "a host with spaces")
        }
        let stored = try #require(try await store.server(id: server.id))
        #expect(stored.destination.host == "a host with spaces")
    }
}
