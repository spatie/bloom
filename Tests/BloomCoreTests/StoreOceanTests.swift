import Testing
import Foundation
@testable import BloomCore

@Suite("Store oceans", .tags(.persistence), .scratchDirectory)
struct StoreOceanTests {
    @Test("seeds a fresh store with the whole catalogue, none of it used")
    func seedsFreshStore() async throws {
        let store = try makeTestStore("oceans")
        let oceans = try await store.oceans()
        #expect(oceans.count == 400)
        #expect(oceans.allSatisfy { $0.usedAt == nil })
        #expect(oceans.map(\.name) == oceans.map(\.name).sorted())
        #expect(try await store.unusedOceanCount() == 400)
    }

    @Test("a claim spends the sea and never hands it out again as a first use")
    func claimSpendsTheSea() async throws {
        let store = try makeTestStore("oceans")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pick = try #require(try await store.claimOcean(now: now))
        #expect(pick.isFirstUse)
        #expect(pick.ocean.usedAt == now)
        #expect(pick.remainingUndiscovered == 399)
        #expect(try await store.unusedOceanCount() == 399)

        var seen: Set<String> = [pick.ocean.slug]
        for claim in 1...20 {
            let next = try #require(try await store.claimOcean(now: now))
            #expect(next.isFirstUse)
            #expect(next.remainingUndiscovered == 399 - claim)
            #expect(seen.insert(next.ocean.slug).inserted, "\(next.ocean.slug) was discovered twice")
        }
    }

    @Test("hands out repeats once every sea is claimed, keeping the first-use date")
    func exhaustedCatalogueRepeats() async throws {
        let store = try makeTestStore("oceans")
        let discovery = Date(timeIntervalSince1970: 1_000_000)
        var discovered: Set<String> = []
        while try await store.unusedOceanCount() > 0 {
            let pick = try #require(try await store.claimOcean(now: discovery))
            #expect(pick.isFirstUse)
            discovered.insert(pick.ocean.slug)
        }
        #expect(discovered.count == 400)

        let later = Date(timeIntervalSince1970: 2_000_000)
        for _ in 0..<5 {
            let repeated = try #require(try await store.claimOcean(now: later))
            #expect(repeated.isFirstUse == false)
            #expect(repeated.remainingUndiscovered == 0)
            #expect(repeated.notice == nil)
            // A repeat is not a discovery, so the date of the real one has to survive it.
            #expect(repeated.ocean.usedAt == discovery)
        }
        #expect(try await store.unusedOceanCount() == 0)
    }

    @Test("a reopen keeps used_at rather than reseeding it away")
    func reopenKeepsUsedFlags() async throws {
        let path = TestScratch.unique("oceans-persist") + ".sqlite"
        let now = Date(timeIntervalSince1970: 42)
        let first = try Store(path: path)
        let pick = try #require(try await first.claimOcean(now: now))

        let second = try Store(path: path)
        #expect(try await second.unusedOceanCount() == 399)
        let stored = try #require(try await second.oceans().first { $0.slug == pick.ocean.slug })
        #expect(stored.usedAt == now)
    }

    /// The seed loops over the catalogue, and the store's own tests rewind `user_version` to
    /// reproduce an old schema, so a seed that could not be replayed would throw and take the
    /// whole migration transaction with it. `INSERT OR IGNORE` is the property under test here.
    @Test("the seeding migration survives being replayed, and keeps what was claimed")
    func seedingMigrationReplays() async throws {
        let path = TestScratch.unique("oceans-replay") + ".sqlite"
        let now = Date(timeIntervalSince1970: 42)
        let store = try Store(path: path)
        let pick = try #require(try await store.claimOcean(now: now))

        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        #expect(try await reopened.oceans().count == 400)
        #expect(try await reopened.unusedOceanCount() == 399)
        let stored = try #require(try await reopened.oceans().first { $0.slug == pick.ocean.slug })
        #expect(stored.usedAt == now)
    }
}
