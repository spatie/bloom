import Foundation

extension Store {
    /// Adds every catalogue sea the table does not have yet, and touches nothing it does.
    ///
    /// On every open rather than only in the migration that made the table, because the seeding
    /// migration has already run on every real database and a sea added to the catalogue later
    /// would otherwise never reach one. A migration step of its own per catalogue change would
    /// work until two branches each appended one, which is the numbering race `repairSchema`
    /// describes. `INSERT OR IGNORE` leaves a claimed row's `used_at` exactly where it was, and
    /// inside one transaction the few hundred inserts cost nothing worth measuring.
    nonisolated static func seedOceans(_ db: SQLiteDatabase) throws {
        for ocean in OceanCatalog.all {
            try db.run(
                "INSERT OR IGNORE INTO oceans (slug, name, latitude, longitude) VALUES (?, ?, ?, ?)",
                [
                    .text(ocean.slug), .text(ocean.name),
                    .double(ocean.latitude), .double(ocean.longitude),
                ]
            )
        }
    }

    // MARK: - Migrations

    /// What a migration refuses to finish over.
    ///
    /// One case, because there is one step in the list that can take rows with it: the sessions
    /// rebuild drops a table other tables cascade from, and a count that came back short means the
    /// cascade fired. Thrown from inside the migration transaction, so the schema and the rows go
    /// back to what they were and the app opens on the old shape rather than on a shorter
    /// transcript.
    public enum StoreTrouble: Error, Sendable {
        case rebuildLostRows(table: String, before: Int64, after: Int64)
    }

    /// One migration step. Most are a block of SQL, but a step that has to look at the rows it is
    /// about to constrain needs real code, so the list holds closures rather than strings.
    private typealias Migration = @Sendable (SQLiteDatabase) throws -> Void

    private nonisolated static func sql(_ statements: String) -> Migration {
        { try $0.execute(statements) }
    }

    /// Columns the code in this build cannot run without, added to any database that is missing
    /// one whatever its version number says.
    ///
    /// **The version stamp is a fast path, not the truth, and this is the incident that proved
    /// it.** The owner's database read `user_version = 22` with `deliveries.crew_payload` present
    /// and `sessions.parent_session_id` absent, so every query naming that column failed and the
    /// app could not open the database at all. `migrate` had nothing to do: 22 is the length of
    /// the list, so it returned before running a step.
    ///
    /// How a database gets into that state is the hazard of numbering migrations by position. Two
    /// branches each append a step, both get the same number, and a database that ran one of them
    /// is stamped as having run the other. Merging the branches cannot repair it, because the
    /// stamp is already past both. Nothing about that is unusual enough to design against with a
    /// second numbering scheme; what is worth doing is asking the schema rather than the stamp
    /// before trusting it.
    ///
    /// So this runs on every open, costs one `PRAGMA table_info` per table named here, and adds
    /// only what is genuinely missing. It is deliberately a short list: the columns whose absence
    /// stops the app dead rather than every column the schema has. A migration is still where a
    /// change is written; this is the belt under it.
    /// The `workspaces.kind` column, shared by its migration and by `repairSchema`.
    nonisolated static let workspaceKindColumn =
        "ALTER TABLE workspaces ADD COLUMN kind TEXT NOT NULL DEFAULT 'worktree';"

    /// At most one live project checkout per project. See `WorkspaceKind.liveProjectCheckout`.
    nonisolated static let oneProjectCheckoutIndex =
        "CREATE UNIQUE INDEX IF NOT EXISTS workspaces_one_project_checkout ON workspaces(repo_id) "
            + "WHERE kind = 'project_checkout' AND state = 'active';"

