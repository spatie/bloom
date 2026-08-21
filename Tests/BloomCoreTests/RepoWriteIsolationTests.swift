import Testing
import Foundation
@testable import BloomCore

/// What a writer of the `repos` table is allowed to change, and what it must leave alone.
///
/// The same rule as `WorkspaceWriteIsolationTests`, one table over, and it became worth writing
/// down the moment projects grew an icon. Five things write to a project row: the sidebar's
/// disclosure triangle, the rename field, the accent well in two different windows, and the icon
/// buttons in the project settings window. They hold their copy of the row for very different
/// lengths of time. Collapsing a section is instant. The accent well writes on every distinct
/// colour of a drag. "Find icon" holds its value across a walk of the project directory, and
/// "Choose icon" holds it across a whole open panel, which is as long as somebody takes to find a
/// file.
///
/// Each of them used to write the whole `Repo` value it was holding, so whichever wrote last put
/// every column back to what it had seen. On this table that is not a number that heals: the
/// project loses the icon Bloom found for it and goes back to drawing its initials, or gets its
/// old name or its old colour back, and stays that way.
@Suite("Project write isolation", .tags(.persistence), .scratchDirectory)
struct RepoWriteIsolationTests {
    private func seed(_ store: Store) async throws -> Repo {
        try await store.upsert(Repo(
            name: "bloom", path: TestScratch.unique("project"), defaultBranch: "main", accent: "4C8DF6"
        ))
    }

    /// The case the icon work made real. Detection finishes and writes, and then the colour well
    /// in the same window writes from the value it was drawn with, which has no icon in it.
    @Test("changing the colour does not undo the icon that was just found")
    func accentDoesNotEraseTheIcon() async throws {
        let store = try makeTestStore("repo-isolation")
        let repo = try await seed(store)

        try await store.update(repoID: repo.id) {
            $0.iconPath = "/projects/bloom/public/favicon.png"
            $0.iconSource = .detected
        }
        // The colour well was drawn before any of that.
        try await store.update(repoID: repo.id) { $0.accent = "FF3B30" }

        let stored = try #require(try await store.repo(id: repo.id))
        #expect(stored.accent == "FF3B30")
        #expect(stored.iconPath == "/projects/bloom/public/favicon.png")
        #expect(stored.iconSource == .detected)
        #expect(stored.hasIcon)
    }

    /// And the other direction, which is the one an open panel makes wide: the icon write lands
    /// after a minute of browsing, carrying a name from before the rename.
    @Test("choosing an icon does not undo a rename made while the panel was open")
    func iconWriteDoesNotUndoARename() async throws {
        let store = try makeTestStore("repo-isolation")
        let repo = try await seed(store)

        try await store.update(repoID: repo.id) { $0.name = "Bloom" }
        // The open panel closes and the choice is written from a value captured before that.
        try await store.update(repoID: repo.id) {
            $0.iconPath = "/pictures/mark.svg"
            $0.iconSource = .chosen
        }

        let stored = try #require(try await store.repo(id: repo.id))
        #expect(stored.name == "Bloom")
        #expect(stored.iconSource == .chosen)
    }

    @Test("a write leaves alone every column it did not name")
    func writeTouchesOnlyWhatItNames() async throws {
        let store = try makeTestStore("repo-isolation")
        let repo = try await seed(store)

        try await store.update(repoID: repo.id) { $0.name = "renamed" }
        try await store.update(repoID: repo.id) { $0.accent = "34C759" }
        try await store.update(repoID: repo.id) { $0.collapsed = true }
        try await store.update(repoID: repo.id) {
            $0.iconPath = "/p/icon.png"
            $0.iconSource = .detected
        }

        let stored = try #require(try await store.repo(id: repo.id))
        #expect(stored.name == "renamed")
        #expect(stored.accent == "34C759")
        #expect(stored.collapsed)
        #expect(stored.iconPath == "/p/icon.png")
        #expect(stored.iconSource == .detected)
        #expect(stored.path == repo.path)
        #expect(stored.defaultBranch == "main")
        // To the millisecond: the column is a REAL holding a Unix time, so the last bits of a
        // `Date` do not survive the round trip. What matters is that nothing rewrote it.
        #expect(abs(stored.createdAt.timeIntervalSince(repo.createdAt)) < 0.001)
    }

    /// Asking for the monogram back is a decision, not an absence, so it has to survive the next
    /// write like anything else.
    @Test("asking for the monogram back is not undone by the next write")
    func monogramSurvives() async throws {
        let store = try makeTestStore("repo-isolation")
        let repo = try await seed(store)

        try await store.update(repoID: repo.id) {
            $0.iconPath = "/p/icon.png"
            $0.iconSource = .detected
        }
        try await store.update(repoID: repo.id) {
            $0.iconPath = nil
            $0.iconSource = .monogram
        }
        try await store.update(repoID: repo.id) { $0.collapsed.toggle() }

        let stored = try #require(try await store.repo(id: repo.id))
        #expect(stored.iconPath == nil)
        #expect(stored.iconSource == .monogram)
        #expect(stored.hasIcon == false)
    }

    @Test("a toggle is against the stored value, not against the caller's copy")
    func toggleIsAgainstTheStoredValue() async throws {
        let store = try makeTestStore("repo-isolation")
        let repo = try await seed(store)

        try await store.update(repoID: repo.id) { $0.collapsed.toggle() }
        try await store.update(repoID: repo.id) { $0.collapsed.toggle() }

        #expect(try await store.repo(id: repo.id)?.collapsed == false)
    }

    @Test("a targeted write does not recreate a project that is gone")
    func doesNotRecreateADeletedProject() async throws {
        let store = try makeTestStore("repo-isolation")
        let repo = try await seed(store)
        try await store.deleteRepo(id: repo.id)

        let result = try await store.update(repoID: repo.id) { $0.name = "back from the dead" }

        #expect(result == nil)
        #expect(try await store.repos().isEmpty)
    }

    @Test("a write cannot change which project it is")
    func cannotChangeIdentity() async throws {
        let store = try makeTestStore("repo-isolation")
        let repo = try await seed(store)

        try await store.update(repoID: repo.id) {
            $0.id = RepoID("some-other-id")
            $0.name = "renamed"
        }

        let stored = try #require(try await store.repo(id: repo.id))
        #expect(stored.id == repo.id)
        #expect(stored.name == "renamed")
        #expect(try await store.repos().count == 1)
    }

    /// Why `upsert` is for creating a project and nothing else, stated as a test so that anyone
    /// tempted to reach for it again can read what it does. Everything a project row holds comes
    /// from the value handed in, so a copy read before the icon was found writes the icon away.
    @Test("a whole-value write from a copy read earlier loses whatever landed since")
    func wholeValueWriteIsWhyUpdateExists() async throws {
        let store = try makeTestStore("repo-isolation")
        let repo = try await seed(store)
        // What a view holds, drawn before the icon existed.
        let held = repo

        try await store.update(repoID: repo.id) {
            $0.iconPath = "/p/icon.png"
            $0.iconSource = .detected
        }
        try await store.upsert(held.with { $0.accent = "FF3B30" })

        let stored = try #require(try await store.repo(id: repo.id))
        #expect(stored.accent == "FF3B30")
        #expect(stored.iconPath == nil)
        #expect(stored.iconSource == .undetected)
    }
}
