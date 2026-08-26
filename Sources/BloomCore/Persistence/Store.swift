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
/// that names them: `updateDiffStat`, `touch`, `updateSessionPreferences`, `reorderSessions`,
/// `reorderWorkspaces`, `reorderProjects`, `updateLastReadSeq`.
///
/// Three columns are not writable through `update`'s closure by anybody outside this module at
/// all: `Workspace.state`, `Workspace.setupState` and `Session.state` are `internal(set)`, and the
/// only way to move them is the event methods in `SetupLifecycle`, `SessionLifecycle` and
/// `WorkspaceLifecycle`. Read the head of any of those three for why a state and the work that
/// goes with it have to be one statement. `internal(set)` alone was not enough, and the way round
/// it was this method: `upsert` is public and writes every column, so a fresh value carrying an
/// existing id and any state at all did the job in one compiling line. The initialiser that names
/// those columns is internal too now. See `Workspace.init` in `Models.swift`.
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

    /// The bundle identifier of the copy the owner actually uses, and the one the dev build gets.
    ///
    /// Written down here because these two strings are the difference between a process that may
    /// open the real database and one that may not. `Tools/dev-build.sh` sets the second, and
    /// `Tools/guard.sh` names the directory that goes with it.
    public static let primaryBundleIdentifier = "be.spatie.bloom"
    public static let devBundleIdentifier = "be.spatie.bloom.dev"

    /// Which Application Support directory a binary with this bundle identifier may use.
    ///
    /// **This is the separation between the dev copy and the owner's data, and it used to be a
    /// paragraph of prose.** The directory was the constant "Bloom", so every process that
    /// reached `defaultPath` without `BLOOM_DB_PATH` opened the real database: the owner's
    /// projects, the real worktree paths, the tmux socket derived from that path. CLAUDE.md and
    /// `Tools/dev-build.sh` both warned about one route into that, `Bloom Dev.app/Contents/MacOS/
    /// Bloom` started by hand, since `LSEnvironment` is applied by LaunchServices and not by a
    /// shell. Nothing warned about the other one, which is `swift run` or `.build/debug/Bloom`,
    /// and neither warning was a control. What was one click away was an archive: a real worktree
    /// removed and its branch offered up for deletion, out of a build nobody thought was pointed
    /// at anything real.
    ///
    /// So it is derived from the binary instead. `LSEnvironment` is belt now rather than the only
    /// strap, and the dev copy is separated whether it is opened or run.
    ///
    /// The dev identifier maps to "Bloom Dev", which is the same directory `Tools/dev-build.sh`
    /// points `BLOOM_DB_PATH` at, so a hand started dev binary lands where it was always meant to
    /// rather than somewhere new. Anything else is a build that is not one of the two: it gets a
    /// directory named after what it is, because a nameless empty database is a mystery and
    /// "Bloom (unbundled)" sitting in Application Support answers itself.
    ///
    /// A pure function of the identifier, rather than of `Bundle.main`, because `Bundle.main`
    /// cannot be varied inside one process and this table is the whole of the rule.
    public static func databaseDirectoryName(forBundleIdentifier identifier: String?) -> String {
        switch identifier {
        case primaryBundleIdentifier: "Bloom"
        case devBundleIdentifier: "Bloom Dev"
        case .some(let other) where !other.isEmpty: "Bloom (\(other))"
        // An executable that is not inside a bundle at all: `swift run`, `.build/debug/Bloom`, or
        // a test host. Nil and empty are the same claim and are treated the same way.
        default: "Bloom (unbundled)"
        }
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = databaseDirectoryName(forBundleIdentifier: Bundle.main.bundleIdentifier)
        return base.appendingPathComponent(name, isDirectory: true)
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

        // Only the real app adopts the database from before the rename, and that is the same rule
        // as the directory above rather than a second one. `adopt` hands back the LEGACY path when
        // the copy fails, on purpose, so that a user who cannot be migrated still runs on their own
        // work; from any other binary that is one more way to end up holding the owner's real rows.
        // A dev copy has never adopted it either, because `BLOOM_DB_PATH` returns above this line.
        guard Bundle.main.bundleIdentifier == primaryBundleIdentifier else {
            return destination.path
        }

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

    /// Every committed write to this database, by table, coalesced. See `StoreObservation.swift`,
    /// and read the two rules on `StoreChangeHub` before writing anything that consumes this.
    ///
    /// `nonisolated` because subscribing is not a database operation and must not queue behind the
    /// writes it wants to hear about. `db` is a `let` of a `Sendable` class, so reading it from
    /// outside the actor is sound.
    ///
    /// The domains are named by the caller rather than filtered afterwards, so a subscriber that
    /// does not care about a table is not woken by it at all. That is not a nicety: `messages` is
    /// written many times a second for the whole of a streaming turn, and it is the one table an
    /// interested-in-everything subscriber would spend all its time on.
    public nonisolated func changes(
        of domains: Set<StoreDomain> = Set(StoreDomain.allCases)
    ) -> StoreChanges {
        StoreChanges(hub: db.changes, interest: domains)
    }

    /// The hub this store's writes land in.
    ///
    /// For the tests, which have to ask one specific database what it published rather than look a
    /// hub up by path. A `:memory:` store has no path to look up, and that it does not share a hub
    /// with the next `:memory:` store is exactly the thing worth pinning.
    nonisolated var changeHub: StoreChangeHub { db.changes }

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

            // Who asked for a workspace: the owner, or an agent running in another workspace.
            //
            // NULL is the owner, which is every row that existed when this ran and most rows that
            // will ever exist, so there is no default to invent and nothing to backfill.
            //
            // No `depth` column beside it. The limit on nesting is one, so "has a parent" is the
            // depth already, and a second number recording the same fact is a second number that
            // can be wrong.
            //
            // No foreign key, deliberately. The parentage record has to survive the parent being
            // archived, and an `ON DELETE` of any flavour would either take the child's record
            // with it or refuse the archive. A parent id pointing at nothing is not a broken row:
            // it reads as "nobody living may reach into this through the bridge", which is the
            // failure this wants.
            //
            // `spawn_tool_use_id` is the tool call that asked, kept so a retried spawn can be
            // recognised as the same one rather than cutting a second worktree. See
            // `WorkspaceOrigin` for why the two are one value up in Swift and two columns here.
            //
            // Real code rather than SQL for the same reason as the three steps above: `ADD COLUMN`
            // has no `IF NOT EXISTS`, and the store's own tests rewind `user_version` to reproduce
            // an old schema, so a step that could not be replayed would throw and take the whole
            // migration transaction with it.
            { db in
                let existing = Set(
                    try db.query("PRAGMA table_info(workspaces);").compactMap { $0.string("name") }
                )
                if !existing.contains("parent_workspace_id") {
                    try db.execute("ALTER TABLE workspaces ADD COLUMN parent_workspace_id TEXT;")
                }
                if !existing.contains("spawn_tool_use_id") {
                    try db.execute("ALTER TABLE workspaces ADD COLUMN spawn_tool_use_id TEXT;")
                }
                try db.execute(
                    """
                    CREATE INDEX IF NOT EXISTS workspaces_parent
                        ON workspaces(parent_workspace_id);
                    """
                )
                // Indexed, not unique. Recognising a retry is asking which workspaces this tool
                // call has already made, and the phase that writes the spawn tool is the one
                // entitled to decide whether one call may ask for more than one workspace. A
                // unique index would settle that here, months early, and be a migration to undo.
                try db.execute(
                    """
                    CREATE INDEX IF NOT EXISTS workspaces_spawn_tool_use
                        ON workspaces(spawn_tool_use_id);
                    """
                )
            },

            // Messages that have been asked for and have not gone yet. See `Delivery`.
            //
            // A table rather than an array in a view model, because of what a queued message has
            // to survive: quitting Bloom with three of them waiting, a turn that fails instead of
            // finishing, and a workspace nobody has opened since launch. All three used to end the
            // same way, which is that the sentence was gone.
            //
            // **This is the `deliveries` table in `bloom-handover/mcp-design.md`, laid down here
            // because the owner needed half of it first.** The columns nothing writes yet are in
            // it on purpose: `source_workspace_id` and `verdict` are what a child workspace's
            // report needs, and a migration is the one thing that is expensive to go back and
            // change. What the two halves share is not a coincidence to be tidied away later, it
            // is the same question (something arrived for a session that is busy) with the same
            // answer (park it, deliver it when the turn ends, in the order it was asked).
            //
            // Ordered by `created_at, rowid`. The timestamp alone is not a total order: the
            // opening prompt and a sentence typed a moment later can land in the same millisecond,
            // and the whole point of this table is that the first thing asked for is the first
            // thing sent. The rowid breaks the tie in insertion order and costs nothing, since
            // this table has a TEXT primary key and therefore still has one.
            //
            // No foreign key on `target_session_id`, following the design: a delivery is a record
            // of what was asked for, and it should outlive the chat for the same reason a report
            // should outlive the parent it was addressed to. An orphan is inert, since every read
            // here names a session.
            sql("""
            CREATE TABLE IF NOT EXISTS deliveries (
                id TEXT PRIMARY KEY,
                target_session_id TEXT NOT NULL,
                source_workspace_id TEXT,
                kind TEXT NOT NULL DEFAULT 'owner',
                verdict TEXT,
                body TEXT NOT NULL,
                created_at REAL NOT NULL,
                delivered_at REAL,
                delivered_seq INTEGER
            );
            CREATE INDEX IF NOT EXISTS deliveries_pending
                ON deliveries(target_session_id, delivered_at);
            """),

            // The sea catalogue every new workspace is christened out of. A table rather than
            // `OceanCatalog.all` read at pick time, because which seas have been spent is state
            // the binary must not own: `used_at` has to survive an update that ships a corrected
            // coordinate or an extra sea, so the catalogue seeds the table once and from then on
            // the database is the truth about what has been used.
            //
            // Real code rather than SQL because seeding loops over the catalogue with bound
            // parameters, and `INSERT OR IGNORE` is what keeps the step replayable: the store's
            // own tests rewind `user_version` to reproduce an old schema, and a reseed over rows
            // that already exist must leave every `used_at` exactly where it was rather than
            // throw or put a discovery date back to null.
            { db in
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS oceans (
                        slug TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        latitude REAL NOT NULL,
                        longitude REAL NOT NULL,
                        used_at REAL
                    );
                    """)
                for ocean in OceanCatalog.all {
                    try db.run(
                        "INSERT OR IGNORE INTO oceans (slug, name, latitude, longitude) VALUES (?, ?, ?, ?)",
                        [
                            .text(ocean.slug), .text(ocean.name),
                            .double(ocean.latitude), .double(ocean.longitude),
                        ]
                    )
                }
            },

            // The catalogue shipped with 268 islands mixed into what is meant to be a list of
            // seas, and was trimmed to actual water after databases had already been seeded, so
            // a seeded table still carries every removed row. The unclaimed ones go here: left
            // in place they would keep handing out island names the wording cannot carry. The
            // claimed ones stay, whether or not the catalogue still knows them, because used_at
            // is history only this table owns and the map still has to pin a voyage that
            // already happened. Replayable like the seed: deleting an already absent slug
            // deletes nothing, and a claimed row is never touched.
            { db in
                let known = Set(OceanCatalog.all.map(\.slug))
                for row in try db.query("SELECT slug FROM oceans WHERE used_at IS NULL") {
                    guard let slug = row.string("slug"), !known.contains(slug) else { continue }
                    try db.run("DELETE FROM oceans WHERE slug = ?", [.text(slug)])
                }
            },
            // Full text search over what the agents actually said.
            //
            // WHY A TABLE OF ITS OWN RATHER THAN AN EXTERNAL CONTENT INDEX. An external content
            // FTS5 table reads its column values back out of the table it shadows, which saves
            // storing them twice, and that is the right shape when the indexed text IS a column.
            // Here it is not: `messages.payload` is the raw JSON line the agent CLI emitted, and
            // pointing FTS5 at it would index every key, every uuid and every tool_use id
            // alongside the words, and would hand `snippet()` a mouthful of JSON to show the
            // reader. The searchable text is derived (see `TranscriptSearchText`), so there is no
            // column to shadow. Measured on the owner's database, the derived text is well under
            // half the size of the payloads it comes from, so storing it is cheaper than the
            // external content table would have been to query.
            //
            // WHY NOT TRIGGERS FOR THE INSERT. The extraction is Swift, walking a JSON document
            // and skipping the keys that are machinery, and SQL cannot call it. So the index is
            // written in `insert`, inside the same transaction as the message row, which is what
            // makes "a message exists but is not searchable" a state the database cannot be in.
            // The DELETE is a trigger, because deleting by rowid needs no Swift at all and
            // archiving a workspace removes its messages through a foreign key cascade that no
            // Swift of Bloom's is on the stack for. There is no UPDATE trigger because a message
            // row`s payload is never rewritten; only `seq` is, by the migration above.
            //
            // `porter` on top of `unicode61` so that searching for "worked" finds "working". The
            // stemmer is applied to the query as well as the text, so the two always agree.
            { db in
                try db.execute("""
                    CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
                        body,
                        tokenize = 'porter unicode61 remove_diacritics 2'
                    );

                    CREATE TRIGGER IF NOT EXISTS messages_search_delete
                    AFTER DELETE ON messages BEGIN
                        DELETE FROM message_search WHERE rowid = old.id;
                    END;
                    """)

                // Where the backfill starts. Everything from here up is indexed as it is written,
                // so the backfill only ever walks backwards through history and can never race
                // the agent that is running while it works. See `indexOlderTranscripts`.
                let highest = try db.query("SELECT COALESCE(MAX(id), 0) AS m FROM messages")
                    .first?.int("m") ?? 0
                try db.run(
                    "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                    [.text(Self.backfillCursorKey), .text(String(highest + 1))]
                )
            },

            // The workspace notes pane: one piece of scratch text per worktree, kept because the
            // thing you notice at eleven at night has to still be there in the morning.
            //
            // A table rather than a column on `workspaces`, and the reasoning is on `WorkspaceNote`.
            // In short: the workspace row already has four writers running at four different
            // speeds, a pane somebody types in for a minute is the slowest of them, and the last
            // time a slow writer sent a whole row back the database claimed a workspace was live
            // over a deleted worktree.
            //
            // The cascade is the only lifecycle it needs. Archiving moves `state` and leaves the
            // row standing, so an archived workspace keeps its note, which is the point: a note is
            // usually about why the work stopped.
            sql("""
            CREATE TABLE IF NOT EXISTS workspace_notes (
                workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
                body TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """),

            // The block of ten ports a workspace holds, which used to live only in memory.
            //
            // A setup script writes this number into files that outlive the process: a `.env`
            // saying `APP_URL=http://localhost:3100`, a compose file, a Valet site. Allocating a
            // fresh block on the next launch left every one of those naming a port nothing was
            // listening on. It is also the only way the archive script can take down what the
            // setup script put up, because it is what makes `$BLOOM_PORT` the same number in both.
            //
            // Zero rather than NULL, and no backfill. Zero already means "no block yet" in the
            // Swift value and in `$BLOOM_PORT`, so every row that existed before this reads as a
            // workspace that has not asked for one, which is true: nothing wrote a port down, so
            // there is no earlier promise to keep. The first thing that wants one allocates it,
            // against the blocks the other rows now hold.
            //
            // Real code rather than SQL for the same reason as the steps above: `ADD COLUMN` has
            // no `IF NOT EXISTS`, and the store's own tests rewind `user_version` to reproduce an
            // old schema, so a step that could not be replayed would throw and take the whole
            // migration transaction with it.
            { db in
                let existing = Set(
                    try db.query("PRAGMA table_info(workspaces);").compactMap { $0.string("name") }
                )
                if !existing.contains("port") {
                    try db.execute(
                        "ALTER TABLE workspaces ADD COLUMN port INTEGER NOT NULL DEFAULT 0;"
                    )
                }
            },

            // The transcript index, thrown away and built again.
            //
            // `TranscriptSearchText` decides what of a row is words and what is machinery, and it
            // used to let three fields through that are not words: `usage.inference_geo`,
            // `usage.service_tier` and the line's own `timestamp`. A search for "hello" answered
            // with "Hello. What are we working on? not_available standard 2026-08-23T10:22:27",
            // which is the snippet reading out the bookkeeping that had been concatenated onto the
            // sentence in the index.
            //
            // What is indexed is derived at write time, so fixing the extractor fixes nothing that
            // is already written: every row indexed before this keeps the text it was given, and
            // the reader keeps being shown it. So the index goes, and the cursor goes back above
            // the highest message, which is the state the backfill was built for. The app already
            // walks that cursor down after its first screen is drawn, newest first, a batch at a
            // time, resumable, so this costs a background walk rather than a slow launch, and the
            // recent workspaces anybody actually searches for are correct within seconds.
            { db in
                try db.execute("DELETE FROM message_search;")
                let highest = try db.query("SELECT COALESCE(MAX(id), 0) AS m FROM messages")
                    .first?.int("m") ?? 0
                try db.run(
                    "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                    [.text(Self.backfillCursorKey), .text(String(highest + 1))]
                )
            },

            // Every provider's allowance, keyed by provider and window.
            //
            // A table of its own, and not a column anywhere. This belongs to an account rather
            // than to a workspace: two workspaces open on Claude Code report the same five hour
            // window, and writing that onto either workspace row would put an account-wide fact in
            // two places and hand a frequent writer a whole-value write on a row the diff stat
            // refresh and an archive are already fighting over. Same reasoning as `WorkspaceNote`,
            // and the bug behind it is `WorkspaceWriteIsolationTests`.
            //
            // The primary key is (provider, window) rather than a row per report, because a report
            // is not history, it is the current state of one window. Two workspaces reporting the
            // same window land on the same row and the fresher observation wins, which is right:
            // there is one account behind both.
            //
            // `used`, `limit_value` and `unit` are all nullable because all three are genuinely
            // unknown some of the time. Claude Code publishes no usage figure until a warning
            // threshold has been passed, and a provider may report usage against no published
            // ceiling. See `QuotaMeasure`.
            sql("""
            CREATE TABLE IF NOT EXISTS agent_quotas (
                provider TEXT NOT NULL,
                window_key TEXT NOT NULL,
                window_label TEXT NOT NULL,
                window_seconds REAL,
                used REAL,
                limit_value REAL,
                unit TEXT,
                resets_at REAL,
                observed_at REAL NOT NULL,
                PRIMARY KEY (provider, window_key)
            );
            """),

            // Whether a project is left out of the sidebar's list.
            //
            // Zero rather than NULL and no backfill, because nobody has hidden anything yet: every
            // row that existed before this is a project the owner can see, which is what zero
            // says. See `ProjectVisibility` for what the column means and `Repo.hidden` for what
            // it deliberately does not touch.
            //
            // Real code rather than SQL for the reason every step above gives: `ADD COLUMN` has no
            // `IF NOT EXISTS`, and the store's own tests rewind `user_version` to reproduce an old
            // schema, so a step that could not be replayed would throw and take the whole
            // migration transaction with it.
            { db in
                let existing = Set(
                    try db.query("PRAGMA table_info(repos);").compactMap { $0.string("name") }
                )
                if !existing.contains("hidden") {
                    try db.execute("ALTER TABLE repos ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;")
                }
            },

            // The owner's own quick prompts: a short name, a mark, and the words that go into the
            // composer's draft.
            //
            // A table rather than the settings key value pairs. The seven entries in
            // `PromptOverrides` get away with a key each because their set is closed and Bloom
            // wrote it; this list grows, is renamed and is deleted from, and every growing list in
            // Bloom is a row. It hangs off nothing: there is one flat global list, so there is no
            // foreign key here and no project scope to widen later without a migration.
            sql("""
            CREATE TABLE IF NOT EXISTS quick_prompt (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                symbol TEXT NOT NULL,
                text TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            """),

            // The two switches on a quick prompt: whether choosing it sends the words rather than
            // leaving them in the composer, and whether it opens a new chat for them.
            //
            // Zero rather than NULL, and no backfill. Every prompt in the table was written when
            // insert-and-stop was the only thing a quick prompt could do, and off is exactly that
            // behaviour, so the default is not a guess about what the owner wanted, it is what the
            // row has always done. See `QuickPromptDelivery`.
            //
            // Real code rather than SQL for the reason the two steps above give: `ADD COLUMN` has
            // no `IF NOT EXISTS`, and the store's own tests rewind `user_version` to reproduce an
            // old schema, so a step that could not be replayed would throw and take the whole
            // migration transaction with it.
            { db in
                let existing = Set(
                    try db.query("PRAGMA table_info(quick_prompt);").compactMap { $0.string("name") }
                )
                if !existing.contains("sends_immediately") {
                    try db.execute("""
                        ALTER TABLE quick_prompt
                        ADD COLUMN sends_immediately INTEGER NOT NULL DEFAULT 0;
                        """)
                }
                if !existing.contains("opens_new_chat") {
                    try db.execute("""
                        ALTER TABLE quick_prompt
                        ADD COLUMN opens_new_chat INTEGER NOT NULL DEFAULT 0;
                        """)
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

    public func repo(id: RepoID) throws -> Repo? {
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
                id, name, path, default_branch, accent, sort_order, collapsed, hidden, created_at,
                icon_path, icon_source
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                path = excluded.path,
                default_branch = excluded.default_branch,
                accent = excluded.accent,
                sort_order = excluded.sort_order,
                collapsed = excluded.collapsed,
                hidden = excluded.hidden,
                icon_path = excluded.icon_path,
                icon_source = excluded.icon_source
            """,
            [
                .text(repo.id), .text(repo.name), .text(repo.path), .text(repo.defaultBranch),
                .text(repo.accent), .int(Int64(repo.sortOrder)), .int(repo.collapsed ? 1 : 0),
                .int(repo.hidden ? 1 : 0),
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
        repoID: RepoID,
        _ change: @Sendable (inout Repo) -> Void
    ) throws -> Repo? {
        guard var row = try repo(id: repoID) else { return nil }
        change(&row)
        row.id = repoID
        return try upsert(row)
    }

    /// Writes a whole project drag's new order in one transaction.
    ///
    /// One transaction and not a loop of `update(repoID:)` calls, and that is not tidiness either.
    /// Each of those calls commits on its own, and since the store announces every commit
    /// (`StoreObservation.swift`) a drag over five projects was five commits and five
    /// announcements. `AppModel`'s observer reloads the sidebar on `repos`, so its reload could
    /// land in the actor queue between the second write and the third and put an order that is
    /// half old and half new on screen: a row visibly jumping back for a frame at the end of a
    /// drag somebody had just finished. One transaction commits once and is announced once, so
    /// there is no moment at which the stored order is half written and something is looking.
    /// Do not turn this back into a loop of separate writes.
    ///
    /// Targeted, exactly as `reorderSessions` is: the statement names `sort_order` and nothing
    /// else, so a rename, an accent or an icon that landed while the drag was happening survives
    /// it. Writing back a whole `Repo` the sidebar was holding is the bug `update(repoID:)` was
    /// written for.
    public func reorderProjects(_ changes: [SidebarReorder.ProjectChange]) throws {
        guard !changes.isEmpty else { return }
        try db.transaction {
            for change in changes {
                try db.run(
                    "UPDATE repos SET sort_order = ? WHERE id = ?",
                    [.int(Int64(change.sortOrder)), .text(change.id)]
                )
            }
        }
    }

    public func deleteRepo(id: RepoID) throws {
        try db.run("DELETE FROM repos WHERE id = ?", [.text(id)])
    }

    // MARK: - Workspaces

    public func workspaces(includeArchived: Bool = false) throws -> [Workspace] {
        let sql = includeArchived
            ? "SELECT * FROM workspaces ORDER BY sort_order, created_at"
            : "SELECT * FROM workspaces WHERE state = 'active' ORDER BY sort_order, created_at"
        return try db.query(sql).map(Self.workspace(from:))
    }

    public func workspaces(repoID: RepoID, includeArchived: Bool = false) throws -> [Workspace] {
        let sql = includeArchived
            ? "SELECT * FROM workspaces WHERE repo_id = ? ORDER BY sort_order, created_at"
            : "SELECT * FROM workspaces WHERE repo_id = ? AND state = 'active' ORDER BY sort_order, created_at"
        return try db.query(sql, [.text(repoID)]).map(Self.workspace(from:))
    }

    public func workspace(id: WorkspaceID) throws -> Workspace? {
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
                additions, deletions, changed_files, unread, pinned, colour,
                parent_workspace_id, spawn_tool_use_id, port
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                colour = excluded.colour,
                parent_workspace_id = excluded.parent_workspace_id,
                spawn_tool_use_id = excluded.spawn_tool_use_id,
                port = excluded.port
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
                workspace.origin.parentWorkspaceID.map { .text($0) } ?? .null,
                workspace.origin.spawnToolUseID.map { .text($0) } ?? .null,
                .int(Int64(workspace.port)),
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
    /// `updateDiffStat` and `touch` are the same rule written out column by column for the two
    /// writers that already had it. This is the rule itself, so a column added to
    /// `Workspace` next year does not quietly reopen the hole for everybody else.
    ///
    /// Identity is not the caller's to move: `id` is pinned after the change runs, and `repo_id`
    /// and `created_at` are not in `upsert`'s conflict clause at all.
    ///
    /// Returns nil when there is no such row rather than inserting one. Creating a workspace is
    /// `upsert`, and that is the only thing `upsert` should be reached for.
    @discardableResult
    public func update(
        workspaceID: WorkspaceID,
        _ change: @Sendable (inout Workspace) -> Void
    ) throws -> Workspace? {
        guard var row = try workspace(id: workspaceID) else { return nil }
        change(&row)
        row.id = workspaceID
        return try upsert(row)
    }

    /// Writes a whole workspace drag's new order in one transaction.
    ///
    /// The same reasoning as `reorderProjects`, and it is worth reading there: a loop of separate
    /// `update(workspaceID:)` calls commits once per row, the store announces every commit, and
    /// the sidebar's observer can therefore reload between two of those writes and draw a list
    /// that is half reordered. One transaction is one commit and one announcement.
    ///
    /// Targeted, so a diff stat refresh or an archive landing during the drag is not rolled back:
    /// the statement names the two columns a reorder actually changes and leaves the rest of the
    /// row alone. `SidebarReorder.Change` carries those two columns and never a whole `Workspace`
    /// for the same reason.
    public func reorderWorkspaces(_ changes: [SidebarReorder.Change]) throws {
        guard !changes.isEmpty else { return }
        try db.transaction {
            for change in changes {
                try db.run(
                    "UPDATE workspaces SET sort_order = ?, pinned = ? WHERE id = ?",
                    [
                        .int(Int64(change.sortOrder)), .int(change.pinned ? 1 : 0),
                        .text(change.id),
                    ]
                )
            }
        }
    }

    public func deleteWorkspace(id: WorkspaceID) throws {
        try db.run("DELETE FROM workspaces WHERE id = ?", [.text(id)])
    }

    /// Every archived workspace, with what it still holds measured out of the database.
    ///
    /// Six aggregates rather than one join. A workspace with three chats and eight thousand
    /// messages would appear eight thousand times in a single joined row set, and every count
    /// taken from it would be wrong by a factor nobody would notice until a review comment was
    /// multiplied by a transcript. Each query here groups on its own table and the results are
    /// merged in Swift, so a workspace with no messages, no comments and no note is still a row.
    ///
    /// `LENGTH()` on a blob column costs nothing: SQLite reads the size out of the record header
    /// and never touches the overflow pages the payload actually lives on. That is what makes
    /// measuring a 500 MB transcript table cheap enough to do every time the screen opens, rather
    /// than a number cached somewhere and quietly wrong.
    public func archivedFootprints() throws -> [ArchivedWorkspaceFootprint] {
        let rows = try db.query("""
            SELECT w.*, r.name AS repo_name
            FROM workspaces w
            JOIN repos r ON r.id = w.repo_id
            WHERE w.state = 'archived'
            """)
        guard !rows.isEmpty else { return [] }

        var sessions: [String: Int] = [:]
        for row in try db.query("SELECT workspace_id, COUNT(*) AS n FROM sessions GROUP BY workspace_id") {
            sessions[row.string("workspace_id") ?? ""] = Int(row.int("n") ?? 0)
        }

        var messages: [String: (count: Int, bytes: Int)] = [:]
        for row in try db.query("""
            SELECT s.workspace_id AS wid, COUNT(m.id) AS n,
                   COALESCE(SUM(LENGTH(m.payload)), 0) AS bytes
            FROM messages m JOIN sessions s ON s.id = m.session_id
            GROUP BY s.workspace_id
            """) {
            messages[row.string("wid") ?? ""] = (Int(row.int("n") ?? 0), Int(row.int("bytes") ?? 0))
        }

        var comments: [String: (count: Int, bytes: Int)] = [:]
        for row in try db.query("""
            SELECT workspace_id, COUNT(*) AS n,
                   COALESCE(SUM(LENGTH(body) + LENGTH(line_text) + LENGTH(context_before)
                                 + LENGTH(context_after) + LENGTH(file_path)), 0) AS bytes
            FROM review_comments GROUP BY workspace_id
            """) {
            comments[row.string("workspace_id") ?? ""] = (Int(row.int("n") ?? 0), Int(row.int("bytes") ?? 0))
        }

        var notes: [String: Int] = [:]
        for row in try db.query("SELECT workspace_id, LENGTH(body) AS bytes FROM workspace_notes") {
            notes[row.string("workspace_id") ?? ""] = Int(row.int("bytes") ?? 0)
        }

        var asks: [String: Int] = [:]
        for row in try db.query("""
            SELECT s.workspace_id AS wid, COALESCE(SUM(LENGTH(p.payload)), 0) AS bytes
            FROM permission_asks p JOIN sessions s ON s.id = p.session_id
            GROUP BY s.workspace_id
            """) {
            asks[row.string("wid") ?? ""] = Int(row.int("bytes") ?? 0)
        }

        return rows.map { row in
            let workspace = Self.workspace(from: row)
            let key = workspace.id.rawValue
            let comment = comments[key] ?? (0, 0)
            let note = notes[key] ?? 0
            return ArchivedWorkspaceFootprint(
                workspace: workspace,
                repoName: row.string("repo_name") ?? "",
                sessionCount: sessions[key] ?? 0,
                messageCount: messages[key]?.count ?? 0,
                transcriptBytes: messages[key]?.bytes ?? 0,
                otherBytes: comment.1 + note + (asks[key] ?? 0) + workspace.setupLog.utf8.count,
                reviewCommentCount: comment.0,
                hasNote: note > 0
            )
        }
    }

    /// Deletes archived workspaces and everything hanging off them, permanently.
    ///
    /// Almost all of it is the declared cascades doing their job: sessions, messages and with them
    /// their `message_search` rows through the delete trigger, terminal tabs, review comments and
    /// the note. Two tables carry no foreign key on purpose and would be left behind, so they are
    /// named here. `drafts` is keyed by session id with no reference at all, and `deliveries`
    /// deliberately outlives the session it was addressed to (see the schema), which is right
    /// while the workspace exists and wrong once it does not.
    ///
    /// **Archived only, checked in SQL rather than by the caller.** This is the one call in the
    /// app that destroys a transcript, and a caller that had gone stale between building a list
    /// and confirming it must not be able to take a live workspace's history with it.
    ///
    /// Returns how many workspaces were actually removed, which is not necessarily how many were
    /// asked for.
    @discardableResult
    public func deleteArchivedWorkspaces(ids: [WorkspaceID]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try db.transaction {
            var deleted = 0
            for id in ids {
                let isArchived = try db.query(
                    "SELECT 1 AS ok FROM workspaces WHERE id = ? AND state = 'archived'", [.text(id)]
                ).first != nil
                guard isArchived else { continue }

                try db.run(
                    "DELETE FROM drafts WHERE session_id IN (SELECT id FROM sessions WHERE workspace_id = ?)",
                    [.text(id)]
                )
                try db.run(
                    """
                    DELETE FROM deliveries
                    WHERE source_workspace_id = ?
                       OR target_session_id IN (SELECT id FROM sessions WHERE workspace_id = ?)
                    """,
                    [.text(id), .text(id)]
                )
                try db.run("DELETE FROM workspaces WHERE id = ?", [.text(id)])
                deleted += 1
            }
            return deleted
        }
    }

    /// How big the database file is, and how much of it is space nothing is using.
    ///
    /// `page_count` rather than the file's size on disk, because in WAL mode the file on disk is
    /// three files and the two beside `bloom.sqlite` are a log that gets checkpointed away. The
    /// page count is what the database will settle at, which is the number a person deciding
    /// whether to compact needs.
    public func databaseSize() throws -> DatabaseSize {
        let pageSize = Int(try db.query("PRAGMA page_size;").first?.int("page_size") ?? 0)
        let pages = Int(try db.query("PRAGMA page_count;").first?.int("page_count") ?? 0)
        let free = Int(try db.query("PRAGMA freelist_count;").first?.int("freelist_count") ?? 0)
        return DatabaseSize(pageSize: pageSize, pageCount: pages, freePageCount: free)
    }

    /// Rewrites the database so the pages a delete freed go back to the filesystem.
    ///
    /// **Deleting rows does not shrink the file.** SQLite puts the pages on a free list and reuses
    /// them for the next thing written, which is the right default and the reason a delete of half
    /// a gigabyte of transcript changes nothing anybody can see in Finder. `VACUUM` is what
    /// actually hands the space back, and it does it by copying the whole database, so it costs
    /// roughly the current file size in temporary space and takes as long as reading and writing
    /// that much. On a 500 MB database that is seconds, during which this actor answers nothing.
    ///
    /// So it is a separate call with its own button rather than something a delete does on its
    /// own. A delete that silently froze the app for ten seconds would be a bug report, and a
    /// screen that reported freed space it had not actually freed would be a lie. This is the
    /// third option: say how much is sitting in the free list, and let the person spend the time
    /// when they want to.
    public func compactDatabase() throws {
        try db.execute("VACUUM;")
        // And then the log, because in WAL mode `VACUUM` writes the rebuilt database into
        // `bloom.sqlite-wal` and the main file only shrinks when a checkpoint moves it across.
        // Without this the pages are genuinely reclaimed, `page_count` says so, and the file in
        // Finder is still the size it was, which is the one number the person who pressed the
        // button can check. `TRUNCATE` rather than `PASSIVE` so the log itself is handed back too.
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Writes the three counts, and only when one of them has actually moved.
    ///
    /// This runs every six seconds for every active workspace, and on an idle machine it writes
    /// the same three numbers back every time. SQLite does not care that the values are identical:
    /// the row is rewritten, the WAL grows, and the update hook fires, so an app sitting there
    /// doing nothing would announce a change per workspace per six seconds forever and everything
    /// listening would reload for it. See `StoreChangeHub` for why a write that answers a change
    /// has to compare and skip; this is the same rule for a write on a timer.
    ///
    /// The read and the write are both inside the actor with no suspension between them, so this
    /// is still one indivisible change, exactly as `update(workspaceID:)` is.
    public func updateDiffStat(workspaceID: WorkspaceID, additions: Int, deletions: Int, files: Int) throws {
        let current = try db.query(
            "SELECT additions, deletions, changed_files FROM workspaces WHERE id = ?",
            [.text(workspaceID)]
        ).first
        if let current,
           current.int("additions") == Int64(additions),
           current.int("deletions") == Int64(deletions),
           current.int("changed_files") == Int64(files) {
            return
        }
        try db.run(
            "UPDATE workspaces SET additions = ?, deletions = ?, changed_files = ? WHERE id = ?",
            [.int(Int64(additions)), .int(Int64(deletions)), .int(Int64(files)), .text(workspaceID)]
        )
    }

    public func touch(workspaceID: WorkspaceID, unread: Bool? = nil) throws {
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

    /// The setup script is a child of this process, so it cannot outlive the app: a row still
    /// `running` at launch is a run that was killed, never a run still going.
    ///
    /// `.pending` and not `.failed`, because the script never got to report anything. Calling it
    /// failed accuses it of something nobody witnessed and hangs a warning triangle on a workspace
    /// that is very likely fine; calling it succeeded is simply a lie. `.pending` stops the
    /// spinner, reads as "setup has not run yet" and leaves the re-run button inviting, which is
    /// the honest description. The appended log line is what separates this from a workspace whose
    /// setup genuinely never started.
    ///
    /// **Recovery is a transition, so it goes through the transition table like everything else.**
    /// This is one statement over every affected row rather than a read and a write each, because
    /// it runs on the launch path before a window exists and a user with sixty workspaces should
    /// not pay sixty round trips for it. What it must not become is a second opinion, so the states
    /// it selects and the state it writes are both asked of `SetupLifecycle` rather than spelled
    /// here, and the line it appends is `SetupEvent.runInterrupted.note`. Add a state to
    /// `SetupState` and this picks it up; change the table and this follows.
    public func recoverInterruptedSetups() throws {
        let event = SetupEvent.runInterrupted
        var sources: [SetupState] = []
        var destination: SetupState?
        for state in SetupState.allCases {
            guard case .moves(let next) = state.transition(on: event) else { continue }
            sources.append(state)
            destination = next
        }
        guard let destination, !sources.isEmpty, let note = event.note else { return }

        let placeholders = sources.map { _ in "?" }.joined(separator: ", ")
        try db.run(
            """
            UPDATE workspaces
            SET setup_state = ?,
                setup_log = CASE WHEN setup_log = '' THEN ? ELSE setup_log || char(10) || ? END
            WHERE setup_state IN (\(placeholders))
            """,
            [.text(destination.rawValue), .text(note), .text(note)]
                + sources.map { SQLValue.text($0.rawValue) }
        )
    }

    // MARK: - Workspaces an agent asked for

    /// The workspaces started by the agent running in this one, read from the database rather
    /// than counted in memory, so the answer survives Bloom being reopened while children are
    /// still running. `parent_workspace_id` has had an index since the column was added.
    ///
    /// Archived ones are out by default, because this is the list a person or an agent is shown,
    /// and an archived workspace is one that has been dealt with. It is also what
    /// `WorkspaceStartTool` counts against its limit, which is a limit on what is running.
    public func workspaces(startedBy parentWorkspaceID: WorkspaceID, includeArchived: Bool = false) throws -> [Workspace] {
        let sql = includeArchived
            ? "SELECT * FROM workspaces WHERE parent_workspace_id = ? ORDER BY created_at"
            : "SELECT * FROM workspaces WHERE parent_workspace_id = ? AND state = 'active' ORDER BY created_at"
        return try db.query(sql, [.text(parentWorkspaceID)]).map(Self.workspace(from:))
    }

    /// How many workspaces the agent in this one has ever started, archived ones included, and
    /// with no way to ask otherwise.
    ///
    /// **Nothing in the app gates on this today, and that is a decision, not an accident.**
    /// `WorkspaceStartTool` limits what is running, and its own tests pin that archiving frees
    /// the allowance. This count answers the other question, how much has ever been spent, which
    /// an ever-count budget would need: an allowance that archiving hands back is one an agent
    /// can spend for ever, start, archive, start again. If that ceiling is ever wanted, this is
    /// the number it is counted against, so there is no `includeArchived` parameter to pass the
    /// wrong way by accident.
    public func countWorkspaces(startedBy parentWorkspaceID: WorkspaceID) throws -> Int {
        let rows = try db.query(
            "SELECT COUNT(*) AS n FROM workspaces WHERE parent_workspace_id = ?",
            [.text(parentWorkspaceID)]
        )
        return Int(rows.first?.int("n") ?? 0)
    }

    /// The workspaces the owner's own client cut through `workspace_start` since a moment in
    /// time, oldest first.
    ///
    /// The rows are the ones with a spawn id and no parent, which is exactly `.ownerClient`. A
    /// workspace made in the Create sheet has neither column and is not here, and that separation
    /// is the whole reason the case exists: a person who made six workspaces by hand this morning
    /// must not find the tool refusing them a seventh.
    ///
    /// **Archived ones count**, which is the opposite of `workspaces(startedBy:)` and deliberate.
    /// That one limits how many are running, and archiving deals with one. This one asks how many
    /// worktrees were cut in a window, and archiving one does not un-cut it.
    public func workspacesStartedByOwnerClient(since: Date) throws -> [Workspace] {
        try db.query(
            """
            SELECT * FROM workspaces
            WHERE parent_workspace_id IS NULL AND spawn_tool_use_id IS NOT NULL
              AND created_at >= ?
            ORDER BY created_at
            """,
            [.double(since.timeIntervalSince1970)]
        ).map(Self.workspace(from:))
    }

    /// The workspaces one spawn tool call has already made, archived ones included.
    ///
    /// A tool call is retried: by the model, by the transport, and by whatever is driving both.
    /// Asking this before cutting anything is how a repeat of a call is told apart from a second
    /// request, and archived rows count because a retry arriving after the workspace was archived
    /// still must not cut a fresh worktree.
    public func workspaces(spawnToolUseID: String) throws -> [Workspace] {
        try db.query(
            "SELECT * FROM workspaces WHERE spawn_tool_use_id = ? ORDER BY created_at",
            [.text(spawnToolUseID)]
        ).map(Self.workspace(from:))
    }

    public func nextWorkspaceSortOrder(repoID: RepoID) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(sort_order), -1) AS m FROM workspaces WHERE repo_id = ?",
            [.text(repoID)]
        )
        return Int(rows.first?.int("m") ?? -1) + 1
    }

    // MARK: - Sessions

    public func sessions(workspaceID: WorkspaceID) throws -> [Session] {
        try db.query(
            "SELECT * FROM sessions WHERE workspace_id = ? AND archived_at IS NULL ORDER BY sort_order, created_at",
            [.text(workspaceID)]
        ).map(Self.session(from:))
    }

    public func session(id: SessionID) throws -> Session? {
        try db.query("SELECT * FROM sessions WHERE id = ?", [.text(id)]).first.map(Self.session(from:))
    }

    /// Every chat the store says is mid turn or blocked, across every active workspace.
    ///
    /// The durable half of "is an agent working here". The runner writes `state` on every move it
    /// makes, whether or not a window is watching, so this answers for a chat nobody has opened
    /// this launch and it answers again after a missed signal. See `AgentTurns`, which is what
    /// weighs it against what the live transcripts say, and the sidebar row that spent a whole
    /// turn drawing "No changes" over a running agent because nothing asked this question.
    ///
    /// Three columns rather than whole rows: this runs on every write to the sessions table, and
    /// a title, two token counts and a cost are not part of the answer.
    ///
    /// The states come from `AgentTurns.Kind` rather than being spelled out here, the way
    /// `resetRunningSessions` builds its clause out of `SessionLifecycle`, so the rows this hands
    /// back and the rule that reads them cannot come to different conclusions about which states
    /// count. Archived chats and archived workspaces are left out: neither can have an agent in it,
    /// and a sidebar that has no row to draw has nothing to say about one.
    public func sessionActivity() throws -> [SessionActivity] {
        let states = AgentTurns.Kind.allCases.map(\.sessionState)
        let placeholders = states.map { _ in "?" }.joined(separator: ", ")
        return try db.query(
            """
            SELECT s.id AS id, s.workspace_id AS workspace_id, s.state AS state
            FROM sessions s
            JOIN workspaces w ON w.id = s.workspace_id
            WHERE s.archived_at IS NULL AND w.state = ? AND s.state IN (\(placeholders))
            """,
            [.text(WorkspaceState.active.rawValue)] + states.map { SQLValue.text($0.rawValue) }
        ).map { row in
            SessionActivity(
                sessionID: SessionID(row.string("id") ?? newID()),
                workspaceID: WorkspaceID(row.string("workspace_id") ?? ""),
                state: SessionState(rawValue: row.string("state") ?? "idle") ?? .idle
            )
        }
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
        sessionID: SessionID,
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
        id: SessionID,
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
    public func reorderSessions(ids: [SessionID]) throws {
        try db.transaction {
            for (order, id) in ids.enumerated() {
                try db.run(
                    "UPDATE sessions SET sort_order = ? WHERE id = ?",
                    [.int(Int64(order)), .text(id)]
                )
            }
        }
    }

    public func updateLastReadSeq(sessionID: SessionID, seq: Int) throws {
        try db.run(
            "UPDATE sessions SET last_read_seq = ? WHERE id = ?",
            [.int(Int64(seq)), .text(sessionID)]
        )
    }

    public func deleteSession(id: SessionID) throws {
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
    ///
    /// The two paragraphs above are the reasoning, and `SessionLifecycle` is where it is written
    /// down as a rule. This asks that table which states `appRelaunched` moves and where it moves
    /// them, so the bulk pass and the machine cannot come to different conclusions about what an
    /// interrupted launch left behind.
    public func resetRunningSessions() throws {
        var sources: [SessionState] = []
        var destination: SessionState?
        for state in SessionState.allCases {
            guard case .moves(let next) = state.transition(on: .appRelaunched) else { continue }
            sources.append(state)
            destination = next
        }
        guard let destination, !sources.isEmpty else { return }

        let placeholders = sources.map { _ in "?" }.joined(separator: ", ")
        try db.run(
            "UPDATE sessions SET state = ? WHERE state IN (\(placeholders))",
            [.text(destination.rawValue)] + sources.map { SQLValue.text($0.rawValue) }
        )
    }

    // MARK: - Messages

    public func messages(sessionID: SessionID, afterSeq: Int = -1, limit: Int = 100_000) throws -> [Message] {
        try db.query(
            "SELECT * FROM messages WHERE session_id = ? AND seq > ? ORDER BY seq LIMIT ?",
            [.text(sessionID), .int(Int64(afterSeq)), .int(Int64(limit))]
        ).map(Self.message(from:))
    }

    public func messageCount(sessionID: SessionID) throws -> Int {
        Int(try db.query(
            "SELECT COUNT(*) AS c FROM messages WHERE session_id = ?",
            [.text(sessionID)]
        ).first?.int("c") ?? 0)
    }

    public func nextSeq(sessionID: SessionID) throws -> Int {
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
        sessionID: SessionID,
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

    private func nextSeqLocked(sessionID: SessionID) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(seq), -1) AS m FROM messages WHERE session_id = ?",
            [.text(sessionID)]
        )
        return Int(rows.first?.int("m") ?? -1) + 1
    }

    private func insert(_ message: Message) throws -> Int64 {
        let id = try db.run(
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
        // Here rather than in a trigger, and here rather than in a task afterwards: this is the
        // one place a transcript row is created, so indexing it here is what makes the index a
        // fact about the table rather than a cache that can drift. `appendNext` already wraps
        // this in a transaction; `append` does not, and a single statement is its own.
        try indexMessage(id: id, kind: message.kind, payload: message.payload)
        return id
    }

    private func indexMessage(id: Int64, kind: MessageKind, payload: Data) throws {
        guard let body = TranscriptSearchText.indexable(kind: kind, payload: payload) else { return }
        try db.run(
            "INSERT INTO message_search (rowid, body) VALUES (?, ?)",
            [.int(id), .text(body)]
        )
    }

    // MARK: - Transcript search

    /// Where the one time backfill has got to: the lowest message id that is already indexed.
    /// In `settings` rather than in a column or a file because it has to survive a crash, and
    /// because the whole of the resume logic is then one integer that a `SELECT` can read.
    static let backfillCursorKey = "transcriptSearchBackfillCursor"

    /// How many rows one backfill step does.
    ///
    /// Small enough that the actor is handed back between batches, so a turn arriving mid backfill
    /// waits milliseconds rather than minutes. Measured on the owner's database: a batch of a
    /// thousand takes about 90ms, of which most is the JSON walk.
    public static let backfillBatch = 1_000

    public struct BackfillProgress: Sendable, Hashable {
        /// Rows read in this step, indexed or not: a row with no words in it is progress too.
        public var scanned: Int
        /// Rows still below the cursor, so a caller can show it or log it.
        public var remaining: Int
        public var isFinished: Bool { remaining == 0 }
    }

    /// Indexes one batch of the transcripts that existed before this feature did, newest first.
    ///
    /// **Newest first is the point.** Months of messages take a while to walk, and the workspace
    /// somebody searches for in the first minute is nearly always a recent one, so the index is
    /// useful long before it is complete rather than only at the end.
    ///
    /// **Safe to interrupt.** The batch and the cursor move in one transaction, so a process
    /// killed halfway through leaves the cursor where the last complete batch left it and the next
    /// launch redoes at most one batch. Redoing a batch is harmless: `INSERT OR REPLACE` on the
    /// rowid overwrites whatever was there.
    ///
    /// **Never blocks the launch.** Nothing calls this during `init`. The app kicks it off after
    /// its first screen is drawn and loops until `isFinished`, and every call is one hop onto this
    /// actor that yields in between.
    @discardableResult
    public func indexOlderTranscripts(batch: Int = backfillBatch) throws -> BackfillProgress {
        let cursor = Int64(try setting(Self.backfillCursorKey) ?? "") ?? 0
        guard cursor > 0 else { return BackfillProgress(scanned: 0, remaining: 0) }

        return try db.transaction {
            let rows = try db.query(
                "SELECT id, kind, payload FROM messages WHERE id < ? ORDER BY id DESC LIMIT ?",
                [.int(cursor), .int(Int64(batch))]
            )

            var lowest = cursor
            for row in rows {
                guard let id = row.int("id") else { continue }
                lowest = min(lowest, id)
                let kind = MessageKind(rawValue: row.string("kind") ?? "") ?? .system
                guard let body = TranscriptSearchText.indexable(
                    kind: kind, payload: row.data("payload") ?? Data()
                ) else { continue }
                try db.run(
                    "INSERT OR REPLACE INTO message_search (rowid, body) VALUES (?, ?)",
                    [.int(id), .text(body)]
                )
            }

            // A short batch means there was nothing more below the cursor, and the cursor goes to
            // zero rather than to the lowest id seen: zero is the one value that says "finished"
            // without needing a second key to say it.
            let next = rows.count < batch ? 0 : lowest
            try db.run(
                "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                [.text(Self.backfillCursorKey), .text(String(next))]
            )

            let remaining = next == 0 ? 0 : Int(try db.query(
                "SELECT COUNT(*) AS c FROM messages WHERE id < ?", [.int(next)]
            ).first?.int("c") ?? 0)
            return BackfillProgress(scanned: rows.count, remaining: remaining)
        }
    }

    /// True while there is transcript history not yet in the index, so the search screen can say
    /// so instead of quietly returning half an answer.
    public func isTranscriptIndexIncomplete() throws -> Bool {
        (Int64(try setting(Self.backfillCursorKey) ?? "") ?? 0) > 0
    }

    /// Every workspace whose transcript matches, best first.
    ///
    /// Two queries rather than one. The first takes the top few hundred rows by bm25 and builds
    /// the snippets, which is the expensive half and is why it is capped. The second counts the
    /// matches per workspace over the whole index, so a workspace that appears once in the
    /// candidate list can still say it has ninety matches. Counting is an index-only walk and
    /// measured at a fraction of the ranked query.
    ///
    /// **Archived workspaces are included.** Old work is exactly what somebody is hunting for when
    /// they cannot remember which workspace it was, and the archive is where old work goes. The
    /// caller decides how to draw the two; the search does not decide for it.
    ///
    /// Measured on the owner's database, 1035 messages: between 0.1ms and 5.2ms, the slowest of
    /// them being a search for "the". Measured on a synthetic database built by replicating that
    /// same history until it held 264,960 messages and 573MB of payloads: 63ms for a real word and
    /// 180ms for "the", of which the ranked half is 54ms and 127ms and the count is the rest. That
    /// second number is a ceiling rather than a forecast, because replicating one history makes
    /// every term 256 times commoner than it would be in a database that large for real, and it is
    /// commonness that bm25 has to walk.
    public func searchTranscripts(
        _ query: String,
        limit: Int = TranscriptSearch.candidateLimit
    ) throws -> [TranscriptWorkspaceMatches] {
        guard let expression = TranscriptSearch.matchExpression(for: query) else { return [] }

        // `bm25` rather than `rank` so the score comes back with the row and can be looked at.
        // The snippet is built by FTS5 rather than in Swift because it already knows which terms
        // matched where, and doing it here would mean shipping whole message bodies across the
        // actor to find out. See `TranscriptSearch.snippet(from:)` for what the marks become.
        let rows = try db.query(
            """
            SELECT ms.rowid AS message_id, m.session_id, m.seq, m.kind, m.created_at,
                   s.workspace_id, s.title,
                   snippet(message_search, 0, ?, ?, '…', 14) AS marked,
                   bm25(message_search) AS score
            FROM message_search ms
            JOIN messages m ON m.id = ms.rowid
            JOIN sessions s ON s.id = m.session_id
            WHERE message_search MATCH ?
            ORDER BY score
            LIMIT ?
            """,
            [
                .text(TranscriptSearch.openMark), .text(TranscriptSearch.closeMark),
                .text(expression), .int(Int64(limit)),
            ]
        )

        let matches = rows.map { row in
            TranscriptMatch(
                messageID: row.int("message_id") ?? 0,
                workspaceID: WorkspaceID(row.string("workspace_id") ?? ""),
                sessionID: SessionID(row.string("session_id") ?? ""),
                sessionTitle: row.string("title") ?? "Session",
                seq: Int(row.int("seq") ?? 0),
                kind: MessageKind(rawValue: row.string("kind") ?? "") ?? .system,
                createdAt: row.date("created_at") ?? Date(),
                snippet: TranscriptSearch.snippet(from: row.string("marked") ?? ""),
                score: row.double("score") ?? 0
            )
        }

        var totals: [WorkspaceID: Int] = [:]
        for row in try db.query(
            """
            SELECT s.workspace_id AS workspace_id, COUNT(*) AS c
            FROM message_search ms
            JOIN messages m ON m.id = ms.rowid
            JOIN sessions s ON s.id = m.session_id
            WHERE message_search MATCH ?
            GROUP BY s.workspace_id
            """,
            [.text(expression)]
        ) {
            totals[WorkspaceID(row.string("workspace_id") ?? "")] = Int(row.int("c") ?? 0)
        }

        return TranscriptSearch.group(matches, totals: totals)
    }

    /// Puts the database back to what one written before this index existed looks like: the
    /// messages are all there and none of them is searchable. Internal, and only the suite that
    /// tests the backfill calls it, because a database in that state is the one thing the backfill
    /// has to cope with and there is no other way to produce it.
    func forgetTranscriptIndexForTesting() throws {
        try db.execute("DELETE FROM message_search;")
        try rewindTranscriptBackfillForTesting()
    }

    /// Puts the cursor back above every row, which is what an interrupted backfill that never got
    /// to commit its cursor leaves behind.
    func rewindTranscriptBackfillForTesting() throws {
        let highest = try db.query("SELECT COALESCE(MAX(id), 0) AS m FROM messages").first?.int("m") ?? 0
        try db.run(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            [.text(Self.backfillCursorKey), .text(String(highest + 1))]
        )
    }

    /// Find the stored toolUse row a tool_result belongs to.
    public func message(sessionID: SessionID, refID: String) throws -> Message? {
        try db.query(
            "SELECT * FROM messages WHERE session_id = ? AND ref_id = ? ORDER BY seq DESC LIMIT 1",
            [.text(sessionID), .text(refID)]
        ).first.map(Self.message(from:))
    }

    // MARK: - Drafts

    public func draft(sessionID: SessionID) throws -> String {
        try db.query("SELECT body FROM drafts WHERE session_id = ?", [.text(sessionID)])
            .first?.string("body") ?? ""
    }

    public func saveDraft(sessionID: SessionID, body: String) throws {
        if body.isEmpty {
            try db.run("DELETE FROM drafts WHERE session_id = ?", [.text(sessionID)])
        } else {
            try db.run(
                "INSERT INTO drafts (session_id, body) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET body = excluded.body",
                [.text(sessionID), .text(body)]
            )
        }
    }

    // MARK: - Workspace notes

    /// The workspace's note, or nothing when it has never had one. Nothing and an empty note are
    /// the same fact here, because `saveNote` deletes the row rather than storing a blank.
    public func note(workspaceID: WorkspaceID) throws -> WorkspaceNote? {
        try db.query(
            "SELECT * FROM workspace_notes WHERE workspace_id = ?", [.text(workspaceID)]
        ).first.map {
            WorkspaceNote(
                workspaceID: WorkspaceID($0.string("workspace_id") ?? workspaceID.rawValue),
                body: $0.string("body") ?? "",
                updatedAt: $0.date("updated_at") ?? Date()
            )
        }
    }

    /// Writes the workspace's note, or removes it when what is left is blank.
    ///
    /// It touches no other table, and in particular it does not touch `workspaces`. The pane that
    /// calls this is the slowest writer in the app and it must not be able to carry a stale
    /// workspace row back with it. See `WorkspaceNote`.
    public func saveNote(workspaceID: WorkspaceID, body: String, at date: Date = Date()) throws {
        let storable = WorkspaceNote.storable(body)
        if storable.isEmpty {
            try db.run("DELETE FROM workspace_notes WHERE workspace_id = ?", [.text(workspaceID)])
        } else {
            try db.run(
                """
                INSERT INTO workspace_notes (workspace_id, body, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(workspace_id)
                DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
                """,
                [.text(workspaceID), .text(storable), .double(date.timeIntervalSince1970)]
            )
        }
    }

    // MARK: - Agent quotas

    /// Every allowance any provider has reported and has not yet turned over.
    ///
    /// Expired rows are deleted here rather than filtered, because this is the only place that
    /// reliably runs after a long shutdown and a row for a five hour window that reset last week
    /// is not data, it is litter. Reading is the natural moment: the app was closed across the
    /// reset boundary, it comes back, it asks, and the answer it gets is the truth rather than
    /// last Tuesday's percentage sitting under a reset time in the past.
    ///
    /// A read that deletes is the one thing `StoreChangeHub` warns about, so the delete runs only
    /// when there is genuinely something to delete. Without that guard every reload would write,
    /// every write would wake the reload, and the app would sit warm and busy doing nothing.
    public func quotas(at now: Date = Date()) throws -> [AgentQuota] {
        let cutoff = now.timeIntervalSince1970
        let stale = try db.query(
            "SELECT COUNT(*) AS n FROM agent_quotas WHERE resets_at IS NOT NULL AND resets_at <= ?",
            [.double(cutoff)]
        ).first?.int("n") ?? 0
        if stale > 0 {
            try db.run(
                "DELETE FROM agent_quotas WHERE resets_at IS NOT NULL AND resets_at <= ?",
                [.double(cutoff)]
            )
        }
        return try db.query("SELECT * FROM agent_quotas").compactMap(Self.quota(from:))
    }

    /// Writes what a provider has just said about one or more of its windows.
    ///
    /// `INSERT ... ON CONFLICT` and not `upsert`, and the distinction the whole store turns on
    /// still applies: every column written here was built from the payload that arrived a moment
    /// ago, by the only writer this table has. There is no column on this row belonging to anybody
    /// else, so a whole-value write cannot roll back a write it never knew about.
    ///
    /// The `WHERE` clause is the guard that matters. Two workspaces on the same account both
    /// report the same window, and their turns finish in whatever order the two subprocesses
    /// happen to finish in, so a report that was already stale when it arrived must not overwrite
    /// a fresher one. Comparing `observed_at` makes the write idempotent and order independent.
    public func recordQuotas(_ quotas: [AgentQuota]) throws {
        for quota in quotas {
            let (used, limit, unit) = Self.columns(for: quota.measure)
            try db.run(
                """
                INSERT INTO agent_quotas
                    (provider, window_key, window_label, window_seconds,
                     used, limit_value, unit, resets_at, observed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, window_key) DO UPDATE SET
                    window_label = excluded.window_label,
                    window_seconds = excluded.window_seconds,
                    used = excluded.used,
                    limit_value = excluded.limit_value,
                    unit = excluded.unit,
                    resets_at = excluded.resets_at,
                    observed_at = excluded.observed_at
                WHERE excluded.observed_at >= agent_quotas.observed_at
                """,
                [
                    .text(quota.provider.rawValue),
                    .text(quota.window.key),
                    .text(quota.window.label),
                    quota.window.duration.map { SQLValue.double($0) } ?? .null,
                    used.map { SQLValue.double($0) } ?? .null,
                    limit.map { SQLValue.double($0) } ?? .null,
                    unit.map { SQLValue.text($0) } ?? .null,
                    quota.resetsAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                    .double(quota.observedAt.timeIntervalSince1970),
                ]
            )
        }
    }

    /// The sentinel that says the two numbers are a share rather than a count of something.
    static let fractionUnit = "fraction"

    private static func columns(for measure: QuotaMeasure) -> (Double?, Double?, String?) {
        switch measure {
        case .fraction(let value): (value, 1, fractionUnit)
        case .counted(let used, let limit, let unit): (used, limit, unit)
        case .unknown: (nil, nil, nil)
        }
    }

    private static func quota(from row: Row) -> AgentQuota? {
        guard let provider = row.string("provider").flatMap(AgentKind.init(rawValue:)),
              let key = row.string("window_key") else { return nil }
        let measure: QuotaMeasure
        if let used = row.double("used") {
            let unit = row.string("unit") ?? fractionUnit
            measure = unit == fractionUnit
                ? .fraction(used)
                : .counted(used: used, limit: row.double("limit_value"), unit: unit)
        } else {
            measure = .unknown
        }
        return AgentQuota(
            provider: provider,
            window: QuotaWindow(
                key: key,
                label: row.string("window_label") ?? QuotaWindow.humanised(key),
                duration: row.double("window_seconds")
            ),
            measure: measure,
            resetsAt: row.double("resets_at").map { Date(timeIntervalSince1970: $0) },
            observedAt: row.double("observed_at").map { Date(timeIntervalSince1970: $0) } ?? Date()
        )
    }

    // MARK: - Deliveries

    /// Everything asked for on this session that has not gone yet, oldest first.
    ///
    /// `created_at, rowid` and not `created_at` alone. The opening prompt and a sentence typed
    /// while the setup script is still running can land in the same millisecond, and putting them
    /// back in the wrong order is the bug this whole table exists to fix.
    public func pendingDeliveries(sessionID: SessionID) throws -> [Delivery] {
        try db.query(
            """
            SELECT * FROM deliveries
            WHERE target_session_id = ? AND delivered_at IS NULL
            ORDER BY created_at, rowid
            """,
            [.text(sessionID)]
        ).map(Self.delivery(from:))
    }

    /// Puts one at the back of the queue.
    ///
    /// The value is built here and now, so the id and the timestamp it is handed back with are
    /// the ones on disk. Callers hold that id to cancel the row again.
    @discardableResult
    public func enqueueDelivery(_ delivery: Delivery) throws -> Delivery {
        try db.run(
            """
            INSERT INTO deliveries
                (id, target_session_id, source_workspace_id, kind, verdict, body, created_at,
                 delivered_at, delivered_seq)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(delivery.id),
                .text(delivery.targetSessionID),
                delivery.sourceWorkspaceID.map { .text($0) } ?? .null,
                .text(delivery.kind.rawValue),
                delivery.verdict.map { .text($0) } ?? .null,
                .text(delivery.body),
                .double(delivery.createdAt.timeIntervalSince1970),
                delivery.deliveredAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                delivery.deliveredSeq.map { .int(Int64($0)) } ?? .null,
            ]
        )
        return delivery
    }

    /// Marks one as gone.
    ///
    /// Named columns rather than a whole-value write, which is the rule the head of this file is
    /// about: a delivery is read by the transcript to draw it and written by the drain to retire
    /// it, and those two are not ordered with respect to each other.
    ///
    /// `seq` is what the delivery became in the `messages` table where the caller knows it, which
    /// the owner's own path does not: the runner writes that row as part of starting the turn.
    /// See `Delivery.deliveredSeq`.
    public func markDelivered(id: DeliveryID, seq: Int? = nil, at date: Date = Date()) throws {
        try db.run(
            "UPDATE deliveries SET delivered_at = ?, delivered_seq = ? WHERE id = ?",
            [.double(date.timeIntervalSince1970), seq.map { .int(Int64($0)) } ?? .null, .text(id)]
        )
    }

    /// Takes one back out of the queue, because whoever asked for it changed their mind.
    ///
    /// Only while it is still pending. A delivery that has gone is a turn the agent is already
    /// running, and deleting the row would not unsay it; the `WHERE` is what makes a cancel
    /// pressed on the same frame the drain fires a no-op rather than a lie.
    ///
    /// **Returns whether a row actually went**, because a no-op and a delete are two different
    /// things to tell the owner: one of them means the sentence is gone and the other means the
    /// agent is already reading it. The caller cannot work that out for itself, and it is the one
    /// thing the race turns on. See `PendingMessageDiscard.alreadySentSentence`.
    ///
    /// The look and the delete are two statements with no suspension between them, which is the
    /// same reason `update(workspaceID:)` reads inside the actor: nothing else can retire the row
    /// in the gap, because there is no gap.
    @discardableResult
    public func cancelDelivery(id: DeliveryID) throws -> Bool {
        let pending = try db.query(
            "SELECT id FROM deliveries WHERE id = ? AND delivered_at IS NULL", [.text(id)]
        )
        guard !pending.isEmpty else { return false }
        try db.run("DELETE FROM deliveries WHERE id = ? AND delivered_at IS NULL", [.text(id)])
        return true
    }

    /// Puts one back in the queue after a send that never started a turn.
    ///
    /// The drain retires a delivery before handing it over, so the bubble does not flash on screen
    /// for the one frame between the two. When the runner refuses to start there is nothing to
    /// retire it for, and a message the agent never received must go back to being pending rather
    /// than reading as sent.
    public func restoreDelivery(id: DeliveryID) throws {
        try db.run(
            "UPDATE deliveries SET delivered_at = NULL, delivered_seq = NULL WHERE id = ?",
            [.text(id)]
        )
    }

    // MARK: - Review comments

    public func reviewComments(workspaceID: WorkspaceID) throws -> [ReviewComment] {
        try db.query(
            "SELECT * FROM review_comments WHERE workspace_id = ? ORDER BY file_path, line, created_at, id",
            [.text(workspaceID)]
        ).map(Self.reviewComment(from:))
    }

    public func reviewComments(workspaceID: WorkspaceID, filePath: String) throws -> [ReviewComment] {
        try db.query(
            """
            SELECT * FROM review_comments WHERE workspace_id = ? AND file_path = ?
            ORDER BY line, created_at, id
            """,
            [.text(workspaceID), .text(filePath)]
        ).map(Self.reviewComment(from:))
    }

    /// The ones that actually go out with the next message.
    public func attachedReviewComments(workspaceID: WorkspaceID) throws -> [ReviewComment] {
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
    public func updateReviewCommentBody(id: ReviewCommentID, body: String) throws {
        try db.run("UPDATE review_comments SET body = ? WHERE id = ?", [.text(body), .text(id)])
    }

    public func setReviewCommentAttached(id: ReviewCommentID, attached: Bool) throws {
        try db.run(
            "UPDATE review_comments SET attached = ? WHERE id = ?",
            [.int(attached ? 1 : 0), .text(id)]
        )
    }

    /// What "Remove from chat" does to the whole set once the message has gone out. The comments
    /// stay readable in the diff, they just stop being sent again with every following turn.
    public func detachReviewComments(workspaceID: WorkspaceID) throws {
        try db.run(
            "UPDATE review_comments SET attached = 0 WHERE workspace_id = ?",
            [.text(workspaceID)]
        )
    }

    public func deleteReviewComment(id: ReviewCommentID) throws {
        try db.run("DELETE FROM review_comments WHERE id = ?", [.text(id)])
    }

    public func deleteReviewComments(workspaceID: WorkspaceID) throws {
        try db.run("DELETE FROM review_comments WHERE workspace_id = ?", [.text(workspaceID)])
    }

    // MARK: - Quick prompts

    /// The whole list, in the order the panel draws it before anything is searched for.
    public func quickPrompts() throws -> [QuickPrompt] {
        try db.query("SELECT * FROM quick_prompt ORDER BY sort_order, created_at, id")
            .map(Self.quickPrompt(from:))
    }

    public func quickPrompt(id: QuickPromptID) throws -> QuickPrompt? {
        try db.query("SELECT * FROM quick_prompt WHERE id = ?", [.text(id)])
            .first.map(Self.quickPrompt(from:))
    }

    /// Writes a new prompt. `insert` rather than `upsert`, because every column here is the
    /// owner's and a row that already exists is changed through `update(quickPromptID:)`: see the
    /// rule at the head of this file. A prompt with an id the table already holds is a bug rather
    /// than an edit, so the insert is left to fail rather than made to overwrite.
    ///
    /// The order it lands in is worked out here, inside the actor, so two prompts written in the
    /// same moment cannot both read the same maximum and share a place in the list.
    @discardableResult
    public func insert(_ prompt: QuickPrompt) throws -> QuickPrompt {
        var row = prompt
        row.sortOrder = try nextQuickPromptOrder()
        try insertQuickPromptRow(row)
        return row
    }

    /// Changes an existing prompt without writing the columns it did not mean to change.
    ///
    /// The same shape as `update(workspaceID:)`, and for the same reason: the row is read here,
    /// inside the actor, immediately before it is written back, with no suspension in between, so
    /// a form somebody sat in for a minute cannot carry the rest of the row back to what it looked
    /// like when they opened it.
    @discardableResult
    public func update(
        quickPromptID: QuickPromptID,
        _ change: @Sendable (inout QuickPrompt) -> Void
    ) throws -> QuickPrompt? {
        guard var row = try quickPrompt(id: quickPromptID) else { return nil }
        change(&row)
        try db.run(
            """
            UPDATE quick_prompt
            SET name = ?, symbol = ?, text = ?, sends_immediately = ?, opens_new_chat = ?
            WHERE id = ?
            """,
            [
                .text(row.name), .text(row.symbol), .text(row.text),
                .int(row.sendsImmediately ? 1 : 0), .int(row.opensNewChat ? 1 : 0),
                .text(quickPromptID),
            ]
        )
        row.id = quickPromptID
        return row
    }

    public func deleteQuickPrompt(id: QuickPromptID) throws {
        try db.run("DELETE FROM quick_prompt WHERE id = ?", [.text(id)])
    }

    /// Puts the built-ins in, once ever, and answers with the list as it stands afterwards.
    ///
    /// **Deleting a built-in has to stick.** So this compares the version the database has already
    /// seeded against `QuickPromptSeed.version` rather than comparing the built-in list against the
    /// table: a prompt the owner deleted is not missing, it is deleted, and nothing here can tell
    /// those apart by looking at the rows. Adding a second built-in later means a new entry with a
    /// higher `introducedIn` and a bump of the version, which inserts that one and resurrects
    /// nothing. See `QuickPromptSeed`.
    @discardableResult
    public func seedQuickPrompts(now: Date = Date()) throws -> [QuickPrompt] {
        let installed = Int(try setting(QuickPromptSeed.versionKey) ?? "") ?? 0
        let pending = QuickPromptSeed.pending(installed: installed)
        guard !pending.isEmpty else { return try quickPrompts() }

        var order = try nextQuickPromptOrder()
        for entry in pending {
            try insertQuickPromptRow(entry.prompt(sortOrder: order, now: now))
            order += 1
        }
        try setSetting(QuickPromptSeed.versionKey, String(QuickPromptSeed.version))
        return try quickPrompts()
    }

    private func nextQuickPromptOrder() throws -> Int {
        let highest = try db.query("SELECT COALESCE(MAX(sort_order), -1) AS m FROM quick_prompt")
            .first?.int("m") ?? -1
        return Int(highest) + 1
    }

    private func insertQuickPromptRow(_ prompt: QuickPrompt) throws {
        try db.run(
            """
            INSERT INTO quick_prompt (
                id, name, symbol, text, sends_immediately, opens_new_chat, sort_order, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(prompt.id), .text(prompt.name), .text(prompt.symbol), .text(prompt.text),
                .int(prompt.sendsImmediately ? 1 : 0), .int(prompt.opensNewChat ? 1 : 0),
                .int(Int64(prompt.sortOrder)),
                .double(prompt.createdAt.timeIntervalSince1970),
            ]
        )
    }

    // MARK: - Permission grants

    /// Every rule granted in one project, newest first. This is the revocation list.
    public func permissionGrants(repoID: RepoID) throws -> [PermissionGrant] {
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
    public func recordPermissionGrantUse(id: PermissionGrantID, at date: Date = Date()) throws {
        try db.run(
            "UPDATE permission_grants SET use_count = use_count + 1, last_used_at = ? WHERE id = ?",
            [.double(date.timeIntervalSince1970), .text(id)]
        )
    }

    /// Take one back. Immediate: nothing caches these, and the next ask reads the table again.
    public func deletePermissionGrant(id: PermissionGrantID) throws {
        try db.run("DELETE FROM permission_grants WHERE id = ?", [.text(id)])
    }

    public func deletePermissionGrants(repoID: RepoID) throws {
        try db.run("DELETE FROM permission_grants WHERE repo_id = ?", [.text(repoID)])
    }

    // MARK: - Pending permission asks

    /// File a question. Idempotent on the request id, so a replayed line cannot double up.
    public func appendPermissionAsk(sessionID: SessionID, ask: PermissionAsk, at date: Date = Date()) throws {
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
    public func pendingPermissionAsks(sessionID: SessionID) throws -> [PendingPermissionAsk] {
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
    public func permissionAskDecisions(sessionID: SessionID) throws -> [String: String] {
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

    /// Every row, because the one caller left is the migration that drains the table and it wants
    /// all of them. Per workspace, it was a query each and `terminal_tabs` has no index on
    /// `workspace_id`, so each was a full scan. Nothing is indexed instead: after the migration
    /// the table is empty, and the only other statement here is keyed on the primary key.
    public func terminalTabs() throws -> [TerminalTab] {
        try db.query(
            "SELECT * FROM terminal_tabs ORDER BY workspace_id, sort_order"
        ).map {
            TerminalTab(
                id: TerminalTabID($0.string("id") ?? newID()),
                workspaceID: WorkspaceID($0.string("workspace_id") ?? ""),
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

    public func deleteTerminalTab(id: TerminalTabID) throws {
        try db.run("DELETE FROM terminal_tabs WHERE id = ?", [.text(id)])
    }

    // MARK: - Oceans

    public func oceans() throws -> [Ocean] {
        try db.query("SELECT * FROM oceans ORDER BY name").map(Self.ocean(from:))
    }

    public func unusedOceanCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM oceans WHERE used_at IS NULL").first?.int("n") ?? 0)
    }

    /// Spends a sea, or repeats one once the catalogue has run dry.
    ///
    /// The random pick and the write happen inside the actor with no suspension between them, so
    /// two workspaces created back to back cannot draw the same sea as a first use. A repeat
    /// comes back with its stored `used_at` untouched, because that date records the discovery
    /// and a repeat is not one. Nil only when the table is empty, which seeding makes impossible,
    /// but a defensive nil beats a crash in the middle of creating a workspace.
    public func claimOcean(now: Date = Date()) throws -> OceanPick? {
        if let row = try db.query(
            "SELECT * FROM oceans WHERE used_at IS NULL ORDER BY RANDOM() LIMIT 1"
        ).first {
            var ocean = Self.ocean(from: row)
            ocean.usedAt = now
            try db.run(
                "UPDATE oceans SET used_at = ? WHERE slug = ?",
                [.double(now.timeIntervalSince1970), .text(ocean.slug)]
            )
            return OceanPick(
                ocean: ocean, isFirstUse: true, remainingUndiscovered: try unusedOceanCount()
            )
        }
        guard let row = try db.query("SELECT * FROM oceans ORDER BY RANDOM() LIMIT 1").first else {
            return nil
        }
        return OceanPick(ocean: Self.ocean(from: row), isFirstUse: false, remainingUndiscovered: 0)
    }

    // MARK: - Row mapping

    private static func repo(from row: Row) -> Repo {
        Repo(
            id: RepoID(row.string("id") ?? newID()),
            name: row.string("name") ?? "",
            path: row.string("path") ?? "",
            defaultBranch: row.string("default_branch") ?? "main",
            accent: row.string("accent") ?? Accent.all[0],
            sortOrder: Int(row.int("sort_order") ?? 0),
            collapsed: row.bool("collapsed"),
            hidden: row.bool("hidden"),
            createdAt: row.date("created_at") ?? Date(),
            iconPath: row.string("icon_path"),
            iconSource: RepoIconSource(rawValue: row.string("icon_source") ?? "") ?? .undetected
        )
    }

    private static func workspace(from row: Row) -> Workspace {
        Workspace(
            id: WorkspaceID(row.string("id") ?? newID()),
            repoID: RepoID(row.string("repo_id") ?? ""),
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
            colour: row.string("colour"),
            origin: WorkspaceOrigin(
                parentWorkspaceID: row.string("parent_workspace_id"),
                spawnToolUseID: row.string("spawn_tool_use_id")
            ),
            port: Int(row.int("port") ?? 0)
        )
    }

    private static func delivery(from row: Row) -> Delivery {
        Delivery(
            id: DeliveryID(row.string("id") ?? newID()),
            targetSessionID: SessionID(row.string("target_session_id") ?? ""),
            sourceWorkspaceID: row.string("source_workspace_id").map(WorkspaceID.init),
            // An unknown word is the owner's, because that is the only kind this app has ever
            // written and a row it cannot classify is still a sentence somebody is waiting on.
            kind: Delivery.Kind(rawValue: row.string("kind") ?? "") ?? .owner,
            verdict: row.string("verdict"),
            body: row.string("body") ?? "",
            createdAt: row.date("created_at") ?? Date(),
            deliveredAt: row.date("delivered_at"),
            deliveredSeq: row.int("delivered_seq").map(Int.init)
        )
    }

    private static func permissionGrant(from row: Row) -> PermissionGrant {
        let content = row.string("rule_content") ?? ""
        return PermissionGrant(
            id: PermissionGrantID(row.string("id") ?? newID()),
            repoID: RepoID(row.string("repo_id") ?? ""),
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
            sessionID: SessionID(row.string("session_id") ?? ""),
            ask: ask,
            askedAt: row.date("created_at") ?? Date()
        )
    }

    private static func session(from row: Row) -> Session {
        Session(
            id: SessionID(row.string("id") ?? newID()),
            workspaceID: WorkspaceID(row.string("workspace_id") ?? ""),
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

    private static func quickPrompt(from row: Row) -> QuickPrompt {
        QuickPrompt(
            id: QuickPromptID(row.string("id") ?? newID()),
            name: row.string("name") ?? "",
            symbol: row.string("symbol") ?? QuickPrompt.defaultSymbol,
            text: row.string("text") ?? "",
            // A row read before the migration ran, or through a query that did not name the
            // column, has no value here at all, and no value means the prompt behaves the way it
            // always has. See `QuickPromptDelivery`.
            sendsImmediately: row.int("sends_immediately") == 1,
            opensNewChat: row.int("opens_new_chat") == 1,
            sortOrder: Int(row.int("sort_order") ?? 0),
            createdAt: row.date("created_at") ?? Date()
        )
    }

    private static func reviewComment(from row: Row) -> ReviewComment {
        ReviewComment(
            id: ReviewCommentID(row.string("id") ?? newID()),
            workspaceID: WorkspaceID(row.string("workspace_id") ?? ""),
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
            sessionID: SessionID(row.string("session_id") ?? ""),
            seq: Int(row.int("seq") ?? 0),
            kind: MessageKind(rawValue: row.string("kind") ?? "") ?? .system,
            payload: row.data("payload") ?? Data(),
            createdAt: row.date("created_at") ?? Date(),
            durationMS: row.int("duration_ms").map(Int.init),
            refID: row.string("ref_id")
        )
    }

    private static func ocean(from row: Row) -> Ocean {
        Ocean(
            name: row.string("name") ?? "",
            slug: row.string("slug") ?? "",
            latitude: row.double("latitude") ?? 0,
            longitude: row.double("longitude") ?? 0,
            usedAt: row.date("used_at")
        )
    }
}
