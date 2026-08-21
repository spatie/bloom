import Foundation
import Testing
@testable import BloomCore

/// Rules the user granted, and the promise that Bloom never widens one.
///
/// The matching rule under test is exact equality and nothing else. That is the entire safety
/// argument for letting Bloom answer an ask on the user's behalf, so most of this file is about
/// the things that must *not* match: a prefix, a different case, a trimmed space, a resolved path.
/// Every one of those would be Bloom deciding that two rules in a syntax the CLI owns mean the
/// same thing.
@Suite("Permission grants", .tags(.persistence), .scratchDirectory)
struct PermissionGrantTests {
    static func ask(
        tool: String = "Bash",
        rule: String? = "bin/test:*",
        suppressed: Bool = false,
        needsInteraction: Bool = false
    ) -> PermissionAsk {
        let rules: [PermissionRule] = rule.map { [PermissionRule(toolName: tool, ruleContent: $0)] } ?? []
        let suggestion = PermissionSuggestion(
            type: "addRules",
            behavior: "allow",
            destination: "localSettings",
            rules: rules,
            raw: .object([:])
        )
        return PermissionAsk(
            requestID: "req-1",
            toolName: tool,
            input: .object(["command": .string("bin/test --filter Permission")]),
            suggestions: rules.isEmpty ? [] : [suggestion],
            suppressesAlwaysAllow: suppressed,
            requiresUserInteraction: needsInteraction
        )
    }

    static func grant(tool: String = "Bash", rule: String? = "bin/test:*") -> PermissionGrant {
        PermissionGrant(repoID: RepoID("repo-1"), toolName: tool, ruleContent: rule)
    }

    // MARK: Matching

    @Test("the same rule, stored, answers the question")
    func exactMatch() {
        let matched = PermissionGrantIndex.match(ask: Self.ask(), grants: [Self.grant()])

        #expect(matched?.count == 1)
        #expect(matched?.first?.displayText == "Bash(bin/test:*)")
    }

    @Test("nothing stored means somebody has to answer")
    func noGrants() {
        #expect(PermissionGrantIndex.match(ask: Self.ask(), grants: []) == nil)
    }

    /// The wildcard works because it is in the string the CLI composed, not because Bloom knows
    /// what a star means. Two different invocations that the CLI describes with the same rule
    /// match each other; Bloom never expands anything.
    @Test("a wildcard rule the CLI composed matches by being the same string")
    func wildcardIsJustAString() {
        let first = Self.ask(rule: "bin/test:*")
        let second = PermissionAsk(
            requestID: "req-2",
            toolName: "Bash",
            input: .object(["command": .string("bin/test --filter Something Else")]),
            suggestions: [PermissionSuggestion(
                type: "addRules",
                behavior: "allow",
                rules: [PermissionRule(toolName: "Bash", ruleContent: "bin/test:*")]
            )]
        )
        let grants = [Self.grant(rule: "bin/test:*")]

        #expect(PermissionGrantIndex.match(ask: first, grants: grants) != nil)
        #expect(PermissionGrantIndex.match(ask: second, grants: grants) != nil)
    }

    // MARK: Never widening

    /// Every one of these is a way Bloom could have decided two rules mean the same thing. None
    /// of them matches, and each costs at most one extra question.
    @Test(
        "a rule that is not the same string is not the same rule",
        arguments: [
            "bin/test",          // the stored rule without its wildcard
            "bin/test:",         // a truncation
            "bin/test:**",       // a wider wildcard
            "Bin/Test:*",        // different case
            " bin/test:*",       // leading space
            "bin/test:* ",       // trailing space
            "./bin/test:*",      // the same path said differently
            "bin/test:*;rm -rf", // the stored rule as a prefix of a longer one
        ]
    )
    func neverWidens(stored: String) {
        let matched = PermissionGrantIndex.match(ask: Self.ask(rule: "bin/test:*"), grants: [Self.grant(rule: stored)])

        #expect(matched == nil, "\(stored) was treated as Bash(bin/test:*)")
    }

    @Test("a grant for one tool never answers for another")
    func toolNamesMustMatch() {
        let matched = PermissionGrantIndex.match(
            ask: Self.ask(tool: "Bash", rule: "bin/test:*"),
            grants: [Self.grant(tool: "Edit", rule: "bin/test:*")]
        )

        #expect(matched == nil)
    }

