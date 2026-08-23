import Foundation
import Testing
@testable import BloomCore

/// Searching what the agents said, rather than what the workspaces are called.
///
/// The three halves of it are separable and are tested separately: turning what was typed into an
/// expression FTS5 will accept, deciding what of a JSON transcript row is words, and folding a
/// ranked list of rows into one result per workspace. The store suite at the foot puts all three
/// through real SQLite, because the parts can each be right while the SQL is wrong.
@Suite("Transcript search")
struct TranscriptSearchTests {
    // MARK: - What was typed

    @Test("a word becomes a quoted prefix term while it is still being typed")
    func prefixesTheWordInProgress() {
        #expect(TranscriptSearch.matchExpression(for: "wal") == "\"wal\"*")
    }

    @Test("a finished word is not prefixed")
    func doesNotPrefixAfterASpace() {
        #expect(TranscriptSearch.matchExpression(for: "wal ") == "\"wal\"")
    }

    @Test("several words are all required")
    func joinsWordsWithAnd() {
        #expect(TranscriptSearch.matchExpression(for: "wal checkpoint") == "\"wal\" AND \"checkpoint\"*")
    }

    /// The bug this exists for. FTS5 reads a colon as a column filter and a bare hyphen as a
    /// syntax error, so a pasted file reference or a stray dash came back as "no results" and
    /// there was no way to tell that apart from an honest miss.
    @Test("query syntax the user did not mean is quoted away")
    func quotesFTSSyntax() {
        let expression = TranscriptSearch.matchExpression(for: "Store.swift:1881 - ")
        #expect(expression == "\"Store.swift:1881\"")
    }

    @Test("a double quote inside a term is escaped rather than closing the term")
    func escapesQuotes() {
        #expect(TranscriptSearch.matchExpression(for: "say \"\"hi ") == "\"say\" AND \"hi\"")
    }

    @Test("a quoted phrase stays one phrase and is not prefixed")
    func keepsPhrases() {
        #expect(TranscriptSearch.matchExpression(for: "\"write ahead log\"") == "\"write ahead log\"")
    }

    @Test("nothing worth running comes back as nothing to run")
    func refusesEmptyQueries() {
        #expect(TranscriptSearch.matchExpression(for: "") == nil)
        #expect(TranscriptSearch.matchExpression(for: "  ") == nil)
        #expect(TranscriptSearch.matchExpression(for: "a") == nil)
        #expect(TranscriptSearch.matchExpression(for: "-- ") == nil)
    }

    // MARK: - Snippets

    @Test("marks become segments the view can draw without touching the string again")
    func readsMarkedSnippets() {
        let marked = "…the \u{02}WAL\u{03} was truncated…"
        let snippet = TranscriptSearch.snippet(from: marked)

        #expect(snippet.text == "…the WAL was truncated…")
        #expect(snippet.segments.map(\.isMatch) == [false, true, false])
        #expect(snippet.segments[1].text == "WAL")
    }

    @Test("adjacent matched terms read as one highlight")
    func mergesAdjacentSegments() {
        let snippet = TranscriptSearch.snippet(from: "a \u{02}wal\u{03}\u{02} file\u{03} b")
        #expect(snippet.segments.map(\.text) == ["a ", "wal file", " b"])
    }

    @Test("a snippet with no match in it is one plain segment")
    func handlesUnmarkedText() {
        let snippet = TranscriptSearch.snippet(from: "nothing marked")
        #expect(snippet.segments == [TranscriptSnippet.Segment(text: "nothing marked", isMatch: false)])
    }

    // MARK: - What of a row is words

    private func payload(_ json: String) -> Data { Data(json.utf8) }

