import Testing
import Foundation
@testable import BloomCore

/// The schema change behind Ask Bloom: `sessions.workspace_id` is nullable, which took the first
/// table rebuild `Store.migrate` has ever done.
///
/// Two things are worth a test here and they are not the same thing. One is the new shape: a chat
/// row with no worktree can be written, read back and kept out of every list that is about a
/// worktree. The other is the rebuild itself, which drops a table four others cascade from, and
/// which would have taken the whole transcript with it had foreign keys been left on. That one is
/// tested against a database put back into the old shape by hand, because a migration nobody ever
/// runs over real rows is a migration that has not been tested.
@Suite("A chat with no workspace", .tags(.persistence), .scratchDirectory)
struct SessionWithoutWorkspaceTests {
    /// The columns as they were before the rebuild, `NOT NULL` and all. Written out rather than
    /// derived, because a test that builds the old shape out of the new one proves nothing.
    private static let oldSessionsTable = """
        CREATE TABLE sessions_old (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            agent_session_id TEXT,
            model TEXT NOT NULL DEFAULT 'opus',
            effort TEXT NOT NULL DEFAULT 'high',
            agent_kind TEXT NOT NULL DEFAULT 'claudeCode',
            permission_mode TEXT NOT NULL DEFAULT 'acceptEdits',
            state TEXT NOT NULL DEFAULT 'idle',
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            archived_at REAL,
            last_read_seq INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0,
            context_tokens INTEGER NOT NULL DEFAULT 0
        );

        INSERT INTO sessions_old SELECT
            id, workspace_id, title, agent_session_id, model, effort, agent_kind,
            permission_mode, state, sort_order, created_at, updated_at, archived_at,
            last_read_seq, input_tokens, output_tokens, cost_usd, context_tokens
        FROM sessions;

        DROP TABLE sessions;
        ALTER TABLE sessions_old RENAME TO sessions;
        CREATE INDEX IF NOT EXISTS sessions_workspace ON sessions(workspace_id);
        """

    private func isNullable(_ path: String) throws -> Bool {
        let raw = try SQLiteDatabase(path: path)
        let column = try raw.query("PRAGMA table_info(sessions);")
            .first { $0.string("name") == "workspace_id" }
        return column?.int("notnull") == 0
    }

    @Test("a chat with no worktree round-trips")
    func roundTrips() async throws {
        let store = try makeTestStore("ask-session")
        let session = try await store.upsert(Session(workspaceID: nil, title: "Ask Bloom"))

        let loaded = try #require(try await store.session(id: session.id))
        #expect(loaded.workspaceID == nil)
        #expect(loaded.title == "Ask Bloom")
    }

    @Test("it is invisible to every list that is about a worktree")
    func invisibleToWorkspaceLists() async throws {
        let store = try makeTestStore("ask-invisible")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/r-w", baseBranch: "main"
        ))
        let inWorktree = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let ask = try await store.upsert(Session(workspaceID: nil, title: "Ask Bloom"))

        #expect(try await store.sessions(workspaceID: workspace.id).map(\.id) == [inWorktree.id])
        #expect(try await store.sessionsWithoutWorkspace().map(\.id) == [ask.id])
    }

    /// `sessionActivity` joins the workspaces table, so a running Ask chat is not in it. That is
    /// the right answer rather than a gap: the sidebar mirror it feeds is a list of worktrees, and
    /// the Ask row draws its own state off the transcript it is holding.
    @Test("a running chat with no worktree stays out of the workspace activity mirror")
    func staysOutOfActivity() async throws {
        let store = try makeTestStore("ask-activity")
        var ask = Session(workspaceID: nil, title: "Ask Bloom")
        ask.apply(.turnStarted)
        _ = try await store.upsert(ask)

        #expect(try await store.sessionActivity().isEmpty)
        #expect(try await store.session(id: ask.id)?.state == .running)
    }

    /// The one that matters. `DROP TABLE sessions` with foreign keys enforced performs an implicit
    /// delete that cascades into `messages`, so this puts a populated database back into the old
    /// shape, rewinds `user_version` and reopens it: the transcript has to still be there
    /// afterwards, and the column has to have been relaxed.
    @Test("the rebuild relaxes the column without taking the transcript with it")
    func rebuildKeepsMessages() async throws {
        let path = TestScratch.unique("ask-rebuild") + ".sqlite"
        let store = try Store(path: path)
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/r-w", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        for index in 0..<5 {
            _ = try await store.appendNext(
                sessionID: session.id, kind: .user, payload: Data("line \(index)".utf8)
            )
        }

        let raw = try SQLiteDatabase(path: path)
        // Off for the same reason the migration turns them off: with them on, the drop below is
        // the very cascade this test exists to catch.
        try raw.execute("PRAGMA foreign_keys = OFF;")
        try raw.execute(Self.oldSessionsTable)
        raw.userVersion = 0
        #expect(try isNullable(path) == false)

        let reopened = try Store(path: path)
        #expect(try isNullable(path))
        #expect(try await reopened.messageCount(sessionID: session.id) == 5)
        #expect(try await reopened.session(id: session.id)?.title == "Chat")
        #expect(try await reopened.sessions(workspaceID: workspace.id).count == 1)

        // And the point of the whole exercise.
        let ask = try await reopened.upsert(Session(workspaceID: nil, title: "Ask Bloom"))
        #expect(try await reopened.sessionsWithoutWorkspace().map(\.id) == [ask.id])
    }

    /// Replayable, like every other step in the list: a rewound `user_version` over a database
    /// that has already been rebuilt runs the step again and it does nothing.
    @Test("replaying the migration over the new shape changes nothing")
    func replaysOverTheNewShape() async throws {
        let path = TestScratch.unique("ask-replay") + ".sqlite"
        let store = try Store(path: path)
        let ask = try await store.upsert(Session(workspaceID: nil, title: "Ask Bloom"))
        _ = try await store.appendNext(sessionID: ask.id, kind: .user, payload: Data("hello".utf8))

        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        #expect(try isNullable(path))
        #expect(try await reopened.sessionsWithoutWorkspace().map(\.id) == [ask.id])
        #expect(try await reopened.messageCount(sessionID: ask.id) == 1)
    }
}