    /// One suggestion carrying two rules is one decision about two things. Honouring half of it
    /// would be allowing something on the strength of a grant that was about something else.
    @Test("every rule in the suggestion has to be covered, not just one")
    func allRulesOrNone() {
        let ask = PermissionAsk(
            requestID: "req-1",
            toolName: "Bash",
            suggestions: [PermissionSuggestion(
                type: "addRules",
                behavior: "allow",
                rules: [
                    PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"),
                    PermissionRule(toolName: "Bash", ruleContent: "bin/lint:*"),
                ]
            )]
        )

        #expect(PermissionGrantIndex.match(ask: ask, grants: [Self.grant(rule: "bin/test:*")]) == nil)
        #expect(PermissionGrantIndex.match(ask: ask, grants: [
            Self.grant(rule: "bin/test:*"),
            Self.grant(rule: "bin/lint:*"),
        ])?.count == 2)
    }

    /// The CLI's two flags bind Bloom as hard as they bind the buttons. An ask the user was never
    /// allowed to widen must not be answered from a stored grant either, or the flag would mean
    /// nothing the second time the question came round.
    @Test("an ask the CLI marked unwidenable is never answered from a stored rule")
    func respectsTheCLIFlags() {
        let grants = [Self.grant()]

        #expect(PermissionGrantIndex.match(ask: Self.ask(suppressed: true), grants: grants) == nil)
        #expect(PermissionGrantIndex.match(ask: Self.ask(needsInteraction: true), grants: grants) == nil)
        #expect(PermissionGrantIndex.match(ask: Self.ask(rule: nil), grants: grants) == nil)
    }

    // MARK: What the transcript says

    /// A call that ran because of a decision made days ago must not look like a call that simply
    /// ran, and the note has to name the rule in the CLI's own spelling so it can be found in the
    /// revocation list.
    @Test("an auto-allowed call says which rule allowed it")
    func note() {
        let note = PermissionGrantIndex.note(for: [Self.grant()])

        #expect(note.contains("Bash(bin/test:*)"))
        #expect(note.contains("you approved"))
    }

    // MARK: Storage

    @Test("a grant survives a round trip and is listed per project")
    func stored() async throws {
        let store = try makeTestStore()
        let repo = try await store.upsert(Repo(name: "Bloom", path: "/tmp/bloom-\(newID())"))

        let grant = try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"),
            repoID: repo.id,
            for: "bin/test --filter Permission"
        ))

        let listed = try await store.permissionGrants(repoID: repo.id)
        #expect(listed.count == 1)
        #expect(listed.first?.displayText == "Bash(bin/test:*)")
        #expect(listed.first?.grantedFor == "bin/test --filter Permission")
        #expect(listed.first?.id == grant.id)
    }

    /// Granting the same rule again in a different workspace must not reset the counters: the
    /// list uses them to say whether a rule is pulling its weight, and a rule re-granted has not
    /// stopped being three weeks old.
    @Test("granting the same rule twice keeps the first grant")
    func grantingTwiceIsIdempotent() async throws {
        let store = try makeTestStore()
        let repo = try await store.upsert(Repo(name: "Bloom", path: "/tmp/bloom-\(newID())"))
        let rule = PermissionRule(toolName: "Bash", ruleContent: "bin/test:*")

        let first = try await store.upsert(PermissionGrant.granting(rule, repoID: repo.id))
        try await store.recordPermissionGrantUse(id: first.id)
        let second = try await store.upsert(PermissionGrant.granting(rule, repoID: repo.id))

        #expect(second.id == first.id)
        #expect(second.useCount == 1)
        #expect(try await store.permissionGrants(repoID: repo.id).count == 1)
    }

    /// SQLite counts every NULL as distinct in a unique index, so a whole-tool grant stored as
    /// NULL could be inserted over and over. It is stored as an empty string and read back as nil.
    @Test("a whole-tool grant is stored once and reads back as having no content")
    func wholeToolGrant() async throws {
        let store = try makeTestStore()
        let repo = try await store.upsert(Repo(name: "Bloom", path: "/tmp/bloom-\(newID())"))
        let rule = PermissionRule(toolName: "WebFetch", ruleContent: nil)

        try await store.upsert(PermissionGrant.granting(rule, repoID: repo.id))
        try await store.upsert(PermissionGrant.granting(rule, repoID: repo.id))

        let listed = try await store.permissionGrants(repoID: repo.id)
        #expect(listed.count == 1)
        #expect(listed.first?.ruleContent == nil)
        #expect(listed.first?.displayText == "WebFetch")
        #expect(listed.first?.rule == rule)
    }

    @Test("counting a use does not change what was granted")
    func recordingUse() async throws {
        let store = try makeTestStore()
        let repo = try await store.upsert(Repo(name: "Bloom", path: "/tmp/bloom-\(newID())"))
        let grant = try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "swift build:*"),
            repoID: repo.id
        ))

        try await store.recordPermissionGrantUse(id: grant.id)
        try await store.recordPermissionGrantUse(id: grant.id)

        let stored = try #require(await store.permissionGrants(repoID: repo.id).first)
        #expect(stored.useCount == 2)
        #expect(stored.lastUsedAt != nil)
        #expect(stored.rule == grant.rule)
    }

    /// Revocation has to bite on the next ask rather than on the next launch, which is what it
    /// means for nothing to cache these.
    @Test("a revoked rule stops matching immediately")
    func revocationIsImmediate() async throws {
        let store = try makeTestStore()
        let repo = try await store.upsert(Repo(name: "Bloom", path: "/tmp/bloom-\(newID())"))
        let grant = try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"),
            repoID: repo.id
        ))
        let ask = Self.ask()

        #expect(PermissionGrantIndex.match(ask: ask, grants: try await store.permissionGrants(repoID: repo.id)) != nil)

        try await store.deletePermissionGrant(id: grant.id)

        #expect(PermissionGrantIndex.match(ask: ask, grants: try await store.permissionGrants(repoID: repo.id)) == nil)
    }

    /// A grant is about a project, not a worktree. That is the whole reason it does not live in
    /// the CLI's `localSettings`, which is a file inside a worktree that is deleted with it.
    @Test("a grant in one project never answers for another")
    func grantsAreScopedToTheirProject() async throws {
        let store = try makeTestStore()
        let bloom = try await store.upsert(Repo(name: "Bloom", path: "/tmp/bloom-\(newID())"))
        let flare = try await store.upsert(Repo(name: "Flare", path: "/tmp/flare-\(newID())"))
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"),
            repoID: bloom.id
        ))

        #expect(try await store.permissionGrants(repoID: flare.id).isEmpty)
        #expect(try await store.permissionGrants(repoID: bloom.id).count == 1)
        #expect(try await store.permissionGrants().count == 2 - 1)
    }

    @Test("a project going away takes its grants with it")
    func cascades() async throws {
        let store = try makeTestStore()
        let repo = try await store.upsert(Repo(name: "Bloom", path: "/tmp/bloom-\(newID())"))
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "bin/test:*"),
            repoID: repo.id
        ))

        try await store.deleteRepo(id: repo.id)

        #expect(try await store.permissionGrants().isEmpty)
    }
}


