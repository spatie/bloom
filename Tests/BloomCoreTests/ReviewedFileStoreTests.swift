import Testing
import Foundation
@testable import BloomCore

/// The ticks are per-workspace working state, so what can go wrong in storage is a mark that
/// outlives its workspace, a second row for a file already ticked, and one workspace's pass
/// showing up in another's.
@Suite("Viewed file store", .tags(.persistence), .scratchDirectory)
struct ReviewedFileStoreTests {
    private func workspace(in store: Store, name: String = "w") async throws -> Workspace {
        let repo = try await store.upsert(Repo(name: "r-\(name)", path: "/tmp/r-\(name)"))
        return try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: "b", path: "/tmp/r-\(name)-w", baseBranch: "main"
        ))
    }

    @Test("round-trips a mark with the diff it was given for")
    func roundTrips() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        let mark = ReviewedFile(
            workspaceID: workspace.id,
            path: "Sources/Widget.swift",
            fingerprint: "M:4:1:0",
            viewedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.markReviewed(mark)
        let loaded = try #require(try await store.reviewedFiles(workspaceID: workspace.id).first)

        #expect(loaded == mark)
    }

    @Test("ticking the same file twice is one row, holding the newer diff")
    func upserts() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        let path = "Sources/Widget.swift"

        try await store.markReviewed(ReviewedFile(
            workspaceID: workspace.id, path: path, fingerprint: "M:4:1:0"
        ))
        try await store.markReviewed(ReviewedFile(
            workspaceID: workspace.id, path: path, fingerprint: "M:9:2:0"
        ))

        let marks = try await store.reviewedFiles(workspaceID: workspace.id)
        #expect(marks.count == 1)
        #expect(marks.first?.fingerprint == "M:9:2:0")
    }

    @Test("one workspace's pass is invisible to another")
    func staysInItsWorkspace() async throws {
        let store = try makeTestStore()
        let mine = try await workspace(in: store, name: "mine")
        let yours = try await workspace(in: store, name: "yours")

        try await store.markReviewed(ReviewedFile(
            workspaceID: mine.id, path: "a.swift", fingerprint: "M:1:0:0"
        ))

        #expect(try await store.reviewedFiles(workspaceID: yours.id).isEmpty)
        #expect(try await store.reviewedFiles(workspaceID: mine.id).count == 1)
    }

    @Test("clearing takes one file off, or the whole pass")
    func clears() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        for path in ["a.swift", "b.swift", "c.swift"] {
            try await store.markReviewed(ReviewedFile(
                workspaceID: workspace.id, path: path, fingerprint: "M:1:0:0"
            ))
        }

        try await store.clearReviewed(workspaceID: workspace.id, path: "b.swift")
        #expect(try await store.reviewedFiles(workspaceID: workspace.id).map(\.path)
            == ["a.swift", "c.swift"])

        try await store.clearReviewed(workspaceID: workspace.id)
        #expect(try await store.reviewedFiles(workspaceID: workspace.id).isEmpty)
    }

    @Test("a deleted workspace takes its ticks with it", .tags(.destructive))
    func cascadesFromWorkspace() async throws {
        let store = try makeTestStore()
        let mine = try await workspace(in: store, name: "mine")
        let other = try await workspace(in: store, name: "other")
        try await store.markReviewed(ReviewedFile(
            workspaceID: mine.id, path: "a.swift", fingerprint: "M:1:0:0"
        ))
        try await store.markReviewed(ReviewedFile(
            workspaceID: other.id, path: "a.swift", fingerprint: "M:1:0:0"
        ))

        try await store.deleteWorkspace(id: mine.id)

        #expect(try await store.reviewedFiles(workspaceID: mine.id).isEmpty)
        #expect(try await store.reviewedFiles(workspaceID: other.id).count == 1)
    }

    @Test("a comment keeps how many lines it covers across a write")
    func roundTripsASpan() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        let comment = ReviewComment(
            workspaceID: workspace.id,
            filePath: "Sources/Widget.swift",
            anchor: ReviewCommentAnchor(
                line: 12, text: "func render() {", before: ["}"], after: ["    return 1"], span: 5
            ),
            body: "these five belong in one function",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.upsert(comment)
        let loaded = try #require(try await store.reviewComments(workspaceID: workspace.id).first)

        #expect(loaded == comment)
        #expect(loaded.anchor.span == 5)
        #expect(loaded.anchor.lastLine == 16)
    }

    @Test("a comment written before ranges existed covers one line")
    func defaultsTheSpan() async throws {
        let store = try makeTestStore()
        let workspace = try await workspace(in: store)
        let comment = ReviewComment(
            workspaceID: workspace.id,
            filePath: "a.swift",
            anchor: ReviewCommentAnchor(line: 3, text: "x"),
            body: "note"
        )

        try await store.upsert(comment)
        let loaded = try #require(try await store.reviewComments(workspaceID: workspace.id).first)

        #expect(loaded.anchor.span == 1)
        #expect(!loaded.anchor.isRange)
    }
}
