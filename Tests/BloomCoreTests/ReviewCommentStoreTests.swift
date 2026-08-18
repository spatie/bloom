import Testing
import Foundation
@testable import BloomCore

/// Review comments are per-workspace working state, so the things that can go wrong in storage are
/// a mangled anchor, a body that lost its line breaks, and one workspace's review disturbing
/// another's.
@Suite("Review comment store", .tags(.persistence), .scratchDirectory)
struct ReviewCommentStoreTests {
    private func workspace(in store: Store, name: String = "w") async throws -> Workspace {
        let repo = try await store.upsert(Repo(name: "r-\(name)", path: "/tmp/r-\(name)"))
        return try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: "b", path: "/tmp/r-\(name)-w", baseBranch: "main"
        ))
    }

    private func anchor(_ line: Int) -> ReviewCommentAnchor {
        ReviewCommentAnchor(
            line: line, text: "        return \"hello\"", before: ["{", ""], after: ["}", ""]
        )
    }

    @Test("round-trips a comment including unicode and a multi-line body")
    func roundTrips() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        let body = "Réponse 🎉\nsecond line\n\n    indented\ttab"
        let comment = ReviewComment(
            workspaceID: workspace.id,
            filePath: "Sources/Widget.swift",
            side: .old,
            anchor: anchor(34),
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isAttached: false
        )

        try await store.upsert(comment)
        let loaded = try #require(try await store.reviewComments(workspaceID: workspace.id).first)

        #expect(loaded == comment)
        #expect(loaded.body == body)
        #expect(loaded.anchor.before == ["{", ""])
        #expect(loaded.anchor.after == ["}", ""])
        #expect(loaded.side == .old)
        #expect(loaded.isAttached == false)
    }

    @Test("keeps an empty context list apart from a blank context line")
    func keepsEmptyContextApart() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        let empty = ReviewComment(
            workspaceID: workspace.id, filePath: "a.swift",
            anchor: ReviewCommentAnchor(line: 1, text: "x"), body: "empty"
        )
        let blank = ReviewComment(
            workspaceID: workspace.id, filePath: "b.swift",
            anchor: ReviewCommentAnchor(line: 1, text: "x", before: [""], after: [""]),
            body: "blank"
        )

        try await store.upsert(empty)
        try await store.upsert(blank)
        let loaded = try await store.reviewComments(workspaceID: workspace.id)

        // Newline-joined storage cannot tell these two apart, and getting it wrong shifts every
        // stored snippet by one line.
        #expect(loaded.first(where: { $0.body == "empty" })?.anchor.before == [])
        #expect(loaded.first(where: { $0.body == "blank" })?.anchor.before == [""])
    }

    @Test("orders by file and line")
    func orders() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        for (path, line) in [("b.swift", 1), ("a.swift", 40), ("a.swift", 2)] {
            try await store.upsert(ReviewComment(
                workspaceID: workspace.id, filePath: path, anchor: anchor(line), body: "\(path)\(line)"
            ))
        }

        let loaded = try await store.reviewComments(workspaceID: workspace.id)

        #expect(loaded.map(\.body) == ["a.swift2", "a.swift40", "b.swift1"])
    }

    @Test("returns only the comments on one file")
    func filtersByFile() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        try await store.upsert(ReviewComment(
            workspaceID: workspace.id, filePath: "a.swift", anchor: anchor(1), body: "a"
        ))
        try await store.upsert(ReviewComment(
            workspaceID: workspace.id, filePath: "b.swift", anchor: anchor(1), body: "b"
        ))

        let loaded = try await store.reviewComments(workspaceID: workspace.id, filePath: "a.swift")

        #expect(loaded.map(\.body) == ["a"])
    }

    @Test("updates only the body when a comment is edited")
    func updatesBody() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        // A whole number of seconds, because a timestamp is stored as a SQLite REAL and comparing
        // a round-tripped `Date()` to the original is a test about floating point, not about this.
        let comment = ReviewComment(
            workspaceID: workspace.id, filePath: "a.swift", anchor: anchor(12), body: "first",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.upsert(comment)

        try await store.updateReviewCommentBody(id: comment.id, body: "second\nline")
        let loaded = try #require(try await store.reviewComments(workspaceID: workspace.id).first)

        #expect(loaded.body == "second\nline")
        #expect(loaded.anchor == comment.anchor)
        #expect(loaded.createdAt == comment.createdAt)
    }

    @Test("upserting an edited value replaces the row rather than adding one")
    func upsertsInPlace() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        var comment = ReviewComment(
            workspaceID: workspace.id, filePath: "a.swift", anchor: anchor(12), body: "first"
        )
        try await store.upsert(comment)
        comment.body = "second"
        try await store.upsert(comment)

        let loaded = try await store.reviewComments(workspaceID: workspace.id)

        #expect(loaded.count == 1)
        #expect(loaded[0].body == "second")
    }

    @Test("detaches a comment from the chat without deleting it")
    func detachesOne() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        let comment = ReviewComment(
            workspaceID: workspace.id, filePath: "a.swift", anchor: anchor(3), body: "note"
        )
        try await store.upsert(comment)

        try await store.setReviewCommentAttached(id: comment.id, attached: false)

        #expect(try await store.attachedReviewComments(workspaceID: workspace.id).isEmpty)
        #expect(try await store.reviewComments(workspaceID: workspace.id).count == 1)

        try await store.setReviewCommentAttached(id: comment.id, attached: true)
        #expect(try await store.attachedReviewComments(workspaceID: workspace.id).count == 1)
    }

    @Test("detaches the whole workspace once the message has gone out")
    func detachesAll() async throws {
        let store = try makeTestStore()
        let mine = try await workspace(in: store, name: "mine")
        let other = try await workspace(in: store, name: "other")
        for line in 1...3 {
            try await store.upsert(ReviewComment(
                workspaceID: mine.id, filePath: "a.swift", anchor: anchor(line), body: "n\(line)"
            ))
        }
        try await store.upsert(ReviewComment(
            workspaceID: other.id, filePath: "a.swift", anchor: anchor(1), body: "theirs"
        ))

        try await store.detachReviewComments(workspaceID: mine.id)

        #expect(try await store.attachedReviewComments(workspaceID: mine.id).isEmpty)
        #expect(try await store.reviewComments(workspaceID: mine.id).count == 3)
        #expect(try await store.attachedReviewComments(workspaceID: other.id).count == 1)
    }

    @Test("deletes a single comment")
    func deletesOne() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        let first = ReviewComment(
            workspaceID: workspace.id, filePath: "a.swift", anchor: anchor(1), body: "one"
        )
        let second = ReviewComment(
            workspaceID: workspace.id, filePath: "a.swift", anchor: anchor(2), body: "two"
        )
        try await store.upsert(first)
        try await store.upsert(second)

        try await store.deleteReviewComment(id: first.id)

        #expect(try await store.reviewComments(workspaceID: workspace.id).map(\.body) == ["two"])
    }

    @Test("clearing one workspace's review leaves another's alone", .tags(.destructive))
    func deletesPerWorkspace() async throws {
        let store = try makeTestStore()
        let mine = try await workspace(in: store, name: "mine")
        let other = try await workspace(in: store, name: "other")
        try await store.upsert(ReviewComment(
            workspaceID: mine.id, filePath: "a.swift", anchor: anchor(1), body: "mine"
        ))
        try await store.upsert(ReviewComment(
            workspaceID: other.id, filePath: "a.swift", anchor: anchor(1), body: "theirs"
        ))

        try await store.deleteReviewComments(workspaceID: mine.id)

        #expect(try await store.reviewComments(workspaceID: mine.id).isEmpty)
        #expect(try await store.reviewComments(workspaceID: other.id).map(\.body) == ["theirs"])
    }

    @Test("a deleted workspace takes its review with it", .tags(.destructive))
    func cascadesFromWorkspace() async throws {
        let store = try makeTestStore()
        let mine = try await workspace(in: store, name: "mine")
        let other = try await workspace(in: store, name: "other")
        try await store.upsert(ReviewComment(
            workspaceID: mine.id, filePath: "a.swift", anchor: anchor(1), body: "mine"
        ))
        try await store.upsert(ReviewComment(
            workspaceID: other.id, filePath: "a.swift", anchor: anchor(1), body: "theirs"
        ))

        try await store.deleteWorkspace(id: mine.id)

        #expect(try await store.reviewComments(workspaceID: mine.id).isEmpty)
        #expect(try await store.reviewComments(workspaceID: other.id).count == 1)
    }

    @Test("survives reopening the database")
    func survivesReopen() async throws {
        let path = TestScratch.unique("review") + ".sqlite"
        let comment: ReviewComment
        do {
            let store = try Store(path: path)
            let workspace = try await workspace(in: store)
            comment = ReviewComment(
                workspaceID: workspace.id, filePath: "a.swift", anchor: anchor(7), body: "keep 🎈",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try await store.upsert(comment)
        }

        let reopened = try Store(path: path)
        let loaded = try await reopened.reviewComments(workspaceID: comment.workspaceID)

        #expect(loaded == [comment])
    }
}
