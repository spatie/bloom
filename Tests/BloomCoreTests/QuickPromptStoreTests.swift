import Testing
import Foundation
@testable import BloomCore

/// The quick prompt table, and the one question it exists to answer twice: a built-in arrives on a
/// fresh install, and a built-in the owner deleted stays deleted for good.
@Suite("Quick prompt store", .tags(.persistence), .scratchDirectory)
struct QuickPromptStoreTests {
    @Test("round-trips a prompt")
    func roundTrips() async throws {
        let store = try makeTestStore("quick-prompts")
        let written = try await store.insert(
            QuickPrompt(name: "Tests", symbol: "hammer", text: "Run make test.")
        )

        let loaded = try await store.quickPrompts()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == written.id)
        #expect(loaded[0].name == "Tests")
        #expect(loaded[0].symbol == "hammer")
        #expect(loaded[0].text == "Run make test.")
    }

    @Test("keeps prompts in the order they were written")
    func keepsOrder() async throws {
        let store = try makeTestStore("quick-prompts")
        for name in ["first", "second", "third"] {
            try await store.insert(QuickPrompt(name: name, text: name))
        }

        #expect(try await store.quickPrompts().map(\.name) == ["first", "second", "third"])
        #expect(try await store.quickPrompts().map(\.sortOrder) == [0, 1, 2])
    }

    /// The rule at the head of `Store`, on this table: a write changes the columns it names and no
    /// others. The form is open for as long as somebody takes to write a paragraph, and the copy it
    /// was opened with must not carry the rest of the row back to what it looked like then.
    @Test("an update writes only what it changed")
    func updatesNarrowly() async throws {
        let store = try makeTestStore("quick-prompts")
        let written = try await store.insert(
            QuickPrompt(name: "Tests", symbol: "hammer", text: "Run make test.")
        )

        let changed = try await store.update(quickPromptID: written.id) { $0.name = "Run tests" }
        #expect(changed?.name == "Run tests")

        let loaded = try await store.quickPrompts()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "Run tests")
        #expect(loaded[0].symbol == "hammer")
        #expect(loaded[0].text == "Run make test.")
        #expect(loaded[0].sortOrder == written.sortOrder)
        // Not exact equality: a `Date` goes to SQLite as seconds since 1970 and comes back
        // through the same conversion, which is a rounding of the last few decimal places.
        #expect(abs(loaded[0].createdAt.timeIntervalSince(written.createdAt)) < 0.001)
    }

    @Test("an update to a prompt that is gone changes nothing and says so")
    func updatesNothing() async throws {
        let store = try makeTestStore("quick-prompts")
        let missing = try await store.update(quickPromptID: QuickPromptID.new()) { $0.name = "x" }
        #expect(missing == nil)
        #expect(try await store.quickPrompts().isEmpty)
    }

    @Test("deletes one prompt and leaves the rest")
    func deletes() async throws {
        let store = try makeTestStore("quick-prompts")
        let first = try await store.insert(QuickPrompt(name: "first", text: "a"))
        try await store.insert(QuickPrompt(name: "second", text: "b"))

        try await store.deleteQuickPrompt(id: first.id)
        #expect(try await store.quickPrompts().map(\.name) == ["second"])
    }

    @Test("a fresh database is seeded with the built-ins")
    func seeds() async throws {
        let store = try makeTestStore("quick-prompts")
        let seeded = try await store.seedQuickPrompts()

        #expect(seeded.count == QuickPromptSeed.all.count)
        #expect(seeded.map(\.name) == QuickPromptSeed.all.map(\.name))
        #expect(try await store.setting(QuickPromptSeed.versionKey) == String(QuickPromptSeed.version))
    }

    @Test("seeding twice inserts nothing the second time")
    func seedsOnce() async throws {
        let store = try makeTestStore("quick-prompts")
        try await store.seedQuickPrompts()
        try await store.seedQuickPrompts()
        try await store.seedQuickPrompts()

        #expect(try await store.quickPrompts().count == QuickPromptSeed.all.count)
    }

    /// The whole reason the seed is versioned rather than reconciled. A built-in the owner deleted
    /// is deleted, and every launch after that has to leave it alone.
    @Test("a deleted built-in stays deleted across relaunches")
    func deletedBuiltInStaysDeleted() async throws {
        let path = TestScratch.unique("quick-prompt-seed") + ".sqlite"
        let first = try Store(path: path)
        let seeded = try await first.seedQuickPrompts()
        let built = try #require(seeded.first)
        try await first.deleteQuickPrompt(id: built.id)
        #expect(try await first.quickPrompts().isEmpty)

        // A second `Store` on the same file is the next launch: the migrations run again, and so
        // does the seeding.
        let relaunched = try Store(path: path)
        let after = try await relaunched.seedQuickPrompts()
        #expect(after.isEmpty)
    }

    /// The seeding rule, reached the other way: through the bridge rather than through the panel.
    ///
    /// Here rather than in a second suite of its own, because it is the same question these tests
    /// already exist to answer and the answer must not depend on which door the delete came
    /// through. `quick_prompt_delete` calls `Store.deleteQuickPrompt`, which is what the panel's
    /// own menu calls, and nothing in the four tools writes `QuickPromptSeed.versionKey`. So a
    /// built-in deleted by an agent is deleted exactly as one deleted by hand is.
    @Test("a built-in deleted through the bridge stays deleted, and no tool can reseed it")
    func deletedThroughTheBridgeStaysDeleted() async throws {
        let path = TestScratch.unique("quick-prompt-bridge-seed") + ".sqlite"
        let first = try Store(path: path)

        // The listing is the tool that seeds, because the panel does it on first open and the two
        // have to describe the same library. See `QuickPromptCall`.
        let listed = await tool(QuickPromptListTool(), on: first)
        #expect(!listed.isError)
        let built = try #require(try await first.quickPrompts().first)
        #expect(built.name == QuickPromptSeed.all.first?.name)

        let deleted = await tool(
            QuickPromptDeleteTool(), ["id": .string(built.id.rawValue)], on: first
        )
        #expect(!deleted.isError)
        #expect(try await first.quickPrompts().isEmpty)

        // Asking again is the thing that would resurrect it if the rule were "reconcile the list
        // against the table" rather than "seed once and record it".
        _ = await tool(QuickPromptListTool(), on: first)
        #expect(try await first.quickPrompts().isEmpty)

        // A second `Store` on the same file is the next launch, and the panel seeds again there.
        let relaunched = try Store(path: path)
        #expect(try await relaunched.seedQuickPrompts().isEmpty)
        #expect(
            try await relaunched.setting(QuickPromptSeed.versionKey)
                == String(QuickPromptSeed.version)
        )
    }

    /// One call, through the same door `BridgeDispatch` uses. The identity is the owner's own
    /// client, which is the only role that may delete.
    private func tool(
        _ handler: any BridgeToolHandling,
        _ arguments: [String: JSONValue] = [:],
        on store: Store
    ) async -> BridgeToolResult {
        await handler.call(
            MCPRequest(id: .number(1), method: handler.tool.name, params: .object(arguments)),
            as: .owner,
            store: store
        )
    }

    /// A built-in added later is inserted on its own, without putting back anything that was
    /// deleted before it. Driven through the pure half, because the entries a shipped build seeds
    /// are the ones written down in `QuickPromptSeed`.
    @Test("a later built-in inserts itself and resurrects nothing")
    func laterBuiltIn() async throws {
        let store = try makeTestStore("quick-prompts")
        try await store.seedQuickPrompts()
        for prompt in try await store.quickPrompts() {
            try await store.deleteQuickPrompt(id: prompt.id)
        }

        let next = QuickPromptSeed.Entry(
            name: "Later", symbol: "sparkles", text: "Something new.",
            introducedIn: QuickPromptSeed.version + 1
        )
        #expect(QuickPromptSeed.pending(installed: QuickPromptSeed.version).isEmpty)

        // What `seedQuickPrompts` would do with that entry on the list.
        try await store.insert(next.prompt(sortOrder: 0))
        #expect(try await store.quickPrompts().map(\.name) == ["Later"])
    }
}