/// A question that outlives the window it was asked in.
///
/// The CLI puts no timer on a `can_use_tool` request: it waits until it is answered, until the
/// call is aborted, or until stdin closes. So a blocked agent stays blocked for as long as Bloom
/// takes, and a Bloom that forgot the question on quit would come back to a transcript that simply
/// stopped mid sentence with a live process behind it that nothing could reach.
@Suite("Pending permission asks", .tags(.persistence), .scratchDirectory)
struct PendingPermissionAskTests {
    private func session(in store: Store, label: String = "s") async throws -> Session {
        let repo = try await store.upsert(Repo(name: "r-\(label)", path: "/tmp/r-\(label)-\(newID())"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: label, branch: "b", path: "/tmp/w-\(label)", baseBranch: "main"
        ))
        return try await store.upsert(Session(workspaceID: workspace.id))
    }

    private var realAsk: PermissionAsk {
        PermissionAsk.decode(payload: Data(PermissionAskTests.realAsk.utf8))!
    }

    @Test("a pending ask comes back whole, with its question intact")
    func roundTrips() async throws {
        let store = try makeTestStore()
        let session = try await session(in: store)
        let ask = realAsk

        try await store.appendPermissionAsk(sessionID: session.id, ask: ask)

        let pending = try await store.pendingPermissionAsks(sessionID: session.id)
        #expect(pending.count == 1)
        // Not merely that a row exists: that the question can still be drawn from it.
        #expect(pending.first?.ask == ask)
        #expect(pending.first?.ask.subject == "sudo -n true")
        #expect(pending.first?.ask.ruleText == "Bash(sudo -n true)")
    }

    @Test("answering it takes it out of the pending list and records what was said")
    func resolving() async throws {
        let store = try makeTestStore()
        let session = try await session(in: store)
        let ask = realAsk
        try await store.appendPermissionAsk(sessionID: session.id, ask: ask)

        try await store.resolvePermissionAsk(
            id: ask.requestID,
            decision: PermissionDecision.allow(scope: .project).storedName
        )

        #expect(try await store.pendingPermissionAsks(sessionID: session.id).isEmpty)
        #expect(try await store.permissionAskDecisions(sessionID: session.id)[ask.requestID] == "allow-project")
    }

    /// The CLI can replay a line, and a replayed question is the same question.
    @Test("the same request id filed twice is one question")
    func idempotent() async throws {
        let store = try makeTestStore()
        let session = try await session(in: store)
        let ask = realAsk

        try await store.appendPermissionAsk(sessionID: session.id, ask: ask)
        try await store.appendPermissionAsk(sessionID: session.id, ask: ask)

        #expect(try await store.pendingPermissionAsks(sessionID: session.id).count == 1)
    }