    @Test("prose is indexed and the machinery around it is not")
    func indexesProseWithoutIdentifiers() throws {
        let body = try #require(TranscriptSearchText.indexable(
            kind: .assistantText,
            payload: payload("""
            {"type":"assistant","uuid":"9f1c8e2a-4b7d","session_id":"abc-123",
             "message":{"role":"assistant","model":"claude-opus-4",
             "content":[{"type":"text","text":"The WAL was never checkpointed."}]}}
            """)
        ))

        #expect(body.contains("The WAL was never checkpointed."))
        #expect(!body.contains("9f1c8e2a"))
        #expect(!body.contains("abc-123"))
        #expect(!body.contains("claude-opus-4"))
    }

    /// Tool calls are in on purpose. The question the feature answers is as often settled by the
    /// grep the agent ran as by the sentence it wrote afterwards.
    @Test("a tool call carries its name and its arguments into the index")
    func indexesToolCalls() throws {
        let body = try #require(TranscriptSearchText.indexable(
            kind: .toolUse,
            payload: payload("""
            {"name":"Bash","input":{"command":"sqlite3 bloom.sqlite 'PRAGMA wal_checkpoint'",
             "description":"Checkpoint the write ahead log"}}
            """)
        ))

        #expect(body.contains("Bash"))
        #expect(body.contains("wal_checkpoint"))
        #expect(body.contains("Checkpoint the write ahead log"))
    }

    /// The snippet a reader was handed for "hello" read
    /// "Hello. What are we working on? not_available standard 2026-08-23T10:22:27", which is
    /// `usage.inference_geo`, `usage.service_tier` and the line's own `timestamp` sitting on the
    /// end of the sentence. All three are strings with letters in them, so the only test that
    /// stood between them and the index was the noise list, and they were not on it.
    @Test("the accounting a turn carries beside its words stays out of the index")
    func skipsUsageAndStamps() throws {
        let body = try #require(TranscriptSearchText.indexable(
            kind: .assistantText,
            payload: payload("""
            {"type":"assistant","uuid":"a1","request_id":"req_1","timestamp":"2026-08-23T10:22:27.000Z",
             "message":{"role":"assistant","model":"claude-sonnet-5",
             "content":[{"type":"text","text":"Hello. We are looking at the QA worktree."}],
             "usage":{"input_tokens":2,"output_tokens":3,"service_tier":"standard",
             "inference_geo":"not_available"},
             "context_management":{"applied_edits":["cleared the oldest turn"]}},
             "modelUsage":{"claude-sonnet-5":{"provider":"firstParty","canonicalModel":"claude-sonnet-5"}},
             "stop_reason":"end_turn","fast_mode_state":"off"}
            """)
        ))

        #expect(body == "Hello. We are looking at the QA worktree.")
    }

    /// The reasoning effort, which Codex sends beside every turn and which read as the word
    /// "standard" or "high" dropped into the middle of somebody's sentence.
    @Test("the reasoning effort is a setting rather than a sentence")
    func skipsReasoningEffort() throws {
        let body = try #require(TranscriptSearchText.indexable(
            kind: .user,
            payload: payload("""
            {"msg":{"text":"Move the checkpoint into the copy."},
             "reasoningEffort":"medium","effort":"high","created_at":"2026-08-23T10:22:27Z"}
            """)
        ))

        #expect(body == "Move the checkpoint into the copy.")
    }

    @Test("a row of counters and costs is not indexed at all")
    func skipsResultRows() {
        #expect(TranscriptSearchText.indexable(
            kind: .result,
            payload: payload("{\"subtype\":\"success\",\"total_cost_usd\":0.42}")
        ) == nil)
        #expect(TranscriptSearchText.indexable(kind: .notice, payload: payload("{\"a\":\"b\"}")) == nil)
    }

    @Test("the same sentence appearing twice in one line is indexed once")
    func dedupesRepeatedText() throws {
        let body = try #require(TranscriptSearchText.indexable(
            kind: .assistantText,
            payload: payload("{\"text\":\"one sentence\",\"content\":[{\"text\":\"one sentence\"}]}")
        ))
        #expect(body == "one sentence")
    }

    @Test("a payload that is not JSON is still words")
    func handlesPlainPayloads() {
        #expect(TranscriptSearchText.indexable(
            kind: .user, payload: payload("just some text")
        ) == "just some text")
    }

    @Test("a very long tool result is cut rather than indexed whole")
    func capsLongRows() throws {
        let long = String(repeating: "checkpoint ", count: 4_000)
        let body = try #require(TranscriptSearchText.indexable(
            kind: .toolResult, payload: payload("{\"content\":\"\(long)\"}")
        ))
        #expect(body.count <= TranscriptSearchText.limit)
    }

    // MARK: - One result per workspace

    private func match(_ workspace: String, seq: Int, score: Double) -> TranscriptMatch {
        TranscriptMatch(
            messageID: Int64(seq),
            workspaceID: WorkspaceID(workspace),
            sessionID: SessionID("s-\(workspace)"),
            sessionTitle: "Session",
            seq: seq,
            kind: .assistantText,
            createdAt: Date(timeIntervalSince1970: 0),
            snippet: TranscriptSnippet(segments: []),
            score: score
        )
    }

    /// A workspace where the word appears forty times is one answer, not forty, and it must not
    /// push the other four workspaces off the screen.
    @Test("a workspace with many matches is one row that says how many")
    func foldsAWorkspaceIntoOneRow() {
        let matches = (0..<40).map { match("noisy", seq: $0, score: -1) } + [match("quiet", seq: 99, score: -0.5)]
        let grouped = TranscriptSearch.group(matches)

        #expect(grouped.count == 2)
        #expect(grouped[0].workspaceID == WorkspaceID("noisy"))
        #expect(grouped[0].matches.count == TranscriptSearch.matchesPerWorkspace)
        #expect(grouped[0].total == 40)
        #expect(grouped[1].workspaceID == WorkspaceID("quiet"))
    }

    @Test("the count comes from the whole index rather than from what was fetched")
    func prefersTheCountedTotal() {
        let grouped = TranscriptSearch.group(
            [match("w", seq: 1, score: -2)],
            totals: [WorkspaceID("w"): 91]
        )
        #expect(grouped.first?.total == 91)
    }

    @Test("workspaces come back in the order of their best match")
    func keepsRankOrder() {
        let grouped = TranscriptSearch.group([
            match("b", seq: 1, score: -3),
            match("a", seq: 2, score: -2),
            match("b", seq: 3, score: -1),
        ])
        #expect(grouped.map(\.workspaceID) == [WorkspaceID("b"), WorkspaceID("a")])
    }
}

