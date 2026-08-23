import Testing
import Foundation
@testable import BloomCore

/// The one path in Bloom that destroys a transcript, and the numbers a person decides with.
@Suite("Archive cleanup", .tags(.persistence), .scratchDirectory)
struct ArchiveCleanupTests {
    // MARK: - Measuring

    @Test("only archived workspaces are measured")
    func measuresOnlyArchived() async throws {
        let store = try makeTestStore("archive-scope")
        let repo = try await store.upsert(Repo(name: "there-there", path: "/tmp/tt"))
        _ = try await store.upsert(Workspace(
            repoID: repo.id, name: "live", branch: "b1", path: "/tmp/live", baseBranch: "main"
        ))
        _ = try await archive(store, repo: repo, name: "old", branch: "b2")

        let footprints = try await store.archivedFootprints()
        #expect(footprints.count == 1)
        #expect(footprints[0].workspace.name == "old")
        #expect(footprints[0].repoName == "there-there")
    }

    @Test("the transcript is measured in the bytes its payloads actually hold")
    func measuresTranscriptBytes() async throws {
        let store = try makeTestStore("archive-bytes")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await archive(store, repo: repo, name: "w", branch: "b")
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "S", model: "opus"))

        var expected = 0
        for index in 0..<20 {
            let payload = Data(String(repeating: "x", count: 100 + index).utf8)
            expected += payload.count
            try await store.appendNext(sessionID: session.id, kind: .assistantText, payload: payload)
        }

        let footprint = try #require(try await store.archivedFootprints().first)
        #expect(footprint.messageCount == 20)
        #expect(footprint.sessionCount == 1)
        #expect(footprint.transcriptBytes == expected)
    }

    /// A workspace nobody ever ran an agent in still has to appear, or the list quietly loses the
    /// rows that are cheapest to delete.
    @Test("a workspace with no transcript at all is still a row")
    func measuresAnEmptyWorkspace() async throws {
        let store = try makeTestStore("archive-empty")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        _ = try await archive(store, repo: repo, name: "w", branch: "b")

        let footprint = try #require(try await store.archivedFootprints().first)
        #expect(footprint.messageCount == 0)
        #expect(footprint.transcriptBytes == 0)
        #expect(footprint.hasNote == false)
        #expect(footprint.reviewCommentCount == 0)
    }

    /// Counting on a join of messages and comments multiplies one by the other. This is that bug
    /// written down.
    @Test("review comments and notes are counted once, whatever the transcript is doing")
    func countsAsideFromTheTranscript() async throws {
        let store = try makeTestStore("archive-aside")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await archive(store, repo: repo, name: "w", branch: "b")
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "S", model: "opus"))
        for _ in 0..<9 {
            try await store.appendNext(
                sessionID: session.id, kind: .assistantText, payload: Data("{}".utf8)
            )
        }
        for line in 1...3 {
            _ = try await store.upsert(ReviewComment(
                workspaceID: workspace.id, filePath: "a.swift",
                anchor: ReviewCommentAnchor(line: line, text: "x"), body: "look at this"
            ))
        }
        try await store.saveNote(workspaceID: workspace.id, body: "why this stopped")

        let footprint = try #require(try await store.archivedFootprints().first)
        #expect(footprint.messageCount == 9)
        #expect(footprint.reviewCommentCount == 3)
        #expect(footprint.hasNote)
        #expect(footprint.otherBytes > 0)
    }

    // MARK: - Deleting

    @Test("deleting takes the transcript, the search index and the rows around it")
    func deleteTakesEverything() async throws {
        let store = try makeTestStore("archive-delete")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await archive(store, repo: repo, name: "w", branch: "b")
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "S", model: "opus"))
        try await store.appendNext(
            sessionID: session.id, kind: .assistantText,
            payload: Data("{\"text\":\"an unrepeatable word: zarquon\"}".utf8)
        )
        _ = try await store.upsert(ReviewComment(
            workspaceID: workspace.id, filePath: "a.swift",
            anchor: ReviewCommentAnchor(line: 1, text: "x"), body: "look"
        ))
        try await store.saveNote(workspaceID: workspace.id, body: "a note")
        try await store.saveDraft(sessionID: session.id, body: "half a thought")

        #expect(try await store.searchTranscripts("zarquon").count == 1)

        let deleted = try await store.deleteArchivedWorkspaces(ids: [workspace.id])
        #expect(deleted == 1)

        #expect(try await store.workspace(id: workspace.id) == nil)
        #expect(try await store.sessions(workspaceID: workspace.id).isEmpty)
        #expect(try await store.messages(sessionID: session.id).isEmpty)
        #expect(try await store.reviewComments(workspaceID: workspace.id).isEmpty)
        #expect(try await store.note(workspaceID: workspace.id) == nil)
        #expect(try await store.draft(sessionID: session.id).isEmpty)
        // The FTS rows have no foreign key and can only go through the delete trigger, so this is
        // the assertion that a deleted transcript is actually unsearchable rather than merely
        // unreachable.
        #expect(try await store.searchTranscripts("zarquon").isEmpty)
    }

    /// The list this is called from is built once and confirmed later. A workspace restored in
    /// between must not be destroyed by a click aimed at the row it used to be.
    @Test("a workspace that is not archived is refused, whoever asks")
    func refusesALiveWorkspace() async throws {
        let store = try makeTestStore("archive-refuse")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "live", branch: "b", path: "/tmp/live", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "S", model: "opus"))
        try await store.appendNext(sessionID: session.id, kind: .assistantText, payload: Data("{}".utf8))

        #expect(try await store.deleteArchivedWorkspaces(ids: [workspace.id]) == 0)
        #expect(try await store.workspace(id: workspace.id) != nil)
        #expect(try await store.messages(sessionID: session.id).count == 1)
    }

    @Test("a bulk delete takes the archived rows and leaves the live one standing")
    func deletesInBulk() async throws {
        let store = try makeTestStore("archive-bulk")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let first = try await archive(store, repo: repo, name: "one", branch: "b1")
        let second = try await archive(store, repo: repo, name: "two", branch: "b2")
        let live = try await store.upsert(Workspace(
            repoID: repo.id, name: "live", branch: "b3", path: "/tmp/live", baseBranch: "main"
        ))

        #expect(try await store.deleteArchivedWorkspaces(ids: [first.id, second.id, live.id]) == 2)
        #expect(try await store.archivedFootprints().isEmpty)
        #expect(try await store.workspace(id: live.id) != nil)
    }

    /// The whole path the Archive screen takes, from a selection of several to the rows that are
    /// actually gone, with the one row nobody picked still standing.
    ///
    /// Written because the screen had a route that lost three quarters of a delete between the
    /// list and the confirmation, and because the two halves that route runs through, the
    /// composition and the delete, were each correct on their own. This joins them: the ids that
    /// reach `deleteArchivedWorkspaces` are the ids `ArchiveCleanup.target` produced, the
    /// confirmation's totals are read off the same list, and what the database holds afterwards is
    /// checked row by row rather than by counting.
    @Test("deleting a selection of several takes exactly those rows and no others")
    func deletesExactlyTheSelection() async throws {
        let store = try makeTestStore("archive-selection")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let alpha = try await archive(store, repo: repo, name: "alpha", branch: "b1")
        let bravo = try await archive(store, repo: repo, name: "bravo", branch: "b2")
        let charlie = try await archive(store, repo: repo, name: "charlie", branch: "b3")
        let delta = try await archive(store, repo: repo, name: "delta", branch: "b4")

        var sessions: [WorkspaceID: SessionID] = [:]
        for workspace in [alpha, bravo, charlie, delta] {
            let session = try await store.upsert(
                Session(workspaceID: workspace.id, title: "S", model: "opus")
            )
            sessions[workspace.id] = session.id
            try await store.appendNext(
                sessionID: session.id, kind: .assistantText,
                payload: Data("{\"text\":\"\(workspace.name)\"}".utf8)
            )
        }

        let cleanup = ArchiveCleanup(footprints: try await store.archivedFootprints())
        let selection: Set<WorkspaceID> = [alpha.id, bravo.id, charlie.id]

        // As the row menu now asks: aimed at one row, answered with the selection it sits in.
        let target = cleanup.target(bravo.id, selection: selection, order: .largest)
        #expect(Set(target.map(\.id)) == selection)
        #expect(ArchiveDeletion(target).title == "Delete everything Bloom kept about 3 archived workspaces?")

        let removed = try await store.deleteArchivedWorkspaces(ids: target.map(\.id))
        #expect(removed == 3)

        for id in selection {
            #expect(try await store.workspace(id: id) == nil)
            #expect(try await store.messages(sessionID: sessions[id]!).isEmpty)
        }
        #expect(try await store.workspace(id: delta.id) != nil)
        #expect(try await store.messages(sessionID: sessions[delta.id]!).count == 1)
        #expect(try await store.archivedFootprints().map(\.workspace.name) == ["delta"])
    }

    /// The whole reason this feature reports a number: a delete alone changes nothing on the
    /// filesystem, and only a compaction makes the saving real.
    @Test("the pages a delete frees come back to the file only after a compaction")
    func compactionReclaimsThePages() async throws {
        let store = try makeTestStore("archive-vacuum")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await archive(store, repo: repo, name: "w", branch: "b")
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "S", model: "opus"))
        // Two megabytes of payload, which is enough pages that the free list is unambiguous.
        for index in 0..<200 {
            try await store.appendNext(
                sessionID: session.id, kind: .assistantText,
                payload: Data(String(repeating: "abcdefghij", count: 1_000).utf8)
                    + Data(String(index).utf8)
            )
        }

        let before = try await store.databaseSize()
        #expect(before.totalBytes > 2_000_000)

        try await store.deleteArchivedWorkspaces(ids: [workspace.id])

        let afterDelete = try await store.databaseSize()
        #expect(afterDelete.totalBytes == before.totalBytes)
        #expect(afterDelete.freeBytes > 1_500_000)

        try await store.compactDatabase()

        let afterCompaction = try await store.databaseSize()
        #expect(afterCompaction.freeBytes == 0)
        #expect(afterCompaction.totalBytes < before.totalBytes / 2)

        // And the file on disk, which is the only number a person can check for themselves.
        let onDisk = try FileManager.default
            .attributesOfItem(atPath: store.path)[.size] as? Int ?? 0
        #expect(onDisk < before.totalBytes / 2)
    }

    // MARK: - Ordering

    @Test("largest first puts the row worth deleting at the top")
    func ordersByBytes() {
        let cleanup = ArchiveCleanup(footprints: [
            footprint(name: "small", bytes: 10, archivedAt: 100),
            footprint(name: "huge", bytes: 10_000, archivedAt: 300),
            footprint(name: "middling", bytes: 500, archivedAt: 200),
        ])
        #expect(cleanup.ordered(by: .largest).map(\.workspace.name) == ["huge", "middling", "small"])
        #expect(cleanup.ordered(by: .oldest).map(\.workspace.name) == ["small", "middling", "huge"])
        #expect(cleanup.totalBytes == 10_510)
    }

    /// Two workspaces archived by the same script in the same second are a tie, and a list that
    /// reshuffles them between two refreshes is a list somebody clicks the wrong row in.
    @Test("equal rows keep a stable order")
    func breaksTiesStably() {
        let cleanup = ArchiveCleanup(footprints: [
            footprint(name: "b", bytes: 100, archivedAt: 50, id: "id-b"),
            footprint(name: "a", bytes: 100, archivedAt: 50, id: "id-a"),
        ])
        #expect(cleanup.ordered(by: .largest).map(\.workspace.name) == ["a", "b"])
        #expect(cleanup.ordered(by: .oldest).map(\.workspace.name) == ["a", "b"])
    }

    @Test("a selection is listed the way the list showed it")
    func selectsInOrder() {
        let cleanup = ArchiveCleanup(footprints: [
            footprint(name: "small", bytes: 10, archivedAt: 100, id: "s"),
            footprint(name: "huge", bytes: 10_000, archivedAt: 300, id: "h"),
            footprint(name: "middling", bytes: 500, archivedAt: 200, id: "m"),
        ])
        let selected = cleanup.selected([WorkspaceID("s"), WorkspaceID("h")], order: .largest)
        #expect(selected.map(\.workspace.name) == ["huge", "small"])
    }

    /// The regression this file was reopened for.
    ///
    /// The Archive screen's row menu passed the row it had been opened on and nothing else, so a
    /// right click on one of three selected workspaces confirmed one and deleted one while the
    /// strip above it went on counting three. The core was already plural and already refused
    /// anything that was not archived; what was missing was the rule saying which rows a command
    /// aimed at one row is actually aimed at, and it was missing because it was written inside a
    /// button where nothing could reach it. These two cases are that rule, and they fail on the
    /// composition rather than on the delete, because the delete was never wrong.
    @Test("a command on a row inside the selection is a command on the whole selection")
    func targetsTheWholeSelection() {
        let cleanup = ArchiveCleanup(footprints: [
            footprint(name: "small", bytes: 10, archivedAt: 100, id: "s"),
            footprint(name: "huge", bytes: 10_000, archivedAt: 300, id: "h"),
            footprint(name: "middling", bytes: 500, archivedAt: 200, id: "m"),
        ])
        let selection: Set<WorkspaceID> = [WorkspaceID("s"), WorkspaceID("h")]

        let target = cleanup.target(WorkspaceID("s"), selection: selection, order: .largest)
        #expect(target.map(\.workspace.name) == ["huge", "small"])
        // The number the strip shows and the number the confirmation shows, from one list.
        #expect(ArchiveDeletion(target).totalBytes == cleanup.selected(selection, order: .largest)
            .reduce(0) { $0 + $1.totalBytes })
        #expect(ArchiveDeletion(target).title == "Delete everything Bloom kept about 2 archived workspaces?")
    }

    /// The other half, and the half that keeps this safe: a row outside the selection takes itself
    /// and nothing else. Widening a delete to rows the person never pointed at would be a worse
    /// bug than the one being fixed, so this asserts the answer is exactly one row and that the
    /// singular wording, which is good copy, still arrives.
    @Test("a command on a row outside the selection takes that row alone")
    func targetsOnlyTheRowClicked() {
        let cleanup = ArchiveCleanup(footprints: [
            footprint(name: "small", bytes: 10, archivedAt: 100, id: "s", messages: 2, sessions: 1),
            footprint(name: "huge", bytes: 10_000, archivedAt: 300, id: "h"),
            footprint(name: "middling", bytes: 500, archivedAt: 200, id: "m"),
        ])

        let target = cleanup.target(
            WorkspaceID("s"), selection: [WorkspaceID("h"), WorkspaceID("m")], order: .largest
        )
        #expect(target.map(\.workspace.name) == ["small"])
        #expect(ArchiveDeletion(target).title == "Delete everything Bloom kept about \u{201C}small\u{201D}?")
        #expect(ArchiveDeletion(target).cancelLabel == "Keep the record")

        // And with nothing selected at all, which is the ordinary way the menu is used.
        let alone = cleanup.target(WorkspaceID("m"), selection: [], order: .largest)
        #expect(alone.map(\.workspace.name) == ["middling"])
    }

    /// A selection built from a list one refresh out of date. The id is not there any more, so
    /// there is nothing to delete and nothing is invented to stand in for it.
    @Test("a row that is no longer in the list targets nothing")
    func targetsNothingForAVanishedRow() {
        let cleanup = ArchiveCleanup(footprints: [
            footprint(name: "small", bytes: 10, archivedAt: 100, id: "s"),
        ])
        #expect(cleanup.target(WorkspaceID("gone"), selection: [], order: .largest).isEmpty)
    }

    // MARK: - What the confirmation says

    @Test("the confirmation names what goes, counted and pluralised")
    func namesTheLosses() {
        let deletion = ArchiveDeletion([
            footprint(name: "port work", bytes: 1_500_000, archivedAt: 100, messages: 1, sessions: 1, comments: 1, note: true)
        ])
        #expect(deletion.title == "Delete everything Bloom kept about \u{201C}port work\u{201D}?")
        #expect(deletion.losses[0] == "1 transcript message across 1 chat, holding \(ArchiveDeletion.bytes(1_500_000))")
        #expect(deletion.losses[1] == "1 review comment written by hand")
        #expect(deletion.losses[2] == "a workspace note")
        #expect(deletion.confirmLabel == "Delete permanently")
        #expect(deletion.cancelLabel == "Keep the record")
    }

    @Test("several workspaces are counted rather than named")
    func countsSeveral() {
        let deletion = ArchiveDeletion([
            footprint(name: "a", bytes: 1_000, archivedAt: 1, messages: 4, sessions: 2),
            footprint(name: "b", bytes: 2_000, archivedAt: 2, messages: 6, sessions: 1),
        ])
        #expect(deletion.title == "Delete everything Bloom kept about 2 archived workspaces?")
        #expect(deletion.losses[0] == "10 transcript messages across 3 chats, holding \(ArchiveDeletion.bytes(3_000))")
        #expect(deletion.cancelLabel == "Keep the records")
    }

    @Test("nothing is claimed about a hand-written comment that is not there")
    func staysQuietAboutWhatIsAbsent() {
        let deletion = ArchiveDeletion([footprint(name: "a", bytes: 100, archivedAt: 1, messages: 2, sessions: 1)])
        #expect(deletion.losses.count == 1)
        #expect(!deletion.message.contains("review comment"))
        #expect(!deletion.message.contains("note"))
    }

    /// The hinge of the whole screen. A branch still here means the commits are not in question;
    /// a branch that is gone means this record may be the last thing left.
    @Test("a branch still on this Mac reads differently from one that is not")
    func saysWhereTheBranchStands() {
        var kept = footprint(name: "a", bytes: 100, archivedAt: 1, branch: "feature/ports")
        kept.branchIsLocal = true
        #expect(ArchiveDeletion([kept]).branchStanding?.contains("still on this Mac") == true)
        #expect(ArchiveDeletion([kept]).branchStanding?.contains("feature/ports") == true)

        var gone = kept
        gone.branchIsLocal = false
        let standing = ArchiveDeletion([gone]).branchStanding
        #expect(standing?.contains("not on this Mac") == true)
        #expect(standing?.contains("last thing left") == true)
    }

    /// A screen has no business saying a branch is gone out of a question it never asked.
    @Test("nothing is said about a branch nobody looked for")
    func staysQuietAboutAnUnknownBranch() {
        let unknown = footprint(name: "a", bytes: 100, archivedAt: 1)
        #expect(ArchiveDeletion([unknown]).branchStanding == nil)

        var one = footprint(name: "b", bytes: 100, archivedAt: 1)
        one.branchIsLocal = true
        #expect(ArchiveDeletion([unknown, one]).branchStanding == nil)
    }

    @Test("a mixed selection says how many of the branches are gone")
    func countsTheBranchesThatAreGone() {
        var kept = footprint(name: "a", bytes: 100, archivedAt: 1, id: "a")
        kept.branchIsLocal = true
        var gone = footprint(name: "b", bytes: 100, archivedAt: 1, id: "b")
        gone.branchIsLocal = false
        let standing = ArchiveDeletion([kept, gone]).branchStanding
        #expect(standing?.contains("1 of these 2 branches is no longer on this Mac") == true)
    }

    // MARK: - Compaction offer

    @Test("compaction is offered only when there is something worth reclaiming")
    func offersCompactionWhenItIsWorthIt() {
        let quiet = DatabaseSize(pageSize: 4_096, pageCount: 10_000, freePageCount: 10)
        #expect(!quiet.isWorthCompacting)

        let loaded = DatabaseSize(pageSize: 4_096, pageCount: 10_000, freePageCount: 4_000)
        #expect(loaded.isWorthCompacting)
        #expect(loaded.freeBytes == 16_384_000)
        #expect(loaded.usedBytes == 24_576_000)
    }

    // MARK: - Helpers

    private func archive(
        _ store: Store, repo: Repo, name: String, branch: String
    ) async throws -> Workspace {
        var workspace = Workspace(
            repoID: repo.id, name: name, branch: branch,
            path: "/tmp/\(name)", baseBranch: "main"
        )
        _ = try await store.upsert(workspace)
        workspace.archive()
        workspace.archivedAt = Date()
        return try await store.upsert(workspace)
    }

    private func footprint(
        name: String,
        bytes: Int,
        archivedAt: TimeInterval,
        id: String = UUID().uuidString,
        branch: String = "b",
        messages: Int = 0,
        sessions: Int = 0,
        comments: Int = 0,
        note: Bool = false
    ) -> ArchivedWorkspaceFootprint {
        var workspace = Workspace(
            id: WorkspaceID(id), repoID: RepoID("r"), name: name, branch: branch,
            path: "/tmp/\(name)", baseBranch: "main"
        )
        workspace.archivedAt = Date(timeIntervalSince1970: archivedAt)
        return ArchivedWorkspaceFootprint(
            workspace: workspace,
            repoName: "r",
            sessionCount: sessions,
            messageCount: messages,
            transcriptBytes: bytes,
            otherBytes: 0,
            reviewCommentCount: comments,
            hasNote: note
        )
    }
}
