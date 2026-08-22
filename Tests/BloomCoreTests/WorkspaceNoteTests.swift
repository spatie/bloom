import Testing
import Foundation
@testable import BloomCore

/// The workspace notes pane, minus the text field.
///
/// Two things are being held still here. One is the promise the feature makes, which is that a note
/// typed tonight is there in the morning, after the workspace was switched away from, after the app
/// was quit, and after the workspace was archived. The other is the promise it makes to the rest of
/// the database: a pane somebody types in for a minute is the slowest writer in the app, and the
/// last time a slow writer sent a whole workspace row back, the row said a workspace was live over
/// a worktree that had been deleted. See `WorkspaceWriteIsolationTests`.
@Suite("Workspace notes", .tags(.persistence), .scratchDirectory)
struct WorkspaceNoteTests {
    private func seed(_ store: Store) async throws -> Workspace {
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))
        return try await store.upsert(Workspace(
            repoID: repo.id, name: "original", branch: "feature/original",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
    }

    // MARK: - Storage

    @Test("a note comes back as it was typed")
    func roundTrips() async throws {
        let store = try makeTestStore("notes")
        let workspace = try await seed(store)

        try await store.saveNote(workspaceID: workspace.id, body: "check the retry\n\nand the timeout")

        #expect(try await store.note(workspaceID: workspace.id)?.body == "check the retry\n\nand the timeout")
    }

    @Test("a workspace that has never had a note has none")
    func noneByDefault() async throws {
        let store = try makeTestStore("notes")
        let workspace = try await seed(store)

        #expect(try await store.note(workspaceID: workspace.id) == nil)
    }

    /// Blank is not a note. A row holding a stray newline would draw as an empty pane with no
    /// placeholder, which reads as a pane that failed to load what it was holding.
    @Test("emptying a note removes it rather than storing a blank")
    func emptyingRemovesIt() async throws {
        let store = try makeTestStore("notes")
        let workspace = try await seed(store)

        try await store.saveNote(workspaceID: workspace.id, body: "something")
        try await store.saveNote(workspaceID: workspace.id, body: "  \n ")

        #expect(try await store.note(workspaceID: workspace.id) == nil)
    }

    /// Two workspaces open side by side, which is the ordinary way this app is used.
    @Test("a note belongs to one workspace")
    func notesDoNotLeakBetweenWorkspaces() async throws {
        let store = try makeTestStore("notes")
        let first = try await seed(store)
        let second = try await seed(store)

        try await store.saveNote(workspaceID: first.id, body: "first")

        #expect(try await store.note(workspaceID: first.id)?.body == "first")
        #expect(try await store.note(workspaceID: second.id) == nil)
    }

    // MARK: - Lifecycle

    /// The reason to keep it: a note is most often about why the work was abandoned, and archiving
    /// is when it stopped. Archiving moves `state`, it does not remove the row, so the cascade
    /// never fires.
    @Test("archiving a workspace keeps its note")
    func survivesArchiving() async throws {
        let store = try makeTestStore("notes")
        let workspace = try await seed(store)
        try await store.saveNote(workspaceID: workspace.id, body: "gave up on the websocket")

        try await store.update(workspaceID: workspace.id) { $0.archive() }

        #expect(try await store.workspace(id: workspace.id)?.state == .archived)
        #expect(try await store.note(workspaceID: workspace.id)?.body == "gave up on the websocket")
    }

    /// And the reason not to keep it forever: deleting the workspace deletes the note with it,
    /// through the foreign key rather than through anything anybody has to remember to call.
    @Test("deleting a workspace takes its note with it")
    func cascadesOnDelete() async throws {
        let store = try makeTestStore("notes")
        let workspace = try await seed(store)
        try await store.saveNote(workspaceID: workspace.id, body: "gone soon")

        try await store.deleteWorkspace(id: workspace.id)

        #expect(try await store.note(workspaceID: workspace.id) == nil)
    }

    // MARK: - Isolation

    /// The bug this feature was one careless column away from reintroducing. The diff stat refresh
    /// runs every six seconds while somebody sits in the pane typing; saving the note must not put
    /// the counts, the state or the name back to whatever they were when the pane opened.
    @Test("saving a note leaves the workspace row alone")
    func doesNotWriteTheWorkspaceRow() async throws {
        let store = try makeTestStore("notes")
        let workspace = try await seed(store)

        // Everything a note-writing user is sitting on top of, happening while they type.
        try await store.updateDiffStat(workspaceID: workspace.id, additions: 12, deletions: 3, files: 2)
        try await store.update(workspaceID: workspace.id) { $0.name = "renamed by the namer" }
        try await store.saveNote(workspaceID: workspace.id, body: "typed over the top of all that")

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.additions == 12)
        #expect(stored.deletions == 3)
        #expect(stored.changedFiles == 2)
        #expect(stored.name == "renamed by the namer")
    }

    // MARK: - The save policy

    @Test("identical text is not worth a write")
    func skipsAnUnchangedNote() {
        #expect(!WorkspaceNote.needsSave(stored: "same", typed: "same"))
        #expect(WorkspaceNote.needsSave(stored: "same", typed: "same "))
        #expect(WorkspaceNote.needsSave(stored: "", typed: "new"))
    }

    /// Whitespace and nothing are the same note, so backspacing the last character of a note down
    /// to a newline is not a write and reopening the pane is not a surprise.
    @Test("blank text and no text are the same note")
    func blankIsNothing() {
        #expect(!WorkspaceNote.needsSave(stored: "", typed: "  \n\t "))
        #expect(WorkspaceNote.storable(" \n ").isEmpty)
        #expect(WorkspaceNote.storable("a\n") == "a\n")
    }

    // MARK: - The composer

    @Test("a note goes to the composer as written, without its surrounding whitespace")
    func handsOffWhatWasWritten() {
        #expect(WorkspaceNote.handoff("\nfix the retry\n\n") == "fix the retry")
        #expect(WorkspaceNote.handoff("  \n ") == nil)
        #expect(WorkspaceNote.handoff("") == nil)
    }
}