    @Test("answering twice does not overwrite the first answer")
    func resolvingIsOnce() async throws {
        let store = try makeTestStore()
        let session = try await session(in: store)
        let ask = realAsk
        try await store.appendPermissionAsk(sessionID: session.id, ask: ask)

        try await store.resolvePermissionAsk(id: ask.requestID, decision: "allow-once")
        try await store.resolvePermissionAsk(id: ask.requestID, decision: "deny")

        #expect(try await store.permissionAskDecisions(sessionID: session.id)[ask.requestID] == "allow-once")
    }

    /// What a crash or a force quit leaves behind, and what launch does about it. A pending ask
    /// whose process is gone is not a question, it is four live buttons that write into a closed
    /// pipe.
    @Test("a question nobody can answer any more is closed at launch")
    func abandoning() async throws {
        let store = try makeTestStore()
        let session = try await session(in: store)
        let ask = realAsk
        try await store.appendPermissionAsk(sessionID: session.id, ask: ask)

        let closed = try await store.abandonPendingPermissionAsks()

        #expect(closed == 1)
        #expect(try await store.pendingPermissionAsks().isEmpty)

        let decision = try #require(await store.permissionAskDecisions(sessionID: session.id)[ask.requestID])
        #expect(decision == PermissionAskOutcome.abandoned)
        #expect(PermissionAskOutcome.wentUnanswered(decision))
        // And the row says something true rather than nothing.
        #expect(!PermissionAskOutcome.summary(decision).isEmpty)
        #expect(PermissionAskOutcome.advice(decision).contains("worktree still holds"))
    }

    /// What a crash leaves behind, from both halves at once. The session row and the pending ask
    /// have to be cleared by the same launch, or the two disagree: a session reset to `idle` with
    /// a question still listed as pending would draw a row with live buttons under a workspace
    /// showing no mark at all.
    @Test("a launch after a crash clears the session and the question together")
    func launchAfterACrash() async throws {
        let store = try makeTestStore()
        let session = try await session(in: store)
        try await store.appendPermissionAsk(sessionID: session.id, ask: realAsk)
        try await store.update(sessionID: session.id) { $0.state = .waiting }

        // Exactly what `AppModel` does on the way up.
        try await store.resetRunningSessions()
        let abandoned = try await store.abandonPendingPermissionAsks()

        #expect(abandoned == 1)
        #expect(try await store.session(id: session.id)?.state == .idle)
        #expect(try await store.pendingPermissionAsks().isEmpty)
    }

    /// One query rather than one per session: with five agents running, loading every session to
    /// find out which of them are stuck would be the expensive way to draw a dot.
    @Test("every blocked session is found in one query")
    func acrossSessions() async throws {
        let store = try makeTestStore()
        let first = try await session(in: store, label: "one")
        let second = try await session(in: store, label: "two")
        let third = try await session(in: store, label: "three")

        try await store.appendPermissionAsk(sessionID: first.id, ask: realAsk)
        // A second, genuinely different question rather than the same bytes twice: the request id
        // is the primary key, so filing the same ask under two sessions would store only one.
        let other = try #require(PermissionAsk.decode(payload: Data(
            PermissionAskTests.realAsk
                .replacingOccurrences(of: "2f9899b1-849f-4d1b-b4b2-9c6e1304b300", with: "second-request")
                .utf8
        )))
        try await store.appendPermissionAsk(sessionID: second.id, ask: other)

        let pending = try await store.pendingPermissionAsks()
        #expect(pending.count == 2)
        #expect(Set(pending.map(\.sessionID)) == [first.id, second.id])
        #expect(!pending.map(\.sessionID).contains(third.id))
    }

    @Test("a session going away takes its questions with it")
    func cascades() async throws {
        let store = try makeTestStore()
        let session = try await session(in: store)
        try await store.appendPermissionAsk(sessionID: session.id, ask: realAsk)

        try await store.deleteSession(id: session.id)

        #expect(try await store.pendingPermissionAsks().isEmpty)
    }

    /// A row Bloom cannot read is a question it cannot draw. Skipping it beats an ask with no
    /// command and four live buttons.
    @Test("bytes that will not decode are skipped rather than drawn empty")
    func unreadablePayload() async throws {
        let store = try makeTestStore()
        let session = try await session(in: store)
        try await store.appendPermissionAsk(
            sessionID: session.id,
            ask: PermissionAsk(requestID: "broken", toolName: "Bash", raw: Data("not json".utf8))
        )
        try await store.appendPermissionAsk(sessionID: session.id, ask: realAsk)

        let pending = try await store.pendingPermissionAsks(sessionID: session.id)
        #expect(pending.count == 1)
        #expect(pending.first?.requestID == realAsk.requestID)
    }
}
