import Foundation
import Testing
@testable import BloomClient

@MainActor
struct WorkspaceReviewStoreTests {
    private let workspace = WorkspaceID("workspace")
    private func file(_ path: String, revision: String) -> ChangedFile {
        var value = ChangedFile(path: path, change: .modified, additions: 1, deletions: 1)
        value.contentRevision = revision
        return value
    }
    private let patch = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-old\n+new\n"

    @Test func oldScopeReplyCannotOverwriteNewScopeOrClearItsLoadingState() async {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        let old = Task { await store.refresh(using: source) }
        let first = await source.call(0)
        store.setScope(.uncommitted)
        #expect(store.changes.isEmpty)
        #expect(store.hasLoaded == false)
        let current = Task { await store.refresh(using: source) }
        let second = await source.call(1)
        await source.completeSnapshot(first.id, .success(.init(revision: "old", files: [file("old", revision: "1")])))
        await old.value
        #expect(store.isLoading)
        #expect(store.changes.isEmpty)
        await source.completeSnapshot(second.id, .success(.init(revision: "new", files: [file("new", revision: "2")])))
        await current.value
        #expect(store.changes.map(\.path) == ["new"])
        #expect(store.scope == .uncommitted)
        #expect(store.isLoading == false)
    }

    @Test func unchangedSnapshotsKeepLoadedFilesAndDiffs() async throws {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        await seed(store, source: source, files: [file("a.swift", revision: "a1")])
        let load = try #require(store.loadDiff(path: "a.swift", using: source))
        let duplicate = try #require(store.loadDiff(path: "a.swift", using: source))
        let request = await source.call(1)
        await source.completeDiff(request.id, .success(.init(revision: "a1", patch: patch)))
        await load.value; await duplicate.value
        let refresh = Task { await store.refresh(using: source) }
        let snapshot = await source.call(2)
        #expect(snapshot.knownRevision == "snapshot-1")
        await source.completeSnapshot(snapshot.id, .success(.init(revision: "snapshot-1", files: nil)))
        await refresh.value
        #expect(store.hasLoaded)
        #expect(store.diffs["a.swift"]?.additions == 1)
        #expect(store.loadDiff(path: "a.swift", using: source) == nil)
        #expect(await source.count == 3)
    }

    @Test func changingOneFileKeepsOtherFilesCachedAndSendsTheKnownPatchRevision() async throws {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        await seed(store, source: source, files: [file("a.swift", revision: "a1"), file("b.swift", revision: "b1")])
        let first = try #require(store.loadDiff(path: "a.swift", using: source))
        let second = try #require(store.loadDiff(path: "b.swift", using: source))
        for index in 1...2 {
            let request = await source.call(index)
            await source.completeDiff(request.id, .success(.init(revision: request.path == "a.swift" ? "a1" : "b1", patch: patch)))
        }
        await first.value; await second.value
        let refresh = Task { await store.refresh(using: source) }
        let request = await source.call(3)
        await source.completeSnapshot(request.id, .success(.init(revision: "snapshot-2", files: [file("a.swift", revision: "a1"), file("b.swift", revision: "b2")])))
        await refresh.value
        #expect(store.diffs["a.swift"] != nil)
        #expect(store.diffs["b.swift"] == nil)
        #expect(store.loadDiff(path: "a.swift", using: source) == nil)
        let reload = try #require(store.loadDiff(path: "b.swift", using: source))
        let changed = await source.call(4)
        #expect(changed.knownRevision == "b1")
        await source.completeDiff(changed.id, .success(.init(revision: "b2", patch: patch)))
        await reload.value
        #expect(store.diffs.count == 2)
    }

    @Test func nilSnapshotWithoutCachedRevisionIsAnError() async {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        let refresh = Task { await store.refresh(using: source) }
        let request = await source.call(0)
        await source.completeSnapshot(request.id, .success(.init(revision: "unknown", files: nil)))
        await refresh.value
        #expect(store.hasLoaded == false)
        #expect(store.error?.contains("omitted") == true)
    }

