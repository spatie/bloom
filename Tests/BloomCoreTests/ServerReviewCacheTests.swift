import Foundation
import Testing
@testable import BloomCore

@Suite("ServerReviewCache", .scratchDirectory, .tags(.subprocess))
struct ServerReviewCacheTests {
    private func fixture() async throws -> (TempRepo, Workspace) {
        let repo = try await TempRepo()
        try repo.write("a.txt", "before\n")
        try repo.write("b.txt", "before\n")
        try await repo.commit("Review fixture")
        try repo.write("a.txt", "after!\n")
        try repo.write("b.txt", "after!\n")
        return (repo, Workspace(repoID: .new(), name: "Review", branch: "main", path: repo.path, baseBranch: "main"))
    }

    @Test func warmAndConcurrentReadsShareSnapshotsAndPatches() async throws {
        let (_, workspace) = try await fixture()
        let cache = ServerReviewCache()
        let snapshot = try await cache.snapshot(workspace: workspace, scope: .branch)
        let empty = try await cache.snapshot(workspace: workspace, scope: .branch, knownRevision: snapshot.revision)
        #expect(empty.files == nil)
        let results = try await withThrowingTaskGroup(of: ServerPatchSnapshot.self, returning: [ServerPatchSnapshot].self) { group in
            for _ in 0..<12 { group.addTask { try await cache.patch(workspace: workspace, path: "a.txt", scope: .branch) } }
            var results: [ServerPatchSnapshot] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(Set(results.map(\.revision)).count == 1)
        #expect(results.allSatisfy { $0.patch?.contains("+after!") == true })
        let conditional = try await cache.patch(workspace: workspace, path: "a.txt", scope: .branch, knownRevision: results[0].revision)
        #expect(conditional.patch == nil)
        let metrics = await cache.metrics
        #expect(metrics.patchBuilds == 1)
        #expect(metrics.scans == 1)
        await cache.shutdown()
    }

    @Test func notificationsDetectEqualSizeEqualCountEditsAndNewDirectories() async throws {
        let (repo, workspace) = try await fixture()
        let cache = ServerReviewCache(backstop: .seconds(2))
        let first = try await cache.snapshot(workspace: workspace, scope: .branch)
        let old = try #require(first.files?.first { $0.path == "a.txt" })
        let waiting = Task { try await cache.snapshot(workspace: workspace, scope: .branch, knownRevision: first.revision, wait: true) }
        try repo.write("a.txt", "other!\n")
        let second = try await waiting.value
        let changed = try #require(second.files?.first { $0.path == "a.txt" })
        #expect(old.additions == changed.additions)
        #expect(old.deletions == changed.deletions)
        #expect(old.contentRevision != changed.contentRevision)
        let patch = try await cache.patch(workspace: workspace, path: "a.txt", scope: .branch, knownRevision: old.contentRevision)
        #expect(patch.patch?.contains("+other!") == true)
        try repo.write("new/deep/file.txt", "New file\n")
        let third = try await cache.snapshot(workspace: workspace, scope: .branch, knownRevision: second.revision, wait: true)
        #expect(third.files?.contains { $0.path == "new/deep/file.txt" } == true)
        await cache.shutdown()
    }

    @Test func unrelatedEditsKeepOtherFileRevisionsAndUnsafePathsRemainRefused() async throws {
        let (repo, workspace) = try await fixture()
        let cache = ServerReviewCache(backstop: .seconds(1))
        let first = try await cache.snapshot(workspace: workspace, scope: .branch)
        let held = try await cache.patch(workspace: workspace, path: "a.txt", scope: .branch)
        try repo.write("b.txt", "another change\n")
        _ = try await cache.snapshot(workspace: workspace, scope: .branch, knownRevision: first.revision, wait: true)
        let same = try await cache.patch(workspace: workspace, path: "a.txt", scope: .branch, knownRevision: held.revision)
        #expect(same.patch == nil)
        await #expect(throws: (any Error).self) { try await cache.patch(workspace: workspace, path: "../a.txt", scope: .branch) }
        await #expect(throws: (any Error).self) { try await cache.patch(workspace: workspace, path: "/etc/passwd", scope: .branch) }
        await cache.shutdown()
    }

    @Test func evictionAndLargeFileLimitsAreEnforced() async throws {
        let (repo, workspace) = try await fixture()
        let cache = ServerReviewCache(patchBudget: 1)
        _ = try await cache.patch(workspace: workspace, path: "a.txt", scope: .branch)
        #expect(await cache.metrics.retainedPatchBytes == 0)
        _ = try await cache.patch(workspace: workspace, path: "a.txt", scope: .branch)
        #expect(await cache.metrics.patchBuilds == 2)
        try repo.write("a.txt", String(repeating: "x", count: ServerReview.fileLimit + 1))
        await #expect(throws: (any Error).self) { try await cache.patch(workspace: workspace, path: "a.txt", scope: .branch) }
        await cache.shutdown()
    }

    @Test func scopeChangesAndCommitEventsInvalidateTheCorrectBase() async throws {
        let (repo, workspace) = try await fixture()
        let cache = ServerReviewCache(backstop: .seconds(1))
        let uncommitted = try await cache.snapshot(workspace: workspace, scope: .uncommitted)
        try await repo.commit("Commit edits")
        let committed = try await cache.snapshot(workspace: workspace, scope: .uncommitted, knownRevision: uncommitted.revision, wait: true)
        #expect(committed.files?.isEmpty == true)
        await cache.shutdown()
    }
}
