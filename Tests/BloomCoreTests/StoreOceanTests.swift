import Testing
import Foundation
@testable import BloomCore

@Suite("Store oceans", .tags(.persistence), .scratchDirectory)
struct StoreOceanTests {
    @Test("seeds a fresh store with the whole catalogue, none of it used")
    func seedsFreshStore() async throws {
        let store = try makeTestStore("oceans")
        let oceans = try await store.oceans()
        #expect(oceans.count == 132)
        #expect(oceans.allSatisfy { $0.usedAt == nil })
        #expect(oceans.map(\.name) == oceans.map(\.name).sorted())
        #expect(try await store.unusedOceanCount() == 132)
    }

    @Test("a claim spends the sea and never hands it out again as a first use")
    func claimSpendsTheSea() async throws {
        let store = try makeTestStore("oceans")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pick = try #require(try await store.claimOcean(now: now))
        #expect(pick.isFirstUse)
        #expect(pick.ocean.usedAt == now)
        #expect(pick.remainingUndiscovered == 131)
        #expect(try await store.unusedOceanCount() == 131)

        var seen: Set<String> = [pick.ocean.slug]
        for claim in 1...20 {
            let next = try #require(try await store.claimOcean(now: now))
            #expect(next.isFirstUse)
            #expect(next.remainingUndiscovered == 131 - claim)
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
        #expect(discovered.count == 132)

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
        #expect(try await second.unusedOceanCount() == 131)
        let stored = try #require(try await second.oceans().first { $0.slug == pick.ocean.slug })
        #expect(stored.usedAt == now)
    }

    /// Seeding makes an empty table impossible in practice, but `claimOcean` still promises nil
    /// over a crash mid-creation, and nil is the cue that sends `startWorkspace` back to the
    /// plant placeholder and the prompt-slug branch. Emptied behind the store's back because the
    /// store itself has no way to unseed, which is the point of the seed.
    @Test("an empty table declines the claim, which is the plant fallback's cue")
    func emptyTableDeclines() async throws {
        let path = TestScratch.unique("oceans-empty") + ".sqlite"
        let store = try Store(path: path)
        let raw = try SQLiteDatabase(path: path)
        try raw.run("DELETE FROM oceans")

        #expect(try await store.claimOcean() == nil)
        #expect(try await store.unusedOceanCount() == 0)
        #expect(try await store.oceans().isEmpty)
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
        #expect(try await reopened.oceans().count == 132)
        #expect(try await reopened.unusedOceanCount() == 131)
        let stored = try #require(try await reopened.oceans().first { $0.slug == pick.ocean.slug })
        #expect(stored.usedAt == now)
    }

    /// The catalogue was trimmed to water after real databases had been seeded from the longer
    /// list, so a table can hold rows no binary's catalogue knows any more. An unclaimed one is
    /// pruned, because it must never be handed out as a name again; a claimed one keeps its row
    /// and its date, because the map still has to pin the voyage that already happened.
    @Test("migration prunes an unclaimed stranger and keeps a claimed one for the map")
    func pruneKeepsClaimedStrangers() async throws {
        let path = TestScratch.unique("oceans-prune") + ".sqlite"
        _ = try Store(path: path)

        let raw = try SQLiteDatabase(path: path)
        try raw.run(
            "INSERT INTO oceans (slug, name, latitude, longitude) VALUES (?, ?, ?, ?)",
            [.text("greenland"), .text("Greenland"), .double(72), .double(-40)]
        )
        try raw.run(
            "INSERT INTO oceans (slug, name, latitude, longitude, used_at) VALUES (?, ?, ?, ?, ?)",
            [.text("borneo"), .text("Borneo"), .double(0.96), .double(114.55), .double(42)]
        )
        raw.userVersion = 0

        let reopened = try Store(path: path)
        let oceans = try await reopened.oceans()
        #expect(!oceans.contains { $0.slug == "greenland" })
        let kept = try #require(oceans.first { $0.slug == "borneo" })
        #expect(kept.usedAt == Date(timeIntervalSince1970: 42))
        #expect(oceans.count == 133)
        #expect(try await reopened.unusedOceanCount() == 132)
    }
}