    private nonisolated static func repairSchema(_ db: SQLiteDatabase) throws {
        let required: [(table: String, column: String, add: String, index: String?)] = [
            (
                "sessions", "parent_session_id",
                "ALTER TABLE sessions ADD COLUMN parent_session_id TEXT;",
                "CREATE INDEX IF NOT EXISTS sessions_parent ON sessions(parent_session_id);"
            ),
            (
                "sessions", "side_conversation_parent_id",
                "ALTER TABLE sessions ADD COLUMN side_conversation_parent_id TEXT;",
                "CREATE INDEX IF NOT EXISTS sessions_side_parent ON sessions(side_conversation_parent_id);"
            ),
            (
                "deliveries", "crew_payload",
                "ALTER TABLE deliveries ADD COLUMN crew_payload BLOB;",
                nil
            ),
            // Not fatal to open, and here all the same: `upsert` names this column, every caller
            // writing a review comment does so through a `try?`, and the loss is a note somebody
            // typed disappearing without a word. That is the one failure the review is most
            // careful about everywhere else, and this list is where the numbering race that would
            // cause it is already answered.
            (
                "review_comments", "span",
                "ALTER TABLE review_comments ADD COLUMN span INTEGER NOT NULL DEFAULT 1;",
                nil
            ),
            ("workspaces", "kind", Self.workspaceKindColumn, Self.oneProjectCheckoutIndex),
        ]

        for wanted in required {
            let columns = try db.query("PRAGMA table_info(\(wanted.table));")
            let names = Set(columns.compactMap { $0.string("name") })
            // An empty answer is a table this database does not have, which is not this method's
            // business: a missing table is a migration that has not run yet, and this runs before
            // they do. An ALTER against it would fail rather than repair anything, and it did:
            // the first version of this method put a bare `CREATE INDEX` under the loop and a
            // brand new database could not be opened at all.
            guard !names.isEmpty, !names.contains(wanted.column) else { continue }
            try db.execute(wanted.add)
            if let index = wanted.index { try db.execute(index) }
        }
    }

