import Foundation

extension Store {
    // MARK: - Sessions

    /// Creation and context capture commit together. Returning an existing detour makes two
    /// panes opening /btw at once converge on one conversation without touching the parent.
    public func openSideConversation(parentID: SessionID, streamingText: String = "") throws -> Session {
        try db.transaction {
            guard let parent = try session(id: parentID), let workspaceID = parent.workspaceID,
                  parent.archivedAt == nil, parent.sideConversationParentID == nil,
                  let workspace = try workspace(id: workspaceID), workspace.state == .active else {
                throw SQLiteError(message: "This chat cannot start a side conversation.", sql: nil)
            }
            if let existing = try sessions(workspaceID: workspaceID).first(where: {
                $0.sideConversationParentID == parentID
            }) { return existing }
            let recent = try db.query(
                "SELECT * FROM messages WHERE session_id = ? ORDER BY seq DESC LIMIT 300",
                [.text(parentID)]
            ).map(Self.message(from:)).reversed()
            let snapshot = SideConversation.Snapshot(
                parentID: parentID, title: parent.title,
                context: SideConversation.context(
                    messages: Array(recent), streamingText: streamingText,
                    inheritedContext: try sideConversationSnapshot(sessionID: parentID)?.context ?? ""
                )
            )
            let next = Session(
                workspaceID: workspaceID, sideConversationParentID: parentID,
                title: PaneNaming.nextTitle(
                    base: "Side conversation", taken: try sessions(workspaceID: workspaceID).map(\.title)
                ),
                model: parent.model, effort: parent.effort,
                agentKind: parent.agentKind, permissionMode: parent.permissionMode,
                sortOrder: try sessions(workspaceID: workspaceID).count
            )
            try upsert(next)
            try setSetting(SideConversation.contextKey(next.id), String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self))
            // Preserve the values which live outside Session as well as the model and permissions.
            for keys in [
                (ComposerControls.fastModeKey(sessionID: parentID), ComposerControls.fastModeKey(sessionID: next.id)),
                (ComposerControls.outputStyleKey(sessionID: parentID), ComposerControls.outputStyleKey(sessionID: next.id)),
                (ComposerControls.contextWindowKey(sessionID: parentID), ComposerControls.contextWindowKey(sessionID: next.id)),
                (ChatAdvisor.key(sessionID: parentID), ChatAdvisor.key(sessionID: next.id))
            ] { try setSetting(keys.1, setting(keys.0)) }
            try setSetting(
                PlanApproval.modeKey(sessionID: next.id),
                planImplementationMode(sessionID: parentID, hasWorktree: true).rawValue
            )
            try setSetting(ComposerControls.defaultsAppliedKey(sessionID: next.id), "1")
            return next
        }
    }

    public func sideConversationSnapshot(sessionID: SessionID) throws -> SideConversation.Snapshot? {
        guard let stored = try setting(SideConversation.contextKey(sessionID)) else { return nil }
        return try JSONDecoder().decode(SideConversation.Snapshot.self, from: Data(stored.utf8))
    }

    /// The editable question stays untouched. Preparing at the provider boundary also keeps a
    /// failed first send retryable even when the provider has already recorded a local user row.
    public func sideConversationTurn(_ text: String, sessionID: SessionID) throws -> String {
        guard try setting(SideConversation.contextDeliveredKey(sessionID)) != "1",
              let snapshot = try sideConversationSnapshot(sessionID: sessionID) else { return text }
        return try SideConversation.firstTurn(text, snapshot: snapshot)
    }

    public func acknowledgeSideConversationContext(sessionID: SessionID) throws {
        try setSetting(SideConversation.contextDeliveredKey(sessionID), "1")
    }

    /// Promotion only changes presentation. The provider id, queued turns and context survive.
    public func keepSideConversation(sessionID: SessionID) throws -> Session? {
        try update(sessionID: sessionID) { row in
            row.sideConversationParentID = nil
        }
    }

    public func sessions(workspaceID: WorkspaceID) throws -> [Session] {
        try db.query(
            "SELECT * FROM sessions WHERE workspace_id = ? AND archived_at IS NULL ORDER BY sort_order, created_at",
            [.text(workspaceID)]
        ).map(Self.session(from:))
    }

    /// The chats closed in one workspace, newest first, with the size of what reopening one would
    /// bring back.
    ///
    /// **One statement rather than a session read and a `messageCount(sessionID:)` per row**, for
    /// `crewByWorkspace`'s reason: this is asked every time the pointer crosses the `+` above the
    /// pane, and ten round trips onto this actor per hover would be competing with the writes of
    /// whichever agent is mid turn. `messages_session_seq` is the index the subquery rides, and the
    /// chat that forced this feature holds 13,872 rows behind it.
    ///
    /// Empty chats are excluded before `LIMIT`, not discarded afterwards. Otherwise ten empty
    /// recent tabs could hide an older conversation that has work in it and should occupy one of
    /// the ten usable slots.
    ///
    /// **The predicate is `TabSet.tabbable`'s, turned onto archived rows, and that is the decision
    /// rather than the tidiness.** A crew member is a sidebar row and a side conversation is a
    /// pane of the chat that started it, so clearing `archived_at` on either would hand back a
    /// chat the strip never draws: reachable in the database, invisible in the app, which is the
    /// bug `SessionReopening` exists to fix wearing a different coat.
    ///
    /// `limit` is the caller's because the cap is a presentation decision and lives in
    /// `SessionReopening.limit`. It is applied here as well so a workspace with four hundred
    /// closed chats is four hundred rows SQLite skips rather than four hundred it builds.
    public func closedSessions(workspaceID: WorkspaceID, limit: Int) throws -> [ClosedChat] {
        try db.query(
            """
            SELECT s.id AS id, s.title AS title, s.agent_kind AS agent_kind,
                   s.archived_at AS archived_at,
                   (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id) AS message_count
            FROM sessions s
            WHERE s.workspace_id = ? AND s.archived_at IS NOT NULL
              AND s.parent_session_id IS NULL AND s.side_conversation_parent_id IS NULL
              AND EXISTS (SELECT 1 FROM messages used WHERE used.session_id = s.id)
            ORDER BY s.archived_at DESC, s.id ASC
            LIMIT ?
            """,
            [.text(workspaceID), .int(Int64(max(0, limit)))]
        ).compactMap { row in
            // A row with no id or no archived stamp is not a closed chat, whatever else it is.
            // Both are guarded rather than defaulted, because a default here would invent a chat
            // that reopening could not find.
            guard let id = row.string("id"), let closedAt = row.date("archived_at") else { return nil }
            return ClosedChat(
                id: SessionID(id),
                title: row.string("title") ?? PaneNaming.chat,
                // A row written before the column existed reads as Claude Code, which is what it
                // was. Same fallback as `session(from:)`, for the same reason.
                agentKind: AgentKind(rawValue: row.string("agent_kind") ?? "") ?? .claudeCode,
                messageCount: Int(row.int("message_count") ?? 0),
                closedAt: closedAt
            )
        }
    }

    /// Clears `archived_at`, which is the whole of reopening a chat.
    ///
    /// **Through `update(sessionID:)` and never `upsert`**, and the reason is that method's own:
    /// a session row has two writers, and the value a menu was built from is a reading taken when
    /// the pointer crossed a button. Writing it back whole would put `agent_session_id`, `state`
    /// and the token counters back to whatever they were at that moment, and the first of those is
    /// the id `--resume` is built from.
    ///
    /// **The side conversations that were promoted when this chat closed stay promoted.** The
    /// `sessions_keep_side_conversations` trigger nulls `side_conversation_parent_id` on the way
    /// in so a closed parent cannot strand a running child, and it does not fire on the way out.
    /// That is right rather than a gap: those chats are tabs of their own now, somebody may have
    /// been using them for a week, and pulling them back under a parent would take them out of the
    /// strip without asking.
    ///
    /// Returns nil when there is no such row, which is a chat whose workspace was archived and its
    /// records deleted while the menu offering it stood open.
    @discardableResult
    public func reopenSession(id: SessionID) throws -> Session? {
        try update(sessionID: id) { $0.archivedAt = nil }
    }

    /// Reopens one row only while it is still in the bounded list the caller could have read.
    ///
    /// One actor-isolated method for the eligibility read and the write is the concurrency rule.
    /// Two clients may ask together, but only the first can see an archived row and clear it; the
    /// second sees `alreadyOpen`. Likewise, ten newer closes cannot land between checking the list
    /// and reopening a row that has just fallen out of it.
    func reopenOfferedSession(
        id: SessionID,
        workspaceID: WorkspaceID,
        limit: Int
    ) throws -> OfferedSessionReopening {
        guard let session = try session(id: id), session.workspaceID == workspaceID else { return .missing }
        guard session.parentSessionID == nil, session.sideConversationParentID == nil else { return .notTopLevel }
        guard session.archivedAt != nil else { return .alreadyOpen }
        guard !session.state.isMidTurn else { return .running }
        let offered = SessionReopening.offered(try closedSessions(workspaceID: workspaceID, limit: limit))
        guard offered.contains(where: { $0.id == id }) else { return .notOffered }
        guard let reopened = try update(sessionID: id, { $0.archivedAt = nil }) else { return .missing }
        return .reopened(reopened)
    }

    /// The chats one chat started, oldest first. A crew, in `Crew`'s words.
    ///
    /// Separate from `sessions(workspaceID:)` rather than a filter over it, because the two
    /// answer different questions and the tab strip asks the first one: a crew member is drawn in
    /// the sidebar under its workspace, not as a tab beside the chat that started it.
    public func crew(of parentID: SessionID) throws -> [Session] {
        try db.query(
            "SELECT * FROM sessions WHERE parent_session_id = ? AND archived_at IS NULL ORDER BY created_at",
            [.text(parentID)]
        ).map(Self.session(from:))
    }

    /// Every crew member in one workspace, whichever chat started them.
    ///
    /// What the sidebar draws under a workspace row, and what the ceiling in `Crew` is counted
    /// against: three running agents in one worktree is three writers in one working tree,
    /// whether or not one chat asked for all of them.
    public func crew(inWorkspace workspaceID: WorkspaceID) throws -> [Session] {
        try db.query(
            "SELECT * FROM sessions WHERE workspace_id = ? AND parent_session_id IS NOT NULL AND archived_at IS NULL ORDER BY created_at",
            [.text(workspaceID)]
        ).map(Self.session(from:))
    }

    /// Every crew member in the app at once, grouped by the worktree it is working in.
    ///
    /// **One statement rather than one per workspace, and that is the whole reason it exists.**
    /// The sidebar's crew rows are refreshed from `store.changes(of: [.sessions])`, and the runner
    /// rewrites a session row (state, tokens, cost, `updatedAt`) many times inside one turn. Asked
    /// per workspace, a sidebar holding twenty of them made twenty round trips onto this actor for
    /// every batch of those writes, competing with the writes of the agent that caused them. The
    /// grouping is Swift's work because it is free there and a second query here is not.
    ///
    /// Same predicate as `crew(inWorkspace:)`, so the two cannot disagree about what a crew member
    /// is. A row with no `workspace_id` cannot be one: `Crew` is about agents sharing a worktree.
    public func crewByWorkspace() throws -> [WorkspaceID: [Session]] {
        let members = try db.query(
            """
            SELECT * FROM sessions
            WHERE parent_session_id IS NOT NULL AND archived_at IS NULL
            ORDER BY created_at
            """
        ).map(Self.session(from:))

        var grouped: [WorkspaceID: [Session]] = [:]
        for member in members {
            guard let workspaceID = member.workspaceID else { continue }
            grouped[workspaceID, default: []].append(member)
        }
        return grouped
    }

    /// The chats that belong to no worktree, oldest first.
    ///
    /// Project-free conversations. It is a separate method rather than a nil argument to
    /// `sessions(workspaceID:)` because `= NULL` is never true in SQL and a caller that passed nil
    /// there would get an empty list and no error, which is the quietest way to be wrong.
    public func sessionsWithoutWorkspace(includeArchived: Bool = false) throws -> [Session] {
        let archivedClause = includeArchived ? "archived_at IS NOT NULL" : "archived_at IS NULL"
        return try db.query(
            "SELECT * FROM sessions WHERE workspace_id IS NULL AND \(archivedClause) "
                + "ORDER BY sort_order, created_at"
        ).map(Self.session(from:))
    }

    /// Finished turns in active project-free conversations that have not been read yet.
    /// A user message alone is not news, and the indexed result lookup answers the whole list in
    /// one store read rather than one actor hop per conversation at launch.
    public func unreadProjectFreeConversationIDs() throws -> Set<SessionID> {
        let rows = try db.query(
            """
            SELECT s.id FROM sessions s
            WHERE s.workspace_id IS NULL AND s.archived_at IS NULL
              AND EXISTS (
                SELECT 1 FROM messages m
                WHERE m.session_id = s.id AND m.seq > s.last_read_seq AND m.kind = 'result'
              )
            """
        )
        return Set(rows.compactMap { $0.string("id").map(SessionID.init) })
    }

    /// Legacy conversations may still have the old placeholder title and no agent thread id.
    /// Their transcript or draft, rather than the title, decides whether they belong in a list.
    public func projectFreeSessionsWithHistory(includeArchived: Bool = false) throws -> Set<SessionID> {
        let archivedClause = includeArchived ? "s.archived_at IS NOT NULL" : "s.archived_at IS NULL"
        let rows = try db.query(
            """
            SELECT s.id FROM sessions s
            WHERE s.workspace_id IS NULL AND \(archivedClause)
              AND (
                EXISTS (SELECT 1 FROM messages m WHERE m.session_id = s.id)
                OR EXISTS (SELECT 1 FROM deliveries d WHERE d.target_session_id = s.id)
                OR EXISTS (SELECT 1 FROM drafts f WHERE f.session_id = s.id AND length(trim(f.body)) > 0)
              )
            """
        )
        return Set(rows.compactMap { $0.string("id").map(SessionID.init) })
    }

    /// Brings a project-free conversation back to the live list.
    @discardableResult
    public func restoreConversation(id: SessionID) throws -> Session? {
        try db.transaction {
            guard let session = try session(id: id), session.workspaceID == nil,
                  session.archivedAt != nil else { return nil }
            let restored = try update(sessionID: id) { $0.archivedAt = nil }
            try setSetting(AskTabs.selectionKey, id.rawValue)
            return restored
        }
    }

    /// Removes only an archived project-free conversation and its dependent records.
    public func deleteArchivedConversation(id: SessionID) throws -> Bool {
        try db.transaction {
            let eligible = try db.query(
                "SELECT id FROM sessions WHERE id = ? AND workspace_id IS NULL AND archived_at IS NOT NULL",
                [.text(id)]
            ).first != nil
            guard eligible else { return false }
            try db.run("DELETE FROM drafts WHERE session_id = ?", [.text(id)])
            try db.run("DELETE FROM deliveries WHERE target_session_id = ?", [.text(id)])
            try setSetting(AskTabs.directoryKey(id), nil)
            try setSetting(ConversationListing.pinnedKey(id), nil)
            try setSetting(ConversationListing.colourKey(id), nil)
            try db.run("DELETE FROM sessions WHERE id = ?", [.text(id)])
            return true
        }
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
        try rememberImplementationMode(for: session)
        try db.run(
            """
            INSERT INTO sessions (
                id, workspace_id, parent_session_id, side_conversation_parent_id, title, agent_session_id, model, effort,
                agent_kind, permission_mode, interaction_mode, state, sort_order, created_at, updated_at,
                archived_at, last_read_seq, input_tokens, output_tokens, cost_usd, context_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                side_conversation_parent_id = excluded.side_conversation_parent_id,
                title = excluded.title,
                agent_session_id = excluded.agent_session_id,
                model = excluded.model,
                effort = excluded.effort,
                agent_kind = excluded.agent_kind,
                permission_mode = excluded.permission_mode,
                interaction_mode = excluded.interaction_mode,
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
                .text(session.id), .text(session.workspaceID),
                session.parentSessionID.map { .text($0) } ?? .null,
                session.sideConversationParentID.map { .text($0) } ?? .null,
                .text(session.title),
                session.agentSessionID.map { .text($0) } ?? .null,
                .text(session.model), .text(session.effort), .text(session.agentKind.rawValue),
                .text(session.permissionMode.rawValue), .text(session.interactionMode.rawValue),
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
        interactionMode: InteractionMode? = nil,
        implementationMode: PermissionMode? = nil,
        /// Only ever set on a chat that has not spoken yet. Changing the backend of a chat that
        /// already has a message strands its transcript half in one vocabulary and half in the
        /// other, and its thread id on a server that knows nothing about the new one, so the
        /// picker forks a new chat instead. See docs/CODEX.md.
        agentKind: AgentKind? = nil
    ) throws {
        // First-open defaults replace a placeholder session. Its fallback mode is not a user
        // choice, so the composer supplies the configured implementation mode when opening Plan.
        if permissionMode == .plan, let implementationMode {
            try setSetting(PlanApproval.modeKey(sessionID: id), PlanApproval.implementationMode(implementationMode).rawValue)
        }
        if let permissionMode, var session = try session(id: id) {
            session.permissionMode = permissionMode
            try rememberImplementationMode(for: session)
        }
        try db.run(
            """
            UPDATE sessions SET
                title = COALESCE(?, title),
                model = COALESCE(?, model),
                effort = COALESCE(?, effort),
                permission_mode = COALESCE(?, permission_mode),
                interaction_mode = COALESCE(?, interaction_mode),
                agent_kind = COALESCE(?, agent_kind),
                updated_at = ?
            WHERE id = ?
            """,
            [
                title.map { .text($0) } ?? .null,
                model.map { .text($0) } ?? .null,
                effort.map { .text($0) } ?? .null,
                permissionMode.map { .text($0.rawValue) } ?? .null,
                interactionMode.map { .text($0.rawValue) } ?? .null,
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
    ///
    /// **A crew member caught by this leaves an orchestrator waiting for ever, so it is told.**
    /// Quitting Bloom with a crew working and reopening it used to bring back a set of dead rows,
    /// with no queued delivery and no news for the chat that started them: the orchestrator sat on
    /// a report that could no longer arrive, which is exactly the failure the head of
    /// `Crew.failedSentence` says the design exists to prevent. The reports are enqueued here
    /// rather than by whatever opens a window, because a workspace nobody opens this launch has
    /// the same problem and there is no window to notice it.
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
        let stateValues = sources.map { SQLValue.text($0.rawValue) }

        // Read before the write, because the write is what destroys the evidence: once these rows
        // are idle, nothing on them says they were working when the app died.
        //
        // The join is what keeps an archived orchestrator out of it. A delivery addressed to a
        // chat the owner has closed is a row nothing will ever drain, and the sentence is about an
        // agent that chat can no longer see anyway. The member being unarchived is the same
        // argument one row down: an archived crew member is gone from `crew(of:)` and from every
        // list its orchestrator can read, so there is nothing there to report the death of.
        let lost = try db.query(
            """
            SELECT member.title AS title,
                   member.workspace_id AS workspace_id,
                   member.parent_session_id AS parent_session_id
            FROM sessions AS member
            JOIN sessions AS parent ON parent.id = member.parent_session_id
            WHERE member.state IN (\(placeholders))
              AND member.archived_at IS NULL
              AND parent.archived_at IS NULL
            ORDER BY member.created_at
            """,
            stateValues
        )

        try db.run(
            "UPDATE sessions SET state = ? WHERE state IN (\(placeholders))",
            [.text(destination.rawValue)] + stateValues
        )

        // After the reset and one at a time, so that a delivery this cannot write costs the
        // orchestrator its news and nothing else. The reset is the half that keeps the ceiling in
        // `Crew` from staying stuck at three dead agents, and losing that to a failed insert would
        // be trading a waiting orchestrator for a workspace that can never start another agent.
        for row in lost {
            guard let parentID = row.string("parent_session_id") else { continue }
            _ = try? enqueueDelivery(Delivery(
                targetSessionID: SessionID(parentID),
                sourceWorkspaceID: row.string("workspace_id").map(WorkspaceID.init),
                kind: .report,
                // A crew message rather than a plain body, like every other thing one agent is
                // told about another: the orchestrator is handed the sentence and its own window
                // draws the one line, instead of the paragraph appearing as though the owner had
                // typed it. See `CrewMessage`.
                crew: CrewMessage.failed(
                    name: row.string("title") ?? "",
                    reason: "Bloom was restarted while it was working, so its turn was lost. "
                        + "Nothing it had not already reported got through."
                )
            ))
        }
    }
}
