import Foundation
import Testing
@testable import BloomCore

/// The incident this file is about: the owner's database read `user_version = 22`, the length of
/// the migration list, with `sessions.parent_session_id` missing. `migrate` had nothing to run and
/// every query naming that column failed, so the app could not open the database at all.
@Suite("Schema repair", .tags(.persistence), .scratchDirectory)
struct SchemaRepairTests {
    @Test("a column missing from a database that calls itself migrated is put back")
    func repairsAColumnTheStampSaysIsThere() async throws {
        let path = TestScratch.unique("schema-repair") + ".sqlite"
        _ = try Store(path: path)

        // Drop the column behind the store's back, exactly as the state on the owner's machine
        // had it: the table without it, and the version still saying everything has run.
        let raw = try SQLiteDatabase(path: path)
        // The index goes first, because SQLite refuses to drop a column an index names. A database
        // that never ran the migration has neither, which is the state being reproduced.
        try raw.execute("DROP INDEX IF EXISTS sessions_parent;")
        try raw.execute("ALTER TABLE sessions DROP COLUMN parent_session_id;")
        let before = try raw.query("PRAGMA table_info(sessions);")
            .compactMap { $0.string("name") }
        #expect(!before.contains("parent_session_id"))

        // Opening again is what repairs it, without the version number moving.
        let reopened = try Store(path: path)
        let sessions = try await reopened.sessions(workspaceID: WorkspaceID("nothing"))
        #expect(sessions.isEmpty)

        let after = try SQLiteDatabase(path: path)
        let columns = try after.query("PRAGMA table_info(sessions);")
            .compactMap { $0.string("name") }
        #expect(columns.contains("parent_session_id"))
    }
}
