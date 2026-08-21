import Foundation
import Synchronization

/// All persistence. One actor, one SQLite file.
///
/// One rule runs through every table here, and it is worth reading before adding a column or a
/// write. **`upsert` creates a row. `update` modifies one.** An `upsert` writes every column from
/// the value it is handed, so it is correct only when that value was built here and now; hand it
/// something read a few seconds ago and it carries every column back to what it looked like then.
/// `update(workspaceID:)`, `update(repoID:)` and `update(sessionID:)` each read the row inside
/// this actor, apply the change, and write, with no suspension in between, so a write changes
/// what it named and nothing else. Where one writer owns a fixed set of columns, it gets a method
/// that names them: `updateDiffStat`, `touch`, `updateSetup`, `updateSessionPreferences`,
/// `reorderSessions`, `updateLastReadSeq`.
///
/// This is not tidiness. These rows have several writers running at wildly different speeds: a
/// diff stat refresh every six seconds, an archive that takes seconds of disk work before it can
/// say so, an open panel somebody spends a minute in, an agent turn that runs for ten minutes.
/// Whole-value writes from any of them silently rolled the others back, and the damage ranged
/// from a stale count through a project losing its icon to a workspace whose row said it was live
/// after its worktree had been deleted. A column added to a model is picked up by `update`
/// automatically; reach for `upsert` on an existing row and it is reintroduced.
public actor Store {
    private let db: SQLiteDatabase
    public nonisolated let path: String

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Bloom", isDirectory: true)
    }

    private static let migrationOutcome = Mutex<LegacyDatabase.Outcome?>(nil)

    /// What the move out of the old directory decided, for whoever wants to report it. Behind a
    /// lock because `defaultPath` is called by the app on launch and again by an App Intent
    /// performed in the same process, and those two are not ordered.
    public static var lastMigration: LegacyDatabase.Outcome? {
        migrationOutcome.withLock { $0 }
    }

    public static func defaultPath() throws -> String {
        // An override exists so a throwaway instance (a snapshot run, a manual experiment) can be
        // pointed at its own database instead of the one holding the user's real workspaces.
        let environment = ProcessInfo.processInfo.environment
        let override = [environment["BLOOM_DB_PATH"]].compactMap { $0 }
            .first { !$0.isEmpty }
        if let override {
            let directory = (override as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            return override
        }

        let directory = defaultDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("bloom.sqlite")

        let outcome = LegacyDatabase.adopt(destination: destination)
        migrationOutcome.withLock { $0 = outcome }
        return outcome.path
    }

    public init(path: String) throws {
        self.path = path
        self.db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
    }

    public static func inMemory() throws -> Store {
        try Store(path: ":memory:")
    }

    // MARK: - Migrations

    /// One migration step. Most are a block of SQL, but a step that has to look at the rows it is
    /// about to constrain needs real code, so the list holds closures rather than strings.
    private typealias Migration = @Sendable (SQLiteDatabase) throws -> Void

    private nonisolated static func sql(_ statements: String) -> Migration {
        { try $0.execute(statements) }
    }

    private nonisolated static func migrate(_ db: SQLiteDatabase) throws {
        let migrations: [Migration] = [
            sql("""
            CREATE TABLE IF NOT EXISTS repos (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                default_branch TEXT NOT NULL DEFAULT 'main',
                accent TEXT NOT NULL DEFAULT '4C8DF6',
                sort_order INTEGER NOT NULL DEFAULT 0,
                collapsed INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspaces (
                id TEXT PRIMARY KEY,
                repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                branch TEXT NOT NULL,
                path TEXT NOT NULL,
                base_branch TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'active',
                setup_state TEXT NOT NULL DEFAULT 'pending',
                setup_log TEXT NOT NULL DEFAULT '',
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                last_activity_at REAL NOT NULL,
                archived_at REAL,
                additions INTEGER NOT NULL DEFAULT 0,
                deletions INTEGER NOT NULL DEFAULT 0,
                changed_files INTEGER NOT NULL DEFAULT 0,
                unread INTEGER NOT NULL DEFAULT 0,
                pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS workspaces_repo ON workspaces(repo_id, state);

            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                agent_session_id TEXT,
                model TEXT NOT NULL DEFAULT 'opus',
                effort TEXT NOT NULL DEFAULT 'high',
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
            CREATE INDEX IF NOT EXISTS sessions_workspace ON sessions(workspace_id);

            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                seq INTEGER NOT NULL,
                kind TEXT NOT NULL,
                payload BLOB NOT NULL,
                created_at REAL NOT NULL,
                duration_ms INTEGER,
                ref_id TEXT
            );
            CREATE INDEX IF NOT EXISTS messages_session ON messages(session_id, seq);
            CREATE INDEX IF NOT EXISTS messages_ref ON messages(session_id, ref_id);

            CREATE TABLE IF NOT EXISTS terminal_tabs (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS drafts (
                session_id TEXT PRIMARY KEY,
                body TEXT NOT NULL
            );
            """),

            // A transcript position belongs to exactly one row. Without this the database happily
            // accepted two rows claiming seq 4, which reorders a transcript and makes
            // `last_read_seq` point at whichever of them the query felt like returning.
            //
            // An existing database can already hold such a pair, and a unique index would refuse
            // to build over it, so the duplicates are moved to the end of their session first.
            // Renumbering rather than deleting: a row that made it to disk is transcript, and the
            // position it claimed was never trustworthy anyway.
            { db in
                let duplicates = try db.query("""
                    SELECT id, session_id FROM messages
                    WHERE id NOT IN (SELECT MIN(id) FROM messages GROUP BY session_id, seq)
                    ORDER BY session_id, id
                    """)

                var nextBySession: [String: Int64] = [:]
                for row in duplicates {
                    guard let id = row.int("id"), let sessionID = row.string("session_id") else { continue }
                    let seq: Int64
                    if let known = nextBySession[sessionID] {
                        seq = known
                    } else {
                        seq = (try db.query(
                            "SELECT COALESCE(MAX(seq), -1) AS m FROM messages WHERE session_id = ?",
                            [.text(sessionID)]
                        ).first?.int("m") ?? -1) + 1
                    }
                    try db.run("UPDATE messages SET seq = ? WHERE id = ?", [.int(seq), .int(id)])
                    nextBySession[sessionID] = seq + 1
                }

                try db.execute(
                    "CREATE UNIQUE INDEX IF NOT EXISTS messages_session_seq ON messages(session_id, seq);"
                )
            },

            // Inline review comments. In the database rather than user defaults because they are
            // per-workspace working state, there can be dozens of them per review, and they have to
            // die with the workspace, which the foreign key does for free.
            //
            // The anchor is spread over four columns rather than stored as one JSON blob: line and
            // file are the two things every query filters or orders by, and burying them in JSON
            // would mean reading every row of a workspace to draw one file's gutter.
            sql("""
            CREATE TABLE IF NOT EXISTS review_comments (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                file_path TEXT NOT NULL,
                side TEXT NOT NULL DEFAULT 'new',
                line INTEGER NOT NULL,
                line_text TEXT NOT NULL DEFAULT '',
                context_before TEXT NOT NULL DEFAULT '[]',
                context_after TEXT NOT NULL DEFAULT '[]',
                body TEXT NOT NULL,
                created_at REAL NOT NULL,
                attached INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS review_comments_workspace
                ON review_comments(workspace_id, file_path, line);
            """),

            // The mark a project is drawn with. Two columns rather than one, because a project
            // with no icon and a project nobody has looked for an icon for want the same monogram
            // and must not be treated the same: only the second is a candidate for detection.
            //
            // Existing rows land on `undetected`, which is exactly what they are, and which is
            // what stops an upgrade from silently redrawing a sidebar somebody is used to.
            //
            // Real code rather than SQL because `ADD COLUMN` has no `IF NOT EXISTS`, and every
            // other step in this list can be replayed over a database that already had it applied.
            // A step that could not would turn a rewound `user_version`, which is how the store's
            // own tests reproduce an old schema, into a migration that throws.
            { db in
                let existing = Set(try db.query("PRAGMA table_info(repos);").compactMap { $0.string("name") })
                if !existing.contains("icon_path") {
                    try db.execute("ALTER TABLE repos ADD COLUMN icon_path TEXT;")
                }
                if !existing.contains("icon_source") {
                    try db.execute(
                        "ALTER TABLE repos ADD COLUMN icon_source TEXT NOT NULL DEFAULT 'undetected';"
                    )
                }
            },

            // Permission prompting: what the user granted, and what is still waiting on them.
            //
            // Two tables because they have opposite lifetimes. A grant outlives every session and
            // every worktree, which is the whole point of it; a pending ask cannot outlive the
            // process that is blocked on it, and dies with the session.
            //
            // `permission_grants` is keyed by repository rather than by workspace. A workspace is
            // a git worktree, so anything kept beside the working directory is deleted along with
            // it, and a rule granted "always" would quietly stop applying. The unique index is
            // what makes granting the same rule twice a no-op rather than a second row nobody can
            // tell from the first: `rule_content` is nullable and SQLite treats NULLs as distinct
            // in a unique index, so the whole-tool case is stored as an empty string instead and
            // read back as nil.
            //
            // `permission_asks` holds the whole control request as it arrived, so a workspace
            // reopened while its agent is still blocked can draw the question rather than an empty
            // space. `resolved_at` and `decision` are the answer; both null means still waiting.
            sql("""
            CREATE TABLE IF NOT EXISTS permission_grants (
                id TEXT PRIMARY KEY,
                repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
                tool_name TEXT NOT NULL,
                rule_content TEXT NOT NULL DEFAULT '',
                granted_at REAL NOT NULL,
                last_used_at REAL,
                use_count INTEGER NOT NULL DEFAULT 0,
                granted_for TEXT NOT NULL DEFAULT ''
            );
            CREATE UNIQUE INDEX IF NOT EXISTS permission_grants_rule
                ON permission_grants(repo_id, tool_name, rule_content);

            CREATE TABLE IF NOT EXISTS permission_asks (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                tool_use_id TEXT NOT NULL DEFAULT '',
                payload BLOB NOT NULL,
                created_at REAL NOT NULL,
                resolved_at REAL,
                decision TEXT
            );
            CREATE INDEX IF NOT EXISTS permission_asks_pending
                ON permission_asks(session_id, resolved_at);
            """),

            // Which CLI drives a chat.
            //
            // On the session rather than on the workspace, because the backend belongs to the
            // conversation: one worktree can hold a Claude Code chat and a Codex one at the same
            // time. Every row that exists when this runs is a Claude Code chat, and the default
            // says so rather than leaving a column nothing can read.
            //
            // Real code rather than SQL because `ADD COLUMN` has no `IF NOT EXISTS`, and every
            // step in this list has to be replayable over a database that already has it applied:
            // the store's own tests rewind `user_version` to reproduce an old schema, and a step
            // that could not be replayed would turn that into a migration that throws.
            { db in
                let existing = Set(
                    try db.query("PRAGMA table_info(sessions);").compactMap { $0.string("name") }
                )
                if !existing.contains("agent_kind") {
                    try db.execute(
                        "ALTER TABLE sessions ADD COLUMN agent_kind TEXT NOT NULL DEFAULT 'claudeCode';"
                    )
                }
            },

            // A colour the user put on a workspace so they can find it again in a long list.
            //
            // Nullable, with no default, because no colour is the normal case and has to stay
            // distinguishable from a colour somebody chose. A `NOT NULL DEFAULT` here would mean
            // every workspace that ever existed is marked, and the sidebar would have to guess
            // which of them meant it.
            //
            // Real code rather than SQL for the same reason the two steps above are: `ADD COLUMN`
            // has no `IF NOT EXISTS`, and the store's own tests rewind `user_version` to reproduce
            // an old schema, so a step that could not be replayed would throw and take the whole
            // migration transaction with it.
            { db in
                let existing = Set(
                    try db.query("PRAGMA table_info(workspaces);").compactMap { $0.string("name") }
                )
                if !existing.contains("colour") {
                    try db.execute("ALTER TABLE workspaces ADD COLUMN colour TEXT;")
                }
            },
        ]

        let current = Int(db.userVersion)
        guard current < migrations.count else { return }
        // One transaction for the lot: a migration that half ran would leave a schema no version
        // number describes.
        try db.transaction {
            for index in current..<migrations.count {
                try migrations[index](db)
            }
            db.userVersion = Int32(migrations.count)
        }
    }

    // MARK: - Repos

    public func repos() throws -> [Repo] {
        try db.query("SELECT * FROM repos ORDER BY sort_order, created_at").map(Self.repo(from:))
    }

    public func repo(id: String) throws -> Repo? {
        try db.query("SELECT * FROM repos WHERE id = ?", [.text(id)]).first.map(Self.repo(from:))
    }

    public func repo(path: String) throws -> Repo? {
        try db.query("SELECT * FROM repos WHERE path = ?", [.text(path)]).first.map(Self.repo(from:))
    }

    /// Writes a whole project row. This is how a project is added, and it is worth reaching for
    /// only when the value being written was built here and now.
    ///
    /// Changing something about a project that already exists is `update(repoID:_:)` instead.
    /// Every column in the conflict clause below is written from the value handed in, so a value
    /// read a few seconds ago carries all of them back to what they were then, `icon_path` and
    /// `icon_source` included. See `update` for what that costs.
    @discardableResult
    public func upsert(_ repo: Repo) throws -> Repo {
        try db.run(
            """
            INSERT INTO repos (
                id, name, path, default_branch, accent, sort_order, collapsed, created_at,
                icon_path, icon_source
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                path = excluded.path,
                default_branch = excluded.default_branch,
                accent = excluded.accent,
                sort_order = excluded.sort_order,
                collapsed = excluded.collapsed,
                icon_path = excluded.icon_path,
                icon_source = excluded.icon_source
            """,
            [
                .text(repo.id), .text(repo.name), .text(repo.path), .text(repo.defaultBranch),
                .text(repo.accent), .int(Int64(repo.sortOrder)), .int(repo.collapsed ? 1 : 0),
                .double(repo.createdAt.timeIntervalSince1970),
                repo.iconPath.map { SQLValue.text($0) } ?? .null,
                .text(repo.iconSource.rawValue),
            ]
        )
        return repo
    }

    /// Changes an existing project without writing the columns it did not mean to change.
    ///
    /// `update(workspaceID:_:)` one table over, for the same reason and built the same way: the
    /// row is read here, inside the actor, immediately before it is written back, and neither
    /// SQLite call suspends, so nothing can write between them.
    ///
    /// The `repos` table has five writers and they hold their copy of the row for very different
    /// lengths of time. Collapsing a project's section and renaming it are quick. The accent well
    /// writes on every distinct colour of a drag. The icon is the slow one: "Find icon" holds its
    /// value across a walk of the project directory, and "Choose icon" holds it across a whole
    /// `NSOpenPanel` session, which is as long as somebody takes to find a file. Whichever of
    /// them wrote last used to put every column back to what it had seen, so the project quietly
    /// lost the icon Bloom had just found for it, or got its old name back, or its old colour.
    ///
    /// Identity is not the caller's to move: `id` is pinned after the change runs, and
    /// `created_at` is not in `upsert`'s conflict clause at all. `path` is, because a project can
    /// legitimately be pointed somewhere else, so it stays something a caller can name.
    ///
    /// Returns nil when there is no such row rather than inserting one.
    @discardableResult
    public func update(
        repoID: String,
        _ change: @Sendable (inout Repo) -> Void
    ) throws -> Repo? {
        guard var row = try repo(id: repoID) else { return nil }
        change(&row)
        row.id = repoID
        return try upsert(row)
    }

    public func deleteRepo(id: String) throws {
        try db.run("DELETE FROM repos WHERE id = ?", [.text(id)])
    }

    // MARK: - Workspaces

    public func workspaces(includeArchived: Bool = false) throws -> [Workspace] {
        let sql = includeArchived
            ? "SELECT * FROM workspaces ORDER BY sort_order, created_at"
            : "SELECT * FROM workspaces WHERE state = 'active' ORDER BY sort_order, created_at"
        return try db.query(sql).map(Self.workspace(from:))
    }

    public func workspaces(repoID: String, includeArchived: Bool = false) throws -> [Workspace] {
        let sql = includeArchived
            ? "SELECT * FROM workspaces WHERE repo_id = ? ORDER BY sort_order, created_at"
            : "SELECT * FROM workspaces WHERE repo_id = ? AND state = 'active' ORDER BY sort_order, created_at"
        return try db.query(sql, [.text(repoID)]).map(Self.workspace(from:))
    }

    public func workspace(id: String) throws -> Workspace? {
        try db.query("SELECT * FROM workspaces WHERE id = ?", [.text(id)]).first.map(Self.workspace(from:))
    }

    /// Writes a whole workspace row. This is how a workspace is created, and it is worth reaching
    /// for only when the value being written was built here and now.
    ///
    /// Changing something about a workspace that already exists is `update(workspaceID:_:)`
    /// instead. Everything in the conflict clause below is written from the value handed in, so a
    /// value read a few seconds ago carries every column back to what it was then, including
    /// `state`. See `update` for what that cost.
    @discardableResult
    public func upsert(_ workspace: Workspace) throws -> Workspace {
        try db.run(
            """
            INSERT INTO workspaces (
                id, repo_id, name, branch, path, base_branch, state, setup_state, setup_log,
                sort_order, created_at, last_activity_at, archived_at,
                additions, deletions, changed_files, unread, pinned, colour
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                branch = excluded.branch,
                path = excluded.path,
                base_branch = excluded.base_branch,
                state = excluded.state,
                setup_state = excluded.setup_state,
                setup_log = excluded.setup_log,
                sort_order = excluded.sort_order,
                last_activity_at = excluded.last_activity_at,
                archived_at = excluded.archived_at,
                additions = excluded.additions,
                deletions = excluded.deletions,
                changed_files = excluded.changed_files,
                unread = excluded.unread,
                pinned = excluded.pinned,
                colour = excluded.colour
            """,
            [
                .text(workspace.id), .text(workspace.repoID), .text(workspace.name),
                .text(workspace.branch), .text(workspace.path), .text(workspace.baseBranch),
                .text(workspace.state.rawValue), .text(workspace.setupState.rawValue),
                .text(workspace.setupLog), .int(Int64(workspace.sortOrder)),
                .double(workspace.createdAt.timeIntervalSince1970),
                .double(workspace.lastActivityAt.timeIntervalSince1970),
                workspace.archivedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .int(Int64(workspace.additions)), .int(Int64(workspace.deletions)),
                .int(Int64(workspace.changedFiles)),
                .int(workspace.unread ? 1 : 0), .int(workspace.pinned ? 1 : 0),
                workspace.colour.map { .text($0) } ?? .null,
            ]
        )
        return workspace
    }

    /// Changes an existing workspace without writing the columns it did not mean to change.
    ///
    /// The row is read here, inside the actor, immediately before it is written back, so what
    /// lands in the database is the row as it stands now with one change applied, rather than a
    /// copy somebody read at some earlier moment. Neither SQLite call suspends and `Store` is an
    /// actor, so nothing can write between the two.
    ///
    /// That is the point of it, and it is not a style preference. Every writer of this table used
    /// to send a whole `Workspace` value it had been holding: the sidebar's pin, the rename, the
    /// drag that reorders rows, the archive itself. Meanwhile the diff stat refresh writes to
    /// every row every six seconds, a finishing turn writes `last_activity_at` and `unread`, and
    /// a setup script writes its outcome minutes after it started. Anything landing between such
    /// a read and its write was silently rolled back by the write.
    ///
    /// The archive is what made this worth fixing rather than noting, in both directions. Its own
    /// write carried every column back across the seconds it spent on disk, so the mark saying a
    /// turn finished unseen, the time it finished at and the counts were rolled back on every
    /// archive. And `state` is a column like any other, so a writer that had read the row before
    /// the archive and wrote after it put `active` back over `archived`. Automatic naming is that
    /// writer: it re-reads, renames the branch with `git`, and writes, and the archive finishing
    /// inside that gap left a workspace whose worktree is gone and whose row says it is live.
    /// Unlike a stale count, that one does not heal. It is still there after a relaunch.
    ///
    /// `updateDiffStat`, `touch` and `updateSetup` are the same rule written out column by column
    /// for the three writers that already had it. This is the rule itself, so a column added to
    /// `Workspace` next year does not quietly reopen the hole for everybody else.
    ///
    /// Identity is not the caller's to move: `id` is pinned after the change runs, and `repo_id`
    /// and `created_at` are not in `upsert`'s conflict clause at all.
    ///
    /// Returns nil when there is no such row rather than inserting one. Creating a workspace is
    /// `upsert`, and that is the only thing `upsert` should be reached for.
    @discardableResult
    public func update(
        workspaceID: String,
        _ change: @Sendable (inout Workspace) -> Void
    ) throws -> Workspace? {
        guard var row = try workspace(id: workspaceID) else { return nil }
        change(&row)
        row.id = workspaceID
        return try upsert(row)
    }

    public func deleteWorkspace(id: String) throws {
        try db.run("DELETE FROM workspaces WHERE id = ?", [.text(id)])
    }

    public func updateDiffStat(workspaceID: String, additions: Int, deletions: Int, files: Int) throws {
        try db.run(
            "UPDATE workspaces SET additions = ?, deletions = ?, changed_files = ? WHERE id = ?",
            [.int(Int64(additions)), .int(Int64(deletions)), .int(Int64(files)), .text(workspaceID)]
        )
    }

    public func touch(workspaceID: String, unread: Bool? = nil) throws {
        if let unread {
            try db.run(
                "UPDATE workspaces SET last_activity_at = ?, unread = ? WHERE id = ?",
                [.double(Date().timeIntervalSince1970), .int(unread ? 1 : 0), .text(workspaceID)]
            )
        } else {
            try db.run(
                "UPDATE workspaces SET last_activity_at = ? WHERE id = ?",
                [.double(Date().timeIntervalSince1970), .text(workspaceID)]
            )
        }
    }

    /// A setup script can run for minutes, and everything else that touches the workspace keeps
    /// writing during those minutes: renames, pinning, diff stats, activity. Writing the whole
    /// `Workspace` value the run started with would roll all of that back, which is the bug
    /// `updateSessionPreferences` exists to avoid on the sessions table. So the setup run owns
    /// exactly these two columns and touches nothing else.
    public func updateSetup(workspaceID: String, state: SetupState, log: String? = nil) throws {
        try db.run(
            "UPDATE workspaces SET setup_state = ?, setup_log = COALESCE(?, setup_log) WHERE id = ?",
            [.text(state.rawValue), log.map { .text($0) } ?? .null, .text(workspaceID)]
        )
    }

    /// The setup script is a child of this process, so it cannot outlive the app: a row still
    /// `running` at launch is a run that was killed, never a run still going.
    ///
    /// `.pending` and not `.failed`, because the script never got to report anything. Calling it
    /// failed accuses it of something nobody witnessed and hangs a warning triangle on a workspace
    /// that is very likely fine; calling it succeeded is simply a lie. `.pending` stops the
    /// spinner, reads as "setup has not run yet" and leaves the re-run button inviting, which is
    /// the honest description. The appended log line is what separates this from a workspace whose
    /// setup genuinely never started.
    public func recoverInterruptedSetups() throws {
        let note = "[bloom] The app stopped while the setup script was running, "
            + "so this run was interrupted before it could report a result. Run setup again to finish it."
        try db.run(
            """
            UPDATE workspaces
            SET setup_state = ?,
                setup_log = CASE WHEN setup_log = '' THEN ? ELSE setup_log || char(10) || ? END
            WHERE setup_state = ?
            """,
            [
                .text(SetupState.pending.rawValue), .text(note), .text(note),
                .text(SetupState.running.rawValue),
            ]
        )
    }

    public func nextWorkspaceSortOrder(repoID: String) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(sort_order), -1) AS m FROM workspaces WHERE repo_id = ?",
            [.text(repoID)]
        )
        return Int(rows.first?.int("m") ?? -1) + 1
    }

    // MARK: - Sessions

    public func sessions(workspaceID: String) throws -> [Session] {
        try db.query(
            "SELECT * FROM sessions WHERE workspace_id = ? AND archived_at IS NULL ORDER BY sort_order, created_at",
            [.text(workspaceID)]
        ).map(Self.session(from:))
    }

    public func session(id: String) throws -> Session? {
        try db.query("SELECT * FROM sessions WHERE id = ?", [.text(id)]).first.map(Self.session(from:))
    }

    /// Writes a whole session row. This is how a session is created, and it is worth reaching for
    /// only when the value being written was built here and now.
    ///
    /// Changing something about a session that already exists is `update(sessionID:_:)`, or one of
    /// the methods that names its columns: `updateSessionPreferences`, `reorderSessions`,
    /// `updateLastReadSeq`. This row has two owners running at very different speeds and
    /// `agent_session_id` is in the conflict clause below, so a whole-value write from a copy read
    /// before the agent answered takes resume with it.
    @discardableResult
    public func upsert(_ session: Session) throws -> Session {
        try db.run(
            """
            INSERT INTO sessions (
                id, workspace_id, title, agent_session_id, model, effort, agent_kind,
                permission_mode, state, sort_order, created_at, updated_at, archived_at,
                last_read_seq, input_tokens, output_tokens, cost_usd, context_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                agent_session_id = excluded.agent_session_id,
                model = excluded.model,
                effort = excluded.effort,
                agent_kind = excluded.agent_kind,
                permission_mode = excluded.permission_mode,
                state = excluded.state,
                sort_order = excluded.sort_order,
                updated_at = excluded.updated_at,
                archived_at = excluded.archived_at,
                last_read_seq = excluded.last_read_seq,
                input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                cost_usd = excluded.cost_usd,
                context_tokens = excluded.context_tokens
            """,
            [
                .text(session.id), .text(session.workspaceID), .text(session.title),
                session.agentSessionID.map { .text($0) } ?? .null,
                .text(session.model), .text(session.effort), .text(session.agentKind.rawValue),
                .text(session.permissionMode.rawValue),
                .text(session.state.rawValue), .int(Int64(session.sortOrder)),
                .double(session.createdAt.timeIntervalSince1970),
                .double(session.updatedAt.timeIntervalSince1970),
                session.archivedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .int(Int64(session.lastReadSeq)),
                .int(Int64(session.inputTokens)), .int(Int64(session.outputTokens)),
                .double(session.costUSD), .int(Int64(session.contextTokens)),
            ]
        )
        return session
    }

    /// Changes an existing session without writing the columns it did not mean to change.
    ///
    /// `update(workspaceID:_:)` and `update(repoID:_:)` two tables over, for the same reason and
    /// built the same way: the row is read here, inside the actor, immediately before it is
    /// written back, and neither SQLite call suspends, so nothing can write between them.
    ///
    /// This is the table where getting it wrong costs the most. A session row has two owners.
    /// `AgentRunner` owns `agent_session_id`, `state`, the token counters and `updated_at`, and it
    /// holds one `Session` value for as long as the workspace is open, which can be hours. The UI
    /// owns the title, the pickers, the sort order, the read mark and `archived_at`, and it writes
    /// them while turns are running. Whichever of them wrote a whole value put the other's columns
    /// back to what they were when its own copy was read, and one of those columns is the id
    /// `--resume` is built from: renaming a session tab mid turn wrote `agent_session_id` back to
    /// null, and the conversation could no longer be continued.
    ///
    /// Identity is not the caller's to move: `id` is pinned after the change runs, and
    /// `workspace_id` and `created_at` are not in `upsert`'s conflict clause at all.
    ///
    /// Returns nil when there is no such row rather than inserting one, so a turn still writing
    /// after its workspace was archived cannot put an orphan back.
    @discardableResult
    public func update(
        sessionID: String,
        _ change: @Sendable (inout Session) -> Void
    ) throws -> Session? {
        guard var row = try session(id: sessionID) else { return nil }
        change(&row)
        row.id = sessionID
        return try upsert(row)
    }

    /// Targeted updates for the fields the UI owns.
    ///
    /// A session row has two writers: `AgentRunner` owns `agent_session_id`, `state` and the
    /// token counters, while the UI owns the title and the pickers. Writing a whole `Session`
    /// struct from the UI would clobber whatever the runner persisted since that copy was read,
    /// which is how the agent session id (and therefore resume) gets lost.
    public func updateSessionPreferences(
        id: String,
        title: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil,
        /// Only ever set on a chat that has not spoken yet. Changing the backend of a chat that
        /// already has a message strands its transcript half in one vocabulary and half in the
        /// other, and its thread id on a server that knows nothing about the new one, so the
        /// picker forks a new chat instead. See docs/CODEX.md.
        agentKind: AgentKind? = nil
    ) throws {
        try db.run(
            """
            UPDATE sessions SET
                title = COALESCE(?, title),
                model = COALESCE(?, model),
                effort = COALESCE(?, effort),
                permission_mode = COALESCE(?, permission_mode),
                agent_kind = COALESCE(?, agent_kind),
                updated_at = ?
            WHERE id = ?
            """,
            [
                title.map { .text($0) } ?? .null,
                model.map { .text($0) } ?? .null,
                effort.map { .text($0) } ?? .null,
                permissionMode.map { .text($0.rawValue) } ?? .null,
                agentKind.map { .text($0.rawValue) } ?? .null,
                .double(Date().timeIntervalSince1970),
                .text(id),
            ]
        )
    }

    /// Writes a whole workspace's session order in one transaction.
    ///
    /// Targeted, for the same reason `updateSessionPreferences` is: `AgentRunner` owns the agent
    /// session id, the state and the counters on these rows, and writing a `Session` struct the
    /// strip was holding would put back whatever those columns looked like when it read them.
    /// `sort_order` has been on the table since the first migration and `sessions(workspaceID:)`
    /// already reads by it, so nothing here needs a schema change.
    public func reorderSessions(ids: [String]) throws {
        try db.transaction {
            for (order, id) in ids.enumerated() {
                try db.run(
                    "UPDATE sessions SET sort_order = ? WHERE id = ?",
                    [.int(Int64(order)), .text(id)]
                )
            }
        }
    }

    public func updateLastReadSeq(sessionID: String, seq: Int) throws {
        try db.run(
            "UPDATE sessions SET last_read_seq = ? WHERE id = ?",
            [.int(Int64(seq)), .text(sessionID)]
        )
    }

    public func deleteSession(id: String) throws {
        try db.run("DELETE FROM sessions WHERE id = ?", [.text(id)])
    }

    /// Any session left `running` or `waiting` when the app died is doing neither now.
    ///
    /// `waiting` is here for a sharper reason than `running`. A blocked agent holds its turn open
    /// until it is answered, and the CLI puts no timer on that, so a session that was waiting when
    /// Bloom died would come back claiming to be waiting on a question whose process is long gone:
    /// the sidebar would show the raised hand, the Dock would carry a badge, and the row would
    /// offer buttons that write into a closed pipe. See `abandonPendingPermissionAsks`, which is
    /// the other half and has to run with this one.
    public func resetRunningSessions() throws {
        try db.run("UPDATE sessions SET state = 'idle' WHERE state IN ('running', 'waiting')")
    }

    // MARK: - Messages

    public func messages(sessionID: String, afterSeq: Int = -1, limit: Int = 100_000) throws -> [Message] {
        try db.query(
            "SELECT * FROM messages WHERE session_id = ? AND seq > ? ORDER BY seq LIMIT ?",
            [.text(sessionID), .int(Int64(afterSeq)), .int(Int64(limit))]
        ).map(Self.message(from:))
    }

    public func messageCount(sessionID: String) throws -> Int {
        Int(try db.query(
            "SELECT COUNT(*) AS c FROM messages WHERE session_id = ?",
            [.text(sessionID)]
        ).first?.int("c") ?? 0)
    }

    public func nextSeq(sessionID: String) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(seq), -1) AS m FROM messages WHERE session_id = ?",
            [.text(sessionID)]
        )
        return Int(rows.first?.int("m") ?? -1) + 1
    }

    /// Insert a row at a sequence number the caller chose. Prefer `appendNext`, which cannot hand
    /// the same number to two writers.
    @discardableResult
    public func append(_ message: Message) throws -> Message {
        var stored = message
        stored.id = try insert(message)
        return stored
    }

    /// Allocate the next sequence number and insert the row in one go.
    ///
    /// Reading `nextSeq` and then calling `append` is two hops onto this actor, and a second
    /// writer that lands in between reserves the number that was just handed out: both rows then
    /// claim the same position. Doing both inside one call, inside one transaction, is what makes
    /// the allocation atomic. `UNIQUE(session_id, seq)` catches the case that outlives this
    /// process (a second `Store` on the same file), and losing that race is a retry, not an error.
    @discardableResult
    public func appendNext(
        sessionID: String,
        kind: MessageKind,
        payload: Data,
        durationMS: Int? = nil,
        refID: String? = nil,
        createdAt: Date = Date()
    ) throws -> Message {
        var lastError: Error?
        for _ in 0..<Self.seqAllocationAttempts {
            do {
                return try db.transaction {
                    let seq = try nextSeqLocked(sessionID: sessionID)
                    var message = Message(
                        sessionID: sessionID,
                        seq: seq,
                        kind: kind,
                        payload: payload,
                        createdAt: createdAt,
                        durationMS: durationMS,
                        refID: refID
                    )
                    message.id = try insert(message)
                    return message
                }
            } catch let error as SQLiteError where Self.isSeqConflict(error) {
                lastError = error
            }
        }
        throw lastError ?? SQLiteError(message: "could not allocate a sequence number", sql: nil)
    }

    /// Enough attempts to outlast a burst of writers, few enough that a genuinely stuck database
    /// surfaces as an error instead of spinning.
    private static let seqAllocationAttempts = 16

    private static func isSeqConflict(_ error: SQLiteError) -> Bool {
        error.message.contains("UNIQUE constraint failed: messages.session_id")
    }

    private func nextSeqLocked(sessionID: String) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(seq), -1) AS m FROM messages WHERE session_id = ?",
            [.text(sessionID)]
        )
        return Int(rows.first?.int("m") ?? -1) + 1
    }

    private func insert(_ message: Message) throws -> Int64 {
        try db.run(
            """
            INSERT INTO messages (session_id, seq, kind, payload, created_at, duration_ms, ref_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(message.sessionID), .int(Int64(message.seq)), .text(message.kind.rawValue),
                .blob(message.payload), .double(message.createdAt.timeIntervalSince1970),
                message.durationMS.map { .int(Int64($0)) } ?? .null,
                message.refID.map { .text($0) } ?? .null,
            ]
        )
    }

    /// Find the stored toolUse row a tool_result belongs to.
    public func message(sessionID: String, refID: String) throws -> Message? {
        try db.query(
            "SELECT * FROM messages WHERE session_id = ? AND ref_id = ? ORDER BY seq DESC LIMIT 1",
            [.text(sessionID), .text(refID)]
        ).first.map(Self.message(from:))
    }

    // MARK: - Drafts

    public func draft(sessionID: String) throws -> String {
        try db.query("SELECT body FROM drafts WHERE session_id = ?", [.text(sessionID)])
            .first?.string("body") ?? ""
    }

    public func saveDraft(sessionID: String, body: String) throws {
        if body.isEmpty {
            try db.run("DELETE FROM drafts WHERE session_id = ?", [.text(sessionID)])
        } else {
            try db.run(
                "INSERT INTO drafts (session_id, body) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET body = excluded.body",
                [.text(sessionID), .text(body)]
            )
        }
    }

    // MARK: - Review comments

    public func reviewComments(workspaceID: String) throws -> [ReviewComment] {
        try db.query(
            "SELECT * FROM review_comments WHERE workspace_id = ? ORDER BY file_path, line, created_at, id",
            [.text(workspaceID)]
        ).map(Self.reviewComment(from:))
    }

    public func reviewComments(workspaceID: String, filePath: String) throws -> [ReviewComment] {
        try db.query(
            """
            SELECT * FROM review_comments WHERE workspace_id = ? AND file_path = ?
            ORDER BY line, created_at, id
            """,
            [.text(workspaceID), .text(filePath)]
        ).map(Self.reviewComment(from:))
    }

    /// The ones that actually go out with the next message.
    public func attachedReviewComments(workspaceID: String) throws -> [ReviewComment] {
        try db.query(
            """
            SELECT * FROM review_comments WHERE workspace_id = ? AND attached = 1
            ORDER BY file_path, line, created_at, id
            """,
            [.text(workspaceID)]
        ).map(Self.reviewComment(from:))
    }

    /// Upsert rather than insert, so the composer can save an edited comment by writing the value
    /// it already holds instead of having to know whether that value has been to disk before.
    @discardableResult
    public func upsert(_ comment: ReviewComment) throws -> ReviewComment {
        try db.run(
            """
            INSERT INTO review_comments (
                id, workspace_id, file_path, side, line, line_text,
                context_before, context_after, body, created_at, attached
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                file_path = excluded.file_path,
                side = excluded.side,
                line = excluded.line,
                line_text = excluded.line_text,
                context_before = excluded.context_before,
                context_after = excluded.context_after,
                body = excluded.body,
                attached = excluded.attached
            """,
            [
                .text(comment.id), .text(comment.workspaceID), .text(comment.filePath),
                .text(comment.side.rawValue), .int(Int64(comment.anchor.line)),
                .text(comment.anchor.text),
                .text(Self.encodeContext(comment.anchor.before)),
                .text(Self.encodeContext(comment.anchor.after)),
                .text(comment.body), .double(comment.createdAt.timeIntervalSince1970),
                .int(comment.isAttached ? 1 : 0),
            ]
        )
        return comment
    }

    /// Only the body, because that is the only thing an edit changes. Rewriting the whole row would
    /// let a stale copy held by the editor put the anchor back to where the line used to be.
    public func updateReviewCommentBody(id: String, body: String) throws {
        try db.run("UPDATE review_comments SET body = ? WHERE id = ?", [.text(body), .text(id)])
    }

    public func setReviewCommentAttached(id: String, attached: Bool) throws {
        try db.run(
            "UPDATE review_comments SET attached = ? WHERE id = ?",
            [.int(attached ? 1 : 0), .text(id)]
        )
    }

    /// What "Remove from chat" does to the whole set once the message has gone out. The comments
    /// stay readable in the diff, they just stop being sent again with every following turn.
    public func detachReviewComments(workspaceID: String) throws {
        try db.run(
            "UPDATE review_comments SET attached = 0 WHERE workspace_id = ?",
            [.text(workspaceID)]
        )
    }

    public func deleteReviewComment(id: String) throws {
        try db.run("DELETE FROM review_comments WHERE id = ?", [.text(id)])
    }

    public func deleteReviewComments(workspaceID: String) throws {
        try db.run("DELETE FROM review_comments WHERE workspace_id = ?", [.text(workspaceID)])
    }

    // MARK: - Permission grants

    /// Every rule granted in one project, newest first. This is the revocation list.
    public func permissionGrants(repoID: String) throws -> [PermissionGrant] {
        try db.query(
            "SELECT * FROM permission_grants WHERE repo_id = ? ORDER BY granted_at DESC, id",
            [.text(repoID)]
        ).map(Self.permissionGrant(from:))
    }

    /// Everything granted anywhere, for a settings pane that lists them by project.
    public func permissionGrants() throws -> [PermissionGrant] {
        try db.query("SELECT * FROM permission_grants ORDER BY repo_id, granted_at DESC, id")
            .map(Self.permissionGrant(from:))
    }

    /// Record a grant, or leave the existing one alone if this rule is already granted here.
    ///
    /// Granting the same rule a second time must not reset the counters: the list uses them to say
    /// whether a rule is pulling its weight, and a rule re-granted because the user pressed the
    /// button again in a new workspace has not stopped being three weeks old.
    @discardableResult
    public func upsert(_ grant: PermissionGrant) throws -> PermissionGrant {
        try db.run(
            """
            INSERT INTO permission_grants (
                id, repo_id, tool_name, rule_content, granted_at, last_used_at, use_count, granted_for
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(repo_id, tool_name, rule_content) DO NOTHING
            """,
            [
                .text(grant.id), .text(grant.repoID), .text(grant.toolName),
                .text(grant.ruleContent ?? ""),
                .double(grant.grantedAt.timeIntervalSince1970),
                grant.lastUsedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .int(Int64(grant.useCount)), .text(grant.grantedFor),
            ]
        )
        // Read back rather than returned as passed, so the caller ends up holding the row that is
        // actually in the table: on a conflict that is the older grant, with its own id.
        let stored = try db.query(
            "SELECT * FROM permission_grants WHERE repo_id = ? AND tool_name = ? AND rule_content = ?",
            [.text(grant.repoID), .text(grant.toolName), .text(grant.ruleContent ?? "")]
        ).first
        return stored.map(Self.permissionGrant(from:)) ?? grant
    }

    /// Count one use of a grant, for the list. Deliberately not in the same statement as the
    /// lookup: a grant revoked between the two is simply not updated, which is the right outcome.
    public func recordPermissionGrantUse(id: String, at date: Date = Date()) throws {
        try db.run(
            "UPDATE permission_grants SET use_count = use_count + 1, last_used_at = ? WHERE id = ?",
            [.double(date.timeIntervalSince1970), .text(id)]
        )
    }

    /// Take one back. Immediate: nothing caches these, and the next ask reads the table again.
    public func deletePermissionGrant(id: String) throws {
        try db.run("DELETE FROM permission_grants WHERE id = ?", [.text(id)])
    }

    public func deletePermissionGrants(repoID: String) throws {
        try db.run("DELETE FROM permission_grants WHERE repo_id = ?", [.text(repoID)])
    }

    // MARK: - Pending permission asks

    /// File a question. Idempotent on the request id, so a replayed line cannot double up.
    public func appendPermissionAsk(sessionID: String, ask: PermissionAsk, at date: Date = Date()) throws {
        try db.run(
            """
            INSERT INTO permission_asks (id, session_id, tool_use_id, payload, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            [
                .text(ask.requestID), .text(sessionID), .text(ask.toolUseID),
                .blob(ask.raw), .double(date.timeIntervalSince1970),
            ]
        )
    }

    /// Close a question, with what was said about it.
    public func resolvePermissionAsk(id: String, decision: String, at date: Date = Date()) throws {
        try db.run(
            "UPDATE permission_asks SET resolved_at = ?, decision = ? WHERE id = ? AND resolved_at IS NULL",
            [.double(date.timeIntervalSince1970), .text(decision), .text(id)]
        )
    }

    /// The questions one session is still holding a turn open for, oldest first.
    public func pendingPermissionAsks(sessionID: String) throws -> [PendingPermissionAsk] {
        try db.query(
            """
            SELECT * FROM permission_asks
            WHERE session_id = ? AND resolved_at IS NULL
            ORDER BY created_at, id
            """,
            [.text(sessionID)]
        ).compactMap(Self.pendingPermissionAsk(from:))
    }

    /// Every unanswered question in the database, oldest first.
    ///
    /// This is what makes a blocked workspace visible from somewhere other than its own transcript,
    /// and it is one query rather than one per session: with five agents running, loading every
    /// session to find out which of them are stuck would be the expensive way to draw a dot.
    public func pendingPermissionAsks() throws -> [PendingPermissionAsk] {
        try db.query(
            "SELECT * FROM permission_asks WHERE resolved_at IS NULL ORDER BY created_at, id"
        ).compactMap(Self.pendingPermissionAsk(from:))
    }

    /// How a decided ask was decided, for drawing a row that has already been answered.
    public func permissionAskDecisions(sessionID: String) throws -> [String: String] {
        var decisions: [String: String] = [:]
        for row in try db.query(
            "SELECT id, decision FROM permission_asks WHERE session_id = ? AND decision IS NOT NULL",
            [.text(sessionID)]
        ) {
            guard let id = row.string("id"), let decision = row.string("decision") else { continue }
            decisions[id] = decision
        }
        return decisions
    }

    /// Close every question a session left open, because the process that was blocked on them is
    /// gone and no answer can reach it any more.
    ///
    /// Called at launch. A pending ask whose agent has died is not a question, it is a trap: it
    /// would draw live buttons that write into a closed pipe. Bloom denies explicitly on the way
    /// out precisely so this stays rare, but a crash, a force quit or a power cut all land here.
    @discardableResult
    public func abandonPendingPermissionAsks(decision: String = "abandoned", at date: Date = Date()) throws -> Int {
        let pending = try db.query(
            "SELECT COUNT(*) AS n FROM permission_asks WHERE resolved_at IS NULL"
        ).first?.int("n") ?? 0
        try db.run(
            "UPDATE permission_asks SET resolved_at = ?, decision = ? WHERE resolved_at IS NULL",
            [.double(date.timeIntervalSince1970), .text(decision)]
        )
        return Int(pending)
    }

    // MARK: - Settings

    public func setting(_ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?.string("value")
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try db.run(
                "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        } else {
            try db.run("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }

    // MARK: - Terminal tabs

    public func terminalTabs(workspaceID: String) throws -> [TerminalTab] {
        try db.query(
            "SELECT * FROM terminal_tabs WHERE workspace_id = ? ORDER BY sort_order",
            [.text(workspaceID)]
        ).map {
            TerminalTab(
                id: $0.string("id") ?? newID(),
                workspaceID: $0.string("workspace_id") ?? "",
                title: $0.string("title") ?? "Terminal",
                sortOrder: Int($0.int("sort_order") ?? 0)
            )
        }
    }

    public func upsert(_ tab: TerminalTab) throws {
        try db.run(
            """
            INSERT INTO terminal_tabs (id, workspace_id, title, sort_order) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, sort_order = excluded.sort_order
            """,
            [.text(tab.id), .text(tab.workspaceID), .text(tab.title), .int(Int64(tab.sortOrder))]
        )
    }

    public func deleteTerminalTab(id: String) throws {
        try db.run("DELETE FROM terminal_tabs WHERE id = ?", [.text(id)])
    }

    // MARK: - Row mapping

    private static func repo(from row: Row) -> Repo {
        Repo(
            id: row.string("id") ?? newID(),
            name: row.string("name") ?? "",
            path: row.string("path") ?? "",
            defaultBranch: row.string("default_branch") ?? "main",
            accent: row.string("accent") ?? Accent.all[0],
            sortOrder: Int(row.int("sort_order") ?? 0),
            collapsed: row.bool("collapsed"),
            createdAt: row.date("created_at") ?? Date(),
            iconPath: row.string("icon_path"),
            iconSource: RepoIconSource(rawValue: row.string("icon_source") ?? "") ?? .undetected
        )
    }

    private static func workspace(from row: Row) -> Workspace {
        Workspace(
            id: row.string("id") ?? newID(),
            repoID: row.string("repo_id") ?? "",
            name: row.string("name") ?? "",
            branch: row.string("branch") ?? "",
            path: row.string("path") ?? "",
            baseBranch: row.string("base_branch") ?? "main",
            state: WorkspaceState(rawValue: row.string("state") ?? "active") ?? .active,
            setupState: SetupState(rawValue: row.string("setup_state") ?? "pending") ?? .pending,
            setupLog: row.string("setup_log") ?? "",
            sortOrder: Int(row.int("sort_order") ?? 0),
            createdAt: row.date("created_at") ?? Date(),
            lastActivityAt: row.date("last_activity_at") ?? Date(),
            archivedAt: row.date("archived_at"),
            additions: Int(row.int("additions") ?? 0),
            deletions: Int(row.int("deletions") ?? 0),
            changedFiles: Int(row.int("changed_files") ?? 0),
            unread: row.bool("unread"),
            pinned: row.bool("pinned"),
            colour: row.string("colour")
        )
    }

    private static func permissionGrant(from row: Row) -> PermissionGrant {
        let content = row.string("rule_content") ?? ""
        return PermissionGrant(
            id: row.string("id") ?? newID(),
            repoID: row.string("repo_id") ?? "",
            toolName: row.string("tool_name") ?? "",
            // Stored as an empty string because SQLite counts every NULL as distinct in a unique
            // index, which would have let the same whole-tool grant be inserted over and over.
            ruleContent: content.isEmpty ? nil : content,
            grantedAt: row.date("granted_at") ?? Date(),
            lastUsedAt: row.date("last_used_at"),
            useCount: Int(row.int("use_count") ?? 0),
            grantedFor: row.string("granted_for") ?? ""
        )
    }

    /// Nil when the stored bytes will not decode. A row Bloom cannot read is a question it cannot
    /// draw, and skipping it is better than an ask with no command and four live buttons.
    private static func pendingPermissionAsk(from row: Row) -> PendingPermissionAsk? {
        guard let id = row.string("id"),
              let payload = row.data("payload"),
              let ask = PermissionAsk.decode(payload: payload)
        else {
            return nil
        }
        return PendingPermissionAsk(
            requestID: id,
            sessionID: row.string("session_id") ?? "",
            ask: ask,
            askedAt: row.date("created_at") ?? Date()
        )
    }

    private static func session(from row: Row) -> Session {
        Session(
            id: row.string("id") ?? newID(),
            workspaceID: row.string("workspace_id") ?? "",
            title: row.string("title") ?? "Session",
            agentSessionID: row.string("agent_session_id"),
            model: row.string("model") ?? "opus",
            effort: row.string("effort") ?? "high",
            // A row written before the column existed reads as Claude Code, which is what it was.
            agentKind: AgentKind(rawValue: row.string("agent_kind") ?? "") ?? .claudeCode,
            permissionMode: PermissionMode(rawValue: row.string("permission_mode") ?? "") ?? .acceptEdits,
            state: SessionState(rawValue: row.string("state") ?? "idle") ?? .idle,
            sortOrder: Int(row.int("sort_order") ?? 0),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date(),
            archivedAt: row.date("archived_at"),
            lastReadSeq: Int(row.int("last_read_seq") ?? 0),
            inputTokens: Int(row.int("input_tokens") ?? 0),
            outputTokens: Int(row.int("output_tokens") ?? 0),
            costUSD: row.double("cost_usd") ?? 0,
            contextTokens: Int(row.int("context_tokens") ?? 0)
        )
    }

    private static func reviewComment(from row: Row) -> ReviewComment {
        ReviewComment(
            id: row.string("id") ?? newID(),
            workspaceID: row.string("workspace_id") ?? "",
            filePath: row.string("file_path") ?? "",
            side: ReviewCommentSide(rawValue: row.string("side") ?? "") ?? .new,
            anchor: ReviewCommentAnchor(
                line: Int(row.int("line") ?? 1),
                text: row.string("line_text") ?? "",
                before: decodeContext(row.string("context_before")),
                after: decodeContext(row.string("context_after"))
            ),
            body: row.string("body") ?? "",
            createdAt: row.date("created_at") ?? Date(),
            isAttached: row.bool("attached")
        )
    }

    /// JSON rather than newline-joined text. A context line is a line of source, so joining on
    /// newlines cannot tell an empty list from a list holding one empty line, and getting that
    /// wrong shifts every stored snippet by one.
    private static func encodeContext(_ lines: [String]) -> String {
        guard let data = try? JSONEncoder().encode(lines) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeContext(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let lines = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return lines
    }

    private static func message(from row: Row) -> Message {
        Message(
            id: row.int("id") ?? 0,
            sessionID: row.string("session_id") ?? "",
            seq: Int(row.int("seq") ?? 0),
            kind: MessageKind(rawValue: row.string("kind") ?? "") ?? .system,
            payload: row.data("payload") ?? Data(),
            createdAt: row.date("created_at") ?? Date(),
            durationMS: row.int("duration_ms").map(Int.init),
            refID: row.string("ref_id")
        )
    }
}