/// The index against real SQLite: that it is written when a message is, that it survives the row
/// being deleted, and that the backfill can be stopped and started again.
@Suite("Transcript index", .tags(.persistence), .scratchDirectory)
struct TranscriptIndexTests {
    private func makeSession(_ store: Store, workspace name: String = "w") async throws -> Session {
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: "b", path: "/tmp/\(name)", baseBranch: "main"
        ))
        return try await store.upsert(Session(workspaceID: workspace.id, title: "Session", model: "opus"))
    }

    private func say(_ store: Store, _ session: Session, _ text: String) async throws {
        try await store.appendNext(
            sessionID: session.id,
            kind: .assistantText,
            payload: Data("{\"text\":\"\(text)\"}".utf8)
        )
    }

    @Test("a message is searchable as soon as it is written")
    func indexesOnInsert() async throws {
        let store = try makeTestStore("transcript-index")
        let session = try await makeSession(store)
        try await say(store, session, "the WAL was never checkpointed")

        let results = try await store.searchTranscripts("checkpoint")
        #expect(results.count == 1)
        #expect(results.first?.matches.first?.sessionID == session.id)
        #expect(results.first?.matches.first?.snippet.segments.contains { $0.isMatch } == true)
    }

    /// The stemmer earns its place here: nobody types the word the agent happened to use.
    @Test("a search finds a word in another of its forms")
    func stemsTheQueryAndTheText() async throws {
        let store = try makeTestStore("transcript-stem")
        let session = try await makeSession(store)
        try await say(store, session, "I worked out the checkpointing")

        #expect(try await store.searchTranscripts("working ").count == 1)
    }

    /// A result has to say where in the transcript it is, or the reader is left scrolling.
    @Test("a result carries the session and the position of the row")
    func pointsAtTheRow() async throws {
        let store = try makeTestStore("transcript-target")
        let session = try await makeSession(store)
        try await say(store, session, "nothing to see")
        try await say(store, session, "the vacuum ran")

        let match = try #require(try await store.searchTranscripts("vacuum ").first?.matches.first)
        #expect(match.seq == 1)
        #expect(match.sessionID == session.id)
    }

    @Test("archiving a workspace takes its transcript out of the index with it")
    func followsTheCascade() async throws {
        let store = try makeTestStore("transcript-cascade")
        let session = try await makeSession(store)
        try await say(store, session, "an unrepeatable word: zarquon")
        #expect(try await store.searchTranscripts("zarquon").count == 1)

        try await store.deleteWorkspace(id: session.workspaceID)
        #expect(try await store.searchTranscripts("zarquon").isEmpty)
    }

    /// Existing databases have months of messages that were written before the index existed.
    @Test("a database written before the index existed is backfilled, newest first")
    func backfillsInBatches() async throws {
        let path = TestScratch.unique("transcript-backfill") + ".sqlite"
        let store = try Store(path: path)
        let session = try await makeSession(store)
        for index in 0..<10 {
            try await say(store, session, "message number \(index) about pelicans")
        }

        // Wind the index back to what an old database looks like: rows in `messages`, nothing in
        // `message_search`, and the cursor above all of them.
        try await store.forgetTranscriptIndexForTesting()
        #expect(try await store.searchTranscripts("pelicans").isEmpty)
        #expect(try await store.isTranscriptIndexIncomplete())

        // One small batch first, which is also the interruption: whatever it did is on disk.
        let first = try await store.indexOlderTranscripts(batch: 4)
        #expect(first.scanned == 4)
        #expect(!first.isFinished)
        #expect(try await store.searchTranscripts("pelicans").first?.total == 4)

        while try await !store.indexOlderTranscripts(batch: 4).isFinished {}
        #expect(try await store.searchTranscripts("pelicans").first?.total == 10)
        #expect(try await !store.isTranscriptIndexIncomplete())
    }

    @Test("re-running a batch that already ran indexes each row once")
    func isSafeToRepeat() async throws {
        let store = try makeTestStore("transcript-repeat")
        let session = try await makeSession(store)
        try await say(store, session, "one about pelicans")
        try await store.forgetTranscriptIndexForTesting()

        try await store.indexOlderTranscripts(batch: 1)
        try await store.rewindTranscriptBackfillForTesting()
        try await store.indexOlderTranscripts(batch: 1)

        #expect(try await store.searchTranscripts("pelicans").first?.total == 1)
    }

    @Test("a workspace with many hits is one result with a count")
    func groupsRealResults() async throws {
        let store = try makeTestStore("transcript-group")
        let session = try await makeSession(store, workspace: "noisy")
        for index in 0..<12 {
            try await say(store, session, "turn \(index) mentions pelicans again")
        }

        let results = try await store.searchTranscripts("pelicans")
        #expect(results.count == 1)
        #expect(results[0].matches.count == TranscriptSearch.matchesPerWorkspace)
        #expect(results[0].total == 12)
    }
}