    nonisolated static func migrate(_ db: SQLiteDatabase) throws {
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
                try seedOceans(db)
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

            // The chat that belongs to no workspace: Ask Bloom, which has a transcript, a cost and
            // a permission history, and no worktree for any of it to hang off.
            //
            // `workspace_id` has been `NOT NULL` since the first step in this list, and SQLite
            // cannot drop a `NOT NULL` in place, so this is the first table rebuild here against
            // forty-odd `ADD COLUMN` steps. The order is SQLite's own recipe: build the new table,
            // copy every row, drop the old one, rename the new one over it.
            //
            // **Foreign keys have to be off while that runs, and this is the reason `migrate` turns
            // them off rather than a tidiness.** With them on, `DROP TABLE sessions` performs an
            // implicit `DELETE FROM` that fires `ON DELETE CASCADE` into `messages`, `drafts`,
            // `permission_asks` and `handoffs`: the whole transcript would go out with the
            // constraint, in a step whose purpose is to relax one. The count check below is that
            // fear written down, because a migration that quietly emptied a table is the one kind
            // this list must never ship.
            //
            // Replayable, like every step above: it reads the column's own `notnull` flag and
            // returns when the rebuild has already happened, so the store's tests can rewind
            // `user_version` over the new shape without this throwing.
            { db in
                let columns = try db.query("PRAGMA table_info(sessions);")
                let workspaceColumn = columns.first { $0.string("name") == "workspace_id" }
                guard workspaceColumn?.int("notnull") == 1 else { return }

                let before = try db.query("SELECT COUNT(*) AS n FROM messages").first?.int("n") ?? 0
                try db.execute("""
                    CREATE TABLE sessions_rebuilt (
                        id TEXT PRIMARY KEY,
                        workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
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

                    INSERT INTO sessions_rebuilt (
                        id, workspace_id, title, agent_session_id, model, effort, agent_kind,
                        permission_mode, state, sort_order, created_at, updated_at, archived_at,
                        last_read_seq, input_tokens, output_tokens, cost_usd, context_tokens
                    )
                    SELECT
                        id, workspace_id, title, agent_session_id, model, effort, agent_kind,
                        permission_mode, state, sort_order, created_at, updated_at, archived_at,
                        last_read_seq, input_tokens, output_tokens, cost_usd, context_tokens
                    FROM sessions;

                    DROP TABLE sessions;
                    ALTER TABLE sessions_rebuilt RENAME TO sessions;
                    CREATE INDEX IF NOT EXISTS sessions_workspace ON sessions(workspace_id);
                    """)

                let after = try db.query("SELECT COUNT(*) AS n FROM messages").first?.int("n") ?? 0
                guard after == before else {
                    throw StoreTrouble.rebuildLostRows(table: "messages", before: before, after: after)
                }
            },

            // The chat that started this one, for a crew member. See `Session.parentSessionID`
            // and `Crew`. Guarded on the column's absence rather than run blind, because the
            // store's own tests rewind `user_version` and replay every migration over a shape
            // that already has it.
            { db in
                let columns = try db.query("PRAGMA table_info(sessions);")
                let names = Set(columns.compactMap { $0.string("name") })
                if !names.contains("parent_session_id") {
                    try db.execute("ALTER TABLE sessions ADD COLUMN parent_session_id TEXT;")
                }
                try db.execute(
                    "CREATE INDEX IF NOT EXISTS sessions_parent ON sessions(parent_session_id);"
                )
            },

            // What one agent said to another, in both of its renderings. See `CrewMessage`.
            //
            // **The column is here because `body` alone could not be both.** A crew message is
            // wrapped for the model and read by a person, and the queue used to hold the wrapped
            // one: whatever the drain did with it, one of the two readers got the wrong string,
            // and the one that did was the owner, who saw the envelope drawn as though he had
            // typed it.
            //
            // The whole payload rather than a second `sent` column, because it is the same JSON
            // the `messages` row is written with, and one document that both readers decode
            // cannot drift the way two columns filled in by two writers can.
            //
            // NULL is the owner's own message, which is every row that existed when this ran and
            // most rows that will ever exist, so there is no default to invent and nothing to
            // backfill. Guarded on the column's absence for the reason every step above is:
            // `ADD COLUMN` has no `IF NOT EXISTS`, and the store's own tests rewind
            // `user_version` and replay the list over a shape that already has it.
            { db in
                let names = Set(
                    try db.query("PRAGMA table_info(deliveries);").compactMap { $0.string("name") }
                )
                if !names.contains("crew_payload") {
                    try db.execute("ALTER TABLE deliveries ADD COLUMN crew_payload BLOB;")
                }
            },

            // The pull request a workspace is about, by number.
            //
            // Every lookup went through `gh pr view <branch>`, and a branch that has been merged
            // and deleted is a name GitHub will not resolve: the workspace in the report showed
            // pull request #222 as open and ready to merge, with a live Squash and merge button,
            // for the rest of the launch. A number survives the branch; the name does not, and
            // neither does `branch.<name>.merge`, which git deletes along with the branch.
            //
            // NULL rather than 0, and no backfill. NULL is "nobody has found out yet", which is
            // what every row that existed when this ran genuinely is, and the first lookup that
            // answers writes the number down. There is nothing to backfill it from here: the
            // answer lives on GitHub, and asking for sixty workspaces at launch is sixty `gh`
            // processes for a column that fills itself in on the next poll.
            //
            // Real code rather than SQL for the reason every step above it is: `ADD COLUMN` has no
            // `IF NOT EXISTS`, and the store's own tests rewind `user_version` and replay the list
            // over a shape that already has the column.
            { db in
                let names = Set(
                    try db.query("PRAGMA table_info(workspaces);").compactMap { $0.string("name") }
                )
                if !names.contains("pull_request_number") {
                    try db.execute(
                        "ALTER TABLE workspaces ADD COLUMN pull_request_number INTEGER;"
                    )
                }
            },

            // How many lines a review comment covers, for the ones left by dragging down the
            // gutter rather than pressing the `+` on one line.
            //
            // A count and not an end line, because the anchor is re-found by the text of its
            // FIRST line and the rest of the note slides with it; an end line stored on its own
            // would stay where it was and the range would stretch. `ReviewCommentAnchor.span`
            // carries the whole of that argument.
            //
            // Every row that existed when this ran covers one line, which is exactly what the
            // default says, so there is nothing to backfill. Real code rather than SQL for the
            // reason every step above is: `ADD COLUMN` has no `IF NOT EXISTS`, and the store's own
            // tests rewind `user_version` and replay the list over a shape that already has it.
            { db in
                let names = Set(
                    try db.query("PRAGMA table_info(review_comments);")
                        .compactMap { $0.string("name") }
                )
                if !names.contains("span") {
                    try db.execute(
                        "ALTER TABLE review_comments ADD COLUMN span INTEGER NOT NULL DEFAULT 1;"
                    )
                }
            },

            // Which files a reviewer has said they have read, and what the diff looked like when
            // they said it.
            //
            // In the database rather than in user defaults, which is where the first version of
            // this feature lived and is why it was taken out again: a bool under
            // `inspector.viewed.<workspace>.<path>` was written and read by one toggle and by
            // nothing else, so it could not be counted, could not dim a row, and died with no
            // migration because there was nothing to migrate. Here it is per-workspace working
            // state beside the review comments, keyed the same way, and the foreign key deletes
            // it with the worktree it is about.
            //
            // The fingerprint is the point of the table. A tick is given for a diff rather than
            // for a path, so a file the agent rewrites afterwards stops reading as viewed without
            // anything having to go round deleting rows during a poll. See
            // `ReviewedFileFingerprint`.
            sql("""
            CREATE TABLE IF NOT EXISTS reviewed_files (
                workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                file_path TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                viewed_at REAL NOT NULL,
                PRIMARY KEY (workspace_id, file_path)
            );
            """),
            { db in
                let names = Set(try db.query("PRAGMA table_info(sessions);").compactMap { $0.string("name") })
                if !names.contains("side_conversation_parent_id") {
                    try db.execute("ALTER TABLE sessions ADD COLUMN side_conversation_parent_id TEXT;")
                }
                try db.execute("CREATE INDEX IF NOT EXISTS sessions_side_parent ON sessions(side_conversation_parent_id);")
                // A closed parent must never strand a hidden, possibly still-running child.
                try db.execute("""
                CREATE TRIGGER IF NOT EXISTS sessions_keep_side_conversations
                AFTER UPDATE OF archived_at ON sessions
                WHEN NEW.archived_at IS NOT NULL
                BEGIN
                    UPDATE sessions SET side_conversation_parent_id = NULL
                    WHERE side_conversation_parent_id = NEW.id;
                END;
                """)
            },
            { db in
                for (table, column, definition) in [
                    ("sessions", "interaction_mode", "TEXT NOT NULL DEFAULT 'build'"),
                    ("deliveries", "interaction_mode", "TEXT"),
                    ("deliveries", "delivery_state", "TEXT NOT NULL DEFAULT 'pending'"),
                    ("deliveries", "provider_turn_id", "TEXT"),
                ] {
                    let columns = Set(try db.query("PRAGMA table_info(\(table));").compactMap { $0.string("name") })
                    if !columns.contains(column) {
                        try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
                        if column == "delivery_state" {
                            try db.execute("UPDATE deliveries SET delivery_state = 'accepted' WHERE delivered_at IS NOT NULL;")
                        }
                    }
                }
            },

            // Messages one workspace's agent sent another through `workspace_say`. See
            // `WorkspaceMessage`.
            //
            // Beside `deliveries` rather than a column on it, because the delivery is addressed to
            // a chat and drained, and this is what the SENDING chat reads to draw its call: queued,
            // delivered or cancelled. `state` follows the delivery, moved in the same statements
            // that move it: see `markDelivered`, `cancelDelivery` and `restoreDelivery`.
            //
            // No foreign keys, following `deliveries`: a reply finds its chat through this row, and
            // it should outlive either workspace being archived. The names are copied in for the
            // same reason, so a bubble still says where a message came from afterwards.
            sql("""
            CREATE TABLE IF NOT EXISTS workspace_messages (
                id TEXT PRIMARY KEY,
                source_workspace_id TEXT,
                source_workspace_name TEXT NOT NULL DEFAULT '',
                source_project_name TEXT NOT NULL DEFAULT '',
                source_session_id TEXT,
                source_chat TEXT NOT NULL DEFAULT '',
                target_workspace_id TEXT,
                target_workspace_name TEXT NOT NULL DEFAULT '',
                target_project_name TEXT NOT NULL DEFAULT '',
                target_session_id TEXT,
                target_chat TEXT NOT NULL DEFAULT '',
                reply_session_id TEXT,
                body TEXT NOT NULL,
                delivery_id TEXT,
                state TEXT NOT NULL,
                created_at REAL NOT NULL,
                delivered_at REAL
            );
            CREATE INDEX IF NOT EXISTS workspace_messages_delivery ON workspace_messages(delivery_id);
            CREATE INDEX IF NOT EXISTS workspace_messages_route
                ON workspace_messages(source_workspace_id, target_workspace_id, state);
            """),

            // A chat that asked `workspace_say` or `workspace_start` to tell it when the other
            // workspace's turn comes to rest. See `WorkspaceDoneWatch`.
            //
            // A table of its own rather than two columns on `workspace_messages`, because a start
            // has no message row and both kinds are looked up the same way: by the workspace whose
            // turn just ended, unspent. `notified_at` is the whole of "at most once": the notice
            // goes only when the `UPDATE` setting it changed a row. `notify_when_done` on the
            // message is the record of what was asked, for a reader of that row.
            //
            // The column is added only when missing, because `ALTER TABLE ADD COLUMN` has no `IF
            // NOT EXISTS` and the store's own tests rewind `user_version` to reproduce an old
            // schema, which would otherwise take the migration transaction with it.
            { db in
                let columns = Set(
                    try db.query("PRAGMA table_info(workspace_messages);").compactMap { $0.string("name") }
                )
                if !columns.contains("notify_when_done") {
                    try db.execute(
                        "ALTER TABLE workspace_messages ADD COLUMN notify_when_done INTEGER NOT NULL DEFAULT 0;"
                    )
                }
                try db.execute("""
                CREATE TABLE IF NOT EXISTS workspace_done_watches (
                    id TEXT PRIMARY KEY,
                    message_id TEXT,
                    watcher_session_id TEXT NOT NULL,
                    target_workspace_id TEXT NOT NULL,
                    target_workspace_name TEXT NOT NULL DEFAULT '',
                    target_project_name TEXT NOT NULL DEFAULT '',
                    target_session_id TEXT,
                    target_chat TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    notified_at REAL
                );
                CREATE INDEX IF NOT EXISTS workspace_done_watches_target
                    ON workspace_done_watches(target_workspace_id, notified_at);
                """)
            },

            // Preserve migration positions for databases created by earlier builds.
            { _ in },
            { _ in },
            { _ in },
            { _ in },
            { _ in },
            { _ in },
            { _ in },
            // The unique index added after duplicate transcript positions were repaired covers
            // the same two columns as messages_session. Keeping both writes two B-trees for every
            // message, while every read can use messages_session_seq.
            sql("DROP INDEX IF EXISTS messages_session;"),

            // Whether a workspace is a worktree or the project's own checkout. See
            // `WorkspaceKind`, which says why this is stated rather than read off the path.
            //
            // Every existing row is a worktree, because nothing else could be made until now, so
            // the default is the backfill. The index is the "at most one live project checkout
            // per project" rule held where two racing creates cannot both get past it; archived
            // rows are outside it, so a checkout can be archived and taken up again.
            //
            // Also in `repairSchema`, because `upsert` names the column and a database stamped
            // past this step without it could create no workspace at all.
            { db in
                let names = Set(
                    try db.query("PRAGMA table_info(workspaces);").compactMap { $0.string("name") }
                )
                if !names.contains("kind") {
                    try db.execute(Self.workspaceKindColumn)
                }
                try db.execute(Self.oneProjectCheckoutIndex)
            },
        ]