    @Test func failuresRemainVisibleUntilRetrySucceeds() async throws {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        await seed(store, source: source, files: [file("a.swift", revision: "a1")])
        let task = try #require(store.loadDiff(path: "a.swift", using: source))
        let request = await source.call(1)
        await source.completeDiff(request.id, .failure(ConnectionFailure("Read failed")))
        await task.value
        #expect(store.errors["a.swift"] == "Read failed")
        #expect(store.loadDiff(path: "a.swift", using: source) == nil)
        let retry = try #require(store.retry(path: "a.swift", using: source))
        let retried = await source.call(2)
        await source.completeDiff(retried.id, .success(.init(revision: "a1", patch: patch)))
        await retry.value
        #expect(store.errors.isEmpty)
        #expect(store.diffs["a.swift"] != nil)
        let refresh = Task { await store.refresh(using: source) }
        let snapshot = await source.call(3)
        await source.completeSnapshot(snapshot.id, .failure(ConnectionFailure("Server disconnected")))
        await refresh.value
        #expect(store.error == "Server disconnected")
        #expect(store.changes.count == 1)
    }

    @Test func atMostTwoDiffReadsRunAndCancelledOldScopeReadsKeepTheirSlots() async throws {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        let files = (1...4).map { file("\($0).swift", revision: "v1") }
        await seed(store, source: source, files: files)
        let old = files.compactMap { store.loadDiff(path: $0.path, using: source) }
        let first = await source.call(1), second = await source.call(2)
        #expect(await source.maximumActiveDiffs == 2)
        store.setScope(.uncommitted)
        let refresh = Task { await store.refresh(using: source) }
        let snapshot = await source.call(3)
        await source.completeSnapshot(snapshot.id, .success(.init(revision: "new", files: files)))
        await refresh.value
        let current = try #require(store.loadDiff(path: "1.swift", using: source))
        await source.completeDiff(first.id, .success(.init(revision: "old", patch: patch)))
        let fresh = await source.call(4)
        #expect(fresh.scope == .uncommitted)
        #expect(store.diffs.isEmpty)
        await source.completeDiff(fresh.id, .success(.init(revision: "v1", patch: patch)))
        await source.completeDiff(second.id, .success(.init(revision: "old", patch: patch)))
        await current.value
        for task in old { await task.value }
        #expect(await source.maximumActiveDiffs == 2)
        #expect(store.diffs.keys.sorted() == ["1.swift"])
    }

    @Test func cancellingARefreshAllowsANewReadWhileTheOldTransportFinishes() async {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        let old = Task { await store.refresh(using: source, refreshFiles: true) }
        let first = await source.call(0)
        store.cancel()
        let fresh = Task { await store.refresh(using: source) }
        let second = await source.call(1)
        await source.completeSnapshot(second.id, .success(.init(revision: "fresh", files: [])))
        await fresh.value
        await source.completeSnapshot(first.id, .success(.init(revision: "stale", files: [file("stale", revision: "old")])))
        await old.value
        #expect(store.revision == "fresh")
        #expect(store.changes.isEmpty)
        #expect(await source.count == 2)
    }

    @Test func conditionalPatchCanReuseTheRetainedParseAfterARevisionCheck() async throws {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        let unversioned = ChangedFile(path: "a.swift", change: .modified)
        await seed(store, source: source, files: [unversioned])
        let first = try #require(store.loadDiff(path: "a.swift", using: source))
        let request = await source.call(1)
        await source.completeDiff(request.id, .success(.init(revision: "patch-1", patch: patch)))
        await first.value
        let refresh = Task { await store.refresh(using: source) }
        let snapshot = await source.call(2)
        await source.completeSnapshot(snapshot.id, .success(.init(revision: "snapshot-2", files: [unversioned])))
        await refresh.value
        let revalidate = try #require(store.loadDiff(path: "a.swift", using: source))
        let check = await source.call(3)
        #expect(check.knownRevision == "patch-1")
        await source.completeDiff(check.id, .success(.init(revision: "patch-1", patch: nil)))
        await revalidate.value
        #expect(store.diffs["a.swift"]?.additions == 1)
        #expect(store.errors.isEmpty)
    }

