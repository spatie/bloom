import Foundation
import Testing
@testable import BloomCore

/// Hiding a project, which narrows one list and is not allowed to mean anything else.
@Suite("Hidden projects")
struct ProjectVisibilityTests {
    private let flare = Repo(name: "flare", path: "/Users/me/dev/flare", sortOrder: 0)
    private let bloom = Repo(name: "bloom", path: "/Users/me/dev/bloom", sortOrder: 1, hidden: true)
    private let site = Repo(name: "site", path: "/Users/me/dev/site", sortOrder: 2)

    @Test("a hidden project is left out of the list unless it is asked for")
    func filtering() {
        #expect(ProjectVisibility.listed([flare, bloom, site], showingHidden: false).map(\.name)
            == ["flare", "site"])
        #expect(ProjectVisibility.listed([flare, bloom, site], showingHidden: true).map(\.name)
            == ["flare", "bloom", "site"])
    }

    /// Sinking them to the bottom would rearrange the pane every time the switch is flipped, and a
    /// project would be in a different place depending on a preference you cannot see from the row
    /// you are looking at.
    @Test("shown hidden projects keep their place in the order rather than sinking")
    func orderIsUntouched() {
        let shown = ProjectVisibility.listed([flare, bloom, site], showingHidden: true)

        #expect(shown.map(\.id) == [flare.id, bloom.id, site.id])
    }

    @Test("the count is what the toggle says out loud")
    func counting() {
        #expect(ProjectVisibility.hiddenCount([flare, bloom, site]) == 1)
        #expect(ProjectVisibility.hiddenCount([flare, site]) == 0)
        #expect(ProjectVisibility.toggleTitle(hiddenCount: 1) == "Show 1 hidden project")
        #expect(ProjectVisibility.toggleTitle(hiddenCount: 4) == "Show 4 hidden projects")
    }

    /// A switch that vanished with the last hidden project could not be turned off, and the next
    /// project hidden would stay in the list looking like a control that did not work.
    @Test("the toggle is still offered, and drops the count, when nothing is hidden")
    func toggleWithNothingHidden() {
        #expect(ProjectVisibility.toggleTitle(hiddenCount: 0) == "Show hidden projects")
    }

    @Test("hiding the last visible project says how to get one back")
    func emptySidebarSaysWhatToDo() {
        let sentence = ProjectVisibility.remainingSentence(visible: 0)

        #expect(sentence.contains("Show hidden projects"))
        #expect(sentence.contains("project_unhide"))
        #expect(ProjectVisibility.remainingSentence(visible: 1).contains("1 project is still"))
    }
}

/// The column behind it, and the two things a write to it must not do.
@Suite("Hidden projects, stored", .tags(.persistence), .scratchDirectory)
struct HiddenProjectStoreTests {
    @Test("hidden survives a round trip and defaults to showing")
    func roundTrip() async throws {
        let store = try makeTestStore("hidden-round-trip")
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare"))
        #expect(!repo.hidden)

        _ = try await store.update(repoID: repo.id) { $0.hidden = true }

        #expect(try await store.repo(id: repo.id)?.hidden == true)
    }

    /// The rule in CLAUDE.md, for the newest column on this table: a write changes the columns it
    /// names and no others. The icon is the one that used to be lost, because it is held across a
    /// walk of the project directory or a whole file panel session.
    @Test("hiding a project writes nothing else, even from a stale copy of the row")
    func hidingIsIsolated() async throws {
        let store = try makeTestStore("hidden-isolated")
        let stale = try await store.upsert(Repo(name: "flare", path: "/tmp/flare"))

        _ = try await store.update(repoID: stale.id) { $0.name = "Flare" }
        _ = try await store.update(repoID: stale.id) {
            $0.iconPath = "/tmp/flare/icon.png"
            $0.iconSource = .chosen
        }
        // The caller is still holding the row as it was before either of those landed.
        _ = try await store.update(repoID: stale.id) { $0.hidden = true }

        let stored = try #require(try await store.repo(id: stale.id))
        #expect(stored.hidden)
        #expect(stored.name == "Flare")
        #expect(stored.iconPath == "/tmp/flare/icon.png")
    }

    /// Every row that existed before this column did is a project the owner can see, which is what
    /// the default says. Replaying the step must neither throw nor reset what is stored.
    @Test("a project written before the column existed reads as showing")
    func migration() async throws {
        let path = TestScratch.unique("hidden-migration") + ".sqlite"
        let store = try Store(path: path)
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare"))
        _ = try await store.update(repoID: repo.id) { $0.hidden = true }

        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        #expect(try await reopened.repo(id: repo.id)?.hidden == true)
        let fresh = try await reopened.upsert(Repo(name: "new", path: "/tmp/new"))
        #expect(!fresh.hidden)
    }
}
