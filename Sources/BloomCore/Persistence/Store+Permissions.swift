import Foundation

extension Store {
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

    /// A watcher must hear only about a question still blocking this turn. Reading the state and
    /// pending asks together excludes automatic approvals and completed turns during feed replay.
    public func pendingPermissionEnding(sessionID: SessionID) throws -> WorkspaceTurnEnding? {
        guard try session(id: sessionID)?.state == .waiting,
              let pending = try pendingPermissionAsks(sessionID: sessionID).last else { return nil }
        return WorkspaceTurnEnding.ofAsk(pending.ask)
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
}