    @Test func visibleDiffsStayPinnedAndOffscreenDiffsAreBounded() async throws {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace, cacheCapacity: 1)
        await seed(store, source: source, files: [file("a.swift", revision: "a1"), file("b.swift", revision: "b1")])
        store.setVisiblePaths(["a.swift", "b.swift"])
        let first = try #require(store.loadDiff(path: "a.swift", using: source))
        let second = try #require(store.loadDiff(path: "b.swift", using: source))
        for index in 1...2 {
            let request = await source.call(index)
            await source.completeDiff(request.id, .success(.init(revision: "patch", patch: patch)))
        }
        await first.value; await second.value
        #expect(store.diffs.count == 2)
        store.setVisiblePaths(["b.swift"])
        #expect(store.diffs.keys.sorted() == ["b.swift"])
    }

    @Test func repeatedConnectionFailureDoesNotRecursivelyNotifyTheView() {
        let store = WorkspaceReviewStore(workspaceID: workspace)
        var notifications = 0
        store.changed = {
            notifications += 1
            store.reportConnectionFailure("Reconnect")
        }
        store.reportConnectionFailure("Reconnect")
        #expect(notifications == 1)
    }

    @Test func cancelledSourceReadCannotReturnAfterAReplacementRead() async throws {
        let source = ReviewFixture(), store = WorkspaceReviewStore(workspaceID: workspace)
        let old = Task { try await store.readFile(path: "a.swift", using: source) }
        let first = await source.call(0)
        store.cancel()
        let fresh = Task { try await store.readFile(path: "a.swift", using: source) }
        let second = await source.call(1)
        await source.completeText(second.id, .init(path: "a.swift", text: "new", revision: "2"))
        let current = try await fresh.value
        #expect(current.text == "new")
        await source.completeText(first.id, .init(path: "a.swift", text: "old", revision: "1"))
        await #expect(throws: CancellationError.self) { try await old.value }
    }

    private func seed(_ store: WorkspaceReviewStore, source: ReviewFixture, files: [ChangedFile]) async {
        let task = Task { await store.refresh(using: source) }
        let request = await source.call(0)
        await source.completeSnapshot(request.id, .success(.init(revision: "snapshot-1", files: files)))
        await task.value
    }
}

private actor ReviewFixture: WorkspaceReviewReading {
    struct Call: Sendable { let id: UUID; let scope: RemoteDiffScope; let path: String?; let knownRevision: String? }
    private var calls: [Call] = []
    private var observers: [(Int, CheckedContinuation<Call, Never>)] = []
    private var snapshots: [UUID: CheckedContinuation<RemoteReviewSnapshot, Error>] = [:]
    private var diffs: [UUID: CheckedContinuation<RemotePatchSnapshot, Error>] = [:]
    private var texts: [UUID: CheckedContinuation<RemoteTextFile, Error>] = [:]
    private var activeDiffs = 0
    private(set) var maximumActiveDiffs = 0
    var count: Int { calls.count }

    func call(_ index: Int) async -> Call {
        if calls.indices.contains(index) { return calls[index] }
        return await withCheckedContinuation { observers.append((index, $0)) }
    }

    private func record(_ call: Call) {
        calls.append(call)
        let ready = observers.filter { calls.indices.contains($0.0) }
        observers.removeAll { calls.indices.contains($0.0) }
        for (index, observer) in ready { observer.resume(returning: calls[index]) }
    }

    func changes(workspaceID: WorkspaceID, scope: RemoteDiffScope, knownRevision: String?, wait: Bool) async throws -> RemoteReviewSnapshot {
        let id = UUID()
        return try await withCheckedThrowingContinuation {
            snapshots[id] = $0
            record(Call(id: id, scope: scope, path: nil, knownRevision: knownRevision))
        }
    }

    func diff(workspaceID: WorkspaceID, path: String, scope: RemoteDiffScope, knownRevision: String?) async throws -> RemotePatchSnapshot {
        let id = UUID()
        activeDiffs += 1; maximumActiveDiffs = max(maximumActiveDiffs, activeDiffs)
        defer { activeDiffs -= 1 }
        return try await withCheckedThrowingContinuation {
            diffs[id] = $0
            record(Call(id: id, scope: scope, path: path, knownRevision: knownRevision))
        }
    }

    func completeSnapshot(_ id: UUID, _ value: Result<RemoteReviewSnapshot, Error>) { snapshots.removeValue(forKey: id)?.resume(with: value) }
    func completeDiff(_ id: UUID, _ value: Result<RemotePatchSnapshot, Error>) { diffs.removeValue(forKey: id)?.resume(with: value) }
    func files(workspaceID: WorkspaceID) async throws -> [String] { [] }
    func readFile(workspaceID: WorkspaceID, path: String) async throws -> RemoteTextFile {
        let id = UUID()
        return try await withCheckedThrowingContinuation {
            texts[id] = $0
            record(Call(id: id, scope: .branch, path: path, knownRevision: nil))
        }
    }
    func completeText(_ id: UUID, _ value: RemoteTextFile) { texts.removeValue(forKey: id)?.resume(returning: value) }
}
