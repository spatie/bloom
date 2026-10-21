import Foundation

extension Store {
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
                parent_workspace_id, spawn_tool_use_id, port, pull_request_number, kind
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                port = excluded.port,
                pull_request_number = excluded.pull_request_number
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
                workspace.pullRequestNumber.map { .int(Int64($0)) } ?? .null,
                // Insert only: the `ON CONFLICT` list leaves it out, so a row keeps the kind it
                // was made with whatever value is handed back. See `Workspace.kind`.
                .text(workspace.kind.rawValue),
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
                // A message between workspaces still queued into or out of this one will now never
                // go, so the bubble in the other chat has to stop saying "queued" and offering Cancel.
                try db.run(
                    """
                    UPDATE workspace_messages SET state = 'cancelled'
                    WHERE state = 'queued' AND delivery_id IN (
                        SELECT id FROM deliveries
                        WHERE source_workspace_id = ?
                           OR target_session_id IN (SELECT id FROM sessions WHERE workspace_id = ?)
                    )
                    """,
                    [.text(id), .text(id)]
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

    /// A filesystem refresh owns only the branch. A rename, restore or archive that landed while
    /// git was running wins over this older observation. An unchanged answer writes nothing, so
    /// the background poll does not wake every workspace observer on an idle checkout.
    ///
    /// A project checkout writes its base with it, and the two refusals that protect a worktree's
    /// base and default branch do not apply to it. See `WorkspaceKind.followsHead`.
    public func updateCheckedOutBranch(_ branch: String, observed: Workspace) throws {
        guard observed.state == .active, branch != observed.branch,
              branch != "HEAD", Git.isValidBranchName(branch),
              let current = try workspace(id: observed.id),
              current.state == .active, current.path == observed.path,
              current.branch == observed.branch else { return }
        if current.kind.followsHead {
            try db.run(
                "UPDATE workspaces SET branch = ?, base_branch = ? WHERE id = ?",
                [.text(branch), .text(branch), .text(observed.id)]
            )
            return
        }
        guard branch != current.baseBranch,
              let project = try repo(id: current.repoID), branch != project.defaultBranch else { return }
        try db.run(
            "UPDATE workspaces SET branch = ? WHERE id = ?",
            [.text(branch), .text(observed.id)]
        )
    }

    /// Writes the pull request this workspace is about, and only when it has actually changed.
    ///
    /// The same shape and the same reason as `updateDiffStat` above it: this runs behind a poll,
    /// most polls answer the number that is already there, and SQLite does not care that the value
    /// is identical. The row would be rewritten, the WAL would grow and the update hook would
    /// fire, so every workspace with a pull request would announce a change every couple of
    /// minutes and everything listening would reload for it.
    ///
    /// One named column rather than a whole `Workspace`, for the reason in this file's head: the
    /// value the caller is holding was read before a `gh` round trip, and a lookup can take
    /// seconds. The read and the write are both inside the actor with nothing suspending between
    /// them.
    ///
    /// Clearing it is not here. That happens exactly once, in `continueOnNewBranch`, in the same
    /// `update` that moves the branch, because the two are one change: the pull request stops
    /// being this workspace's because the branch did.
    public func recordPullRequestNumber(_ number: Int, workspaceID: WorkspaceID) throws {
        guard number > 0 else { return }
        guard let current = try db.query(
            "SELECT pull_request_number FROM workspaces WHERE id = ?", [.text(workspaceID)]
        ).first else { return }
        if current.int("pull_request_number").map(Int.init) == number { return }

        try db.run(
            "UPDATE workspaces SET pull_request_number = ? WHERE id = ?",
            [.int(Int64(number)), .text(workspaceID)]
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
}