        let current = Int(try db.readUserVersion())
        guard current >= 0, current <= migrations.count else {
            throw SQLiteError(message: "Unsupported database schema version \(current)", sql: nil)
        }

        // Before the version is trusted, and whatever it says. See `repairSchema`: a database
        // stamped as fully migrated with a column missing is a real state that a real machine
        // reached, and every query naming that column failed until it was put back.
        try repairSchema(db)

        guard current < migrations.count else { return }

        // Off for the run, and back on after it, which is SQLite's own instruction for a schema
        // change that rebuilds a table rather than a preference. A `DROP TABLE` with foreign keys
        // enforced deletes the children of every row it drops, and the sessions rebuild below
        // would take `messages` with it. The pragma is a no-op inside a transaction, so it has to
        // be here, outside the one the steps run in.
        //
        // Nothing else is open on this connection yet: `migrate` is called from `Store.init`,
        // before the actor exists, so there is no window in which another writer sees them off.
        try db.execute("PRAGMA foreign_keys = OFF;")
        defer { try? db.execute("PRAGMA foreign_keys = ON;") }

        // One transaction for the lot: a migration that half ran would leave a schema no version
        // number describes.
        try db.transaction {
            for index in current..<migrations.count {
                try migrations[index](db)
            }
            try db.setUserVersion(Int32(migrations.count))
        }
    }
}
