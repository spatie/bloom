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

/// The rule that takes a project back out of hiding, which is the one thing hiding does not
/// survive: a workspace being added to the project.
@Suite("A project that comes back")
struct ProjectReturnTests {
    @Test("a hidden project comes back and a showing one is left where it is")
    func theRule() {
        let hidden = Repo(name: "bloom", path: "/Users/me/dev/bloom", hidden: true)
        let showing = Repo(name: "flare", path: "/Users/me/dev/flare")

        #expect(ProjectVisibility.comesBack(hidden))
        #expect(!ProjectVisibility.comesBack(showing))
    }

    /// A create racing a project removal ends here. There is no sidebar row to bring back and
    /// nothing to write to.
    @Test("a project that is no longer in the database is not brought back")
    func aProjectThatHasGone() {
        #expect(!ProjectVisibility.comesBack(nil))
    }
}

/// The write behind that rule. Both halves matter: which columns move, and whether anything is
/// written at all.
@Suite("A project that comes back, written", .tags(.persistence), .scratchDirectory)
struct ProjectReturnStoreTests {
    @Test("the flag is cleared and no other column moves with it")
    func writesOneColumn() async throws {
        let store = try makeTestStore("comes-back")
        let manager = WorkspaceManager(store: store)
        let project = try await store.upsert(
            Repo(name: "bloom", path: "/tmp/bloom", sortOrder: 3, hidden: true)
        )
        // Everything a slower writer could have landed on this row while a worktree was being
        // cut, none of which a project coming back is allowed to carry away.
        _ = try await store.update(repoID: project.id) {
            $0.name = "Bloom"
            $0.iconPath = "/tmp/bloom/icon.png"
            $0.iconSource = .chosen
        }

        #expect(await manager.bringProjectBack(project.id))

        let stored = try #require(try await store.repo(id: project.id))
        #expect(!stored.hidden)
        #expect(stored.name == "Bloom")
        #expect(stored.iconPath == "/tmp/bloom/icon.png")
        // Its place in the sidebar's order is not something coming back changes either.
        #expect(stored.sortOrder == 3)
    }

    /// `update` writes every time it is called and the store announces every commit, so a project
    /// that is already showing must not be written at all: an unconditional write would wake every
    /// subscriber of `repos` on every workspace ever created, to say nothing.
    @Test("a project that is already showing is not written")
    func showingProjectIsLeftAlone() async throws {
        let store = try makeTestStore("comes-back-showing")
        let manager = WorkspaceManager(store: store)
        let project = try await store.upsert(Repo(name: "flare", path: "/tmp/flare"))

        #expect(await manager.bringProjectBack(project.id) == false)
        #expect(try await store.repo(id: project.id)?.hidden == false)
    }

    @Test("a project that is no longer stored is not brought back")
    func missingProjectIsNotWritten() async throws {
        let manager = WorkspaceManager(store: try makeTestStore("comes-back-missing"))

        #expect(await manager.bringProjectBack(RepoID.new()) == false)
    }
}

/// The two places a workspace arrives in a project's list, against a real repository.
@Suite(
    "A project that comes back, in the routes that add a workspace",
    .tags(.git), .scratchDirectory
)
struct ProjectReturnRouteTests {
    private func makeManager(
        _ label: String
    ) async throws -> (repo: TempRepo, registered: Repo, manager: WorkspaceManager, store: Store) {
        let repo = try await TempRepo()
        let store = try makeTestStore(label)
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        return (repo, registered, manager, store)
    }

    /// The case the whole change is for: something on the bridge asks for a workspace in a project
    /// the sidebar is leaving out, and the row it makes would be in no list anybody is looking at.
    ///
    /// The `Repo` handed to `start` is the copy read before the project was hidden, deliberately,
    /// because a stale copy is what every real caller holds. The stored row is what decides.
    @Test("starting a workspace in a hidden project brings it back, and says so")
    func startingBringsTheProjectBack() async throws {
        let (repo, registered, manager, store) = try await makeManager("comes-back-start")
        defer { repo.cleanUp() }
        _ = try await store.update(repoID: registered.id) { $0.hidden = true }

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered,
            prompt: "Fix the flaky test",
            origin: .ownerClient(spawnToolUseID: "toolu_1"),
            opensSession: false
        ))

        #expect(started.projectCameBack)
        #expect(try await store.repo(id: registered.id)?.hidden == false)
        #expect(ProjectVisibility.listed(try await store.repos(), showingHidden: false).count == 1)
        #expect(try await store.workspaces().map(\.id) == [started.workspace.id])
    }

    @Test("starting a workspace in a project that is showing reports nothing")
    func startingInAShowingProjectReportsNothing() async throws {
        let (repo, registered, manager, store) = try await makeManager("comes-back-start-showing")
        defer { repo.cleanUp() }

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Fix the flaky test", origin: .user, opensSession: false
        ))

        #expect(started.projectCameBack == false)
        #expect(try await store.repo(id: registered.id)?.hidden == false)
    }

    /// A restore counts. The row already existed, but it was in no project's list a moment ago and
    /// is in one now, and the caller selects it: a selected row inside a hidden project is a
    /// selection the sidebar cannot draw.
    @Test(
        "restoring an archived workspace into a hidden project brings it back",
        .tags(.destructive)
    )
    func restoringBringsTheProjectBack() async throws {
        let (repo, registered, manager, store) = try await makeManager("comes-back-restore")
        defer { repo.cleanUp() }
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Archive me")

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)
        _ = try await store.update(repoID: registered.id) { $0.hidden = true }

        try await manager.restore(workspace: workspace, repo: registered)

        #expect(try await store.repo(id: registered.id)?.hidden == false)
        #expect(try await store.workspaces().contains { $0.id == workspace.id })
    }
}
