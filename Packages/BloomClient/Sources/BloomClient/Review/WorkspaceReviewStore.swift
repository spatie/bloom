import Foundation
import Observation

/// Shared review lifetime for every Apple client. Like the Mac's existing patch cache, a result
/// belongs to one workspace, scope and file revision. Unrelated files changing never invalidate it.
@MainActor
@Observable
public final class WorkspaceReviewStore {
    public let workspaceID: WorkspaceID
    public private(set) var changes: [ChangedFile] = [] {
        didSet { orderedChanges = ChangedFileTree.orderedFiles(from: changes) }
    }
    public private(set) var orderedChanges: [ChangedFile] = []
    public private(set) var paths: [String] = []
    public private(set) var errors: [String: String] = [:]
    public private(set) var isLoading = false
    public private(set) var isLoadingFiles = false
    public private(set) var hasLoaded = false
    public private(set) var hasLoadedFiles = false
    public private(set) var scope: RemoteDiffScope
    public private(set) var revision: String?
    public private(set) var contentGeneration = 0
    public var error: String? { changesError ?? filesError }
    public var diffs: [String: FileDiff] {
        cached.compactMapValues { held in identities[held.identity.file.path] == held.identity ? held.diff : nil }
    }
    public var changed: (@MainActor () -> Void)?

    private struct Identity: Hashable { let file: ChangedFile; let revision: String }
    private struct Cached { var identity: Identity; let revision: String; let diff: FileDiff; let bytes: Int }
    private struct Load { let id: UUID; let identity: Identity; let task: Task<Void, Never> }
    private var identities: [String: Identity] = [:]
    private var cached: [String: Cached] = [:]
    private var cacheOrder: [String] = []
    private var visiblePaths: Set<String> = []
    private let cacheCapacity: Int
    private let cacheByteLimit: Int
    private let limit = ReviewLoadLimit(maximum: 2)
    private var changesError: String?
    private var filesError: String?
    private var generation = 0
    private var suspended = false
    private var snapshotTask: (UUID, Task<Void, Never>)?
    private var listingTask: (UUID, Task<Void, Never>)?
    private var pending: [String: Load] = [:]
    private var textTasks: [String: (UUID, Task<RemoteTextFile, Error>)] = [:]

    public init(workspaceID: WorkspaceID, scope: RemoteDiffScope = .branch, cacheCapacity: Int = 12, cacheByteLimit: Int = 16 * 1_024 * 1_024) {
        self.workspaceID = workspaceID; self.scope = scope
        self.cacheCapacity = max(1, cacheCapacity); self.cacheByteLimit = max(1, cacheByteLimit)
    }

    public func setScope(_ value: RemoteDiffScope) {
        guard scope != value else { return }
        cancelLoads()
        scope = value; revision = nil; changes = []; hasLoaded = false
        identities = [:]; cached = [:]; cacheOrder = []; visiblePaths = []; errors = [:]; changesError = nil
        contentGeneration += 1
        changed?()
    }

    /// Calls that arrive during the same read await that read. File listings remain independent,
    /// so opening All files during a long-held changes request does not wait for that poll.
    public func refresh(using source: any WorkspaceReviewReading, refreshFiles: Bool = false, wait: Bool = false) async {
        suspended = false
        let refreshGeneration = generation
        let task: Task<Void, Never>
        if let pending = snapshotTask { task = pending.1 } else {
            let id = UUID(), observed = generation
            let scope = scope, revision = revision, shouldWait = wait && hasLoaded
            isLoading = true
            task = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.snapshotTask?.0 == id { self.snapshotTask = nil; self.isLoading = false; self.changed?() }
                }
                do {
                    let snapshot = try await source.changes(workspaceID: self.workspaceID, scope: scope, knownRevision: revision, wait: shouldWait)
                    guard observed == self.generation, !Task.isCancelled else { return }
                    try self.accept(snapshot)
                    self.changesError = nil
                } catch {
                    if observed == self.generation, !Task.isCancelled { self.changesError = error.localizedDescription }
                }
            }
            snapshotTask = (id, task)
            changed?()
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if refreshFiles, refreshGeneration == generation, !Task.isCancelled { await refreshPaths(using: source) }
    }

    public func refreshPaths(using source: any WorkspaceReviewReading) async {
        if let task = listingTask?.1 { await task.value; return }
        let id = UUID(), observed = generation
        isLoadingFiles = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.listingTask?.0 == id { self.listingTask = nil; self.isLoadingFiles = false; self.changed?() }
            }
            do {
                let paths = try await source.files(workspaceID: self.workspaceID)
                guard observed == self.generation, !Task.isCancelled else { return }
                self.paths = paths; self.hasLoadedFiles = true; self.filesError = nil
            } catch {
                if observed == self.generation, !Task.isCancelled { self.filesError = error.localizedDescription }
            }
        }
        listingTask = (id, task)
        changed?()
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func accept(_ snapshot: RemoteReviewSnapshot) throws {
        guard let files = snapshot.files else {
            guard hasLoaded, snapshot.revision == revision else {
                throw ConnectionFailure("The server omitted a changed file list this app does not have. Refresh to try again.")
            }
            return
        }
        let fresh = Dictionary(files.map { ($0.path, Identity(file: $0, revision: $0.contentRevision ?? snapshot.revision)) }, uniquingKeysWith: { _, last in last })
        for path in Array(pending.keys) where pending[path]?.identity != fresh[path] {
            pending.removeValue(forKey: path)?.task.cancel()
        }
        errors = errors.filter { identities[$0.key] == fresh[$0.key] && fresh[$0.key] != nil }
        cached = cached.filter { fresh[$0.key] != nil }
        cacheOrder.removeAll { cached[$0] == nil }
        if snapshot.revision != revision { contentGeneration += 1 }
        identities = fresh; changes = files; revision = snapshot.revision; hasLoaded = true
    }

    /// Returning a task lets a caller await readiness without owning the work. Duplicate requests
    /// share the same task, and cancelled old generations retain worker slots until they finish.
    @discardableResult
    public func loadDiff(path: String, using source: any WorkspaceReviewReading) -> Task<Void, Never>? {
        guard !suspended, let identity = identities[path] else { return nil }
        if cached[path]?.identity == identity { touch(path); return nil }
        if let pending = pending[path] { return pending.task }
        guard errors[path] == nil else { return nil }
        let id = UUID(), observed = generation, scope = scope, workspaceID = workspaceID
        let previous = cached[path]
        let limit = limit
        let task = Task { [weak self] in
            defer {
                if let self, self.pending[path]?.id == id { self.pending[path] = nil; self.changed?() }
            }
            do {
                try await limit.acquire(id)
                defer { limit.release(id) }
                try Task.checkCancellation()
                let response = try await source.diff(workspaceID: workspaceID, path: path, scope: scope, knownRevision: previous?.revision)
                guard let self, observed == self.generation, self.pending[path]?.id == id,
                      self.identities[path] == identity, !Task.isCancelled else { return }
                let held: Cached
                if let patch = response.patch {
                    let diff = DiffParser.parse(patch).first ?? FileDiff(oldPath: path, newPath: path)
                    held = Cached(identity: identity, revision: response.revision, diff: diff, bytes: patch.utf8.count)
                } else if var existing = previous, existing.revision == response.revision {
                    existing.identity = identity; held = existing
                } else { throw ConnectionFailure("The server omitted a diff this app does not have. Retry this file.") }
                self.cached[path] = held; self.touch(path); self.trimCache()
                self.pending[path] = nil; self.changed?()
            } catch {
                guard let self, observed == self.generation, self.pending[path]?.id == id else { return }
                self.pending[path] = nil
                if !Task.isCancelled { self.errors[path] = error.localizedDescription }
                self.changed?()
            }
        }
        pending[path] = Load(id: id, identity: identity, task: task)
        return task
    }

    @discardableResult
    public func retry(path: String, using source: any WorkspaceReviewReading) -> Task<Void, Never>? {
        errors[path] = nil
        return loadDiff(path: path, using: source)
    }

    public func readFile(path: String, using source: any WorkspaceReviewReading) async throws -> RemoteTextFile {
        if let task = textTasks[path]?.1 {
            let observed = generation
            let file = try await task.value
            guard observed == generation, !Task.isCancelled else { throw CancellationError() }
            return file
        }
        let id = UUID(), observed = generation, workspaceID = workspaceID
        let task = Task { try await source.readFile(workspaceID: workspaceID, path: path) }
        textTasks[path] = (id, task)
        defer { if textTasks[path]?.0 == id { textTasks[path] = nil } }
        let file = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard observed == generation, !Task.isCancelled else { throw CancellationError() }
        return file
    }

    public func setVisiblePaths(_ paths: Set<String>) {
        visiblePaths = paths
        trimCache()
    }

    public func reportConnectionFailure(_ message: String) {
        guard changesError != message else { return }
        changesError = message
        changed?()
    }

    public func cancel() {
        cancelLoads()
        changed?()
    }

    private func cancelLoads() {
        suspended = true
        generation += 1
        snapshotTask?.1.cancel(); snapshotTask = nil
        listingTask?.1.cancel(); listingTask = nil
        for load in pending.values { load.task.cancel() }; pending = [:]
        for load in textTasks.values { load.1.cancel() }; textTasks = [:]
        isLoading = false; isLoadingFiles = false
    }

    private func touch(_ path: String) { cacheOrder.removeAll { $0 == path }; cacheOrder.append(path) }

    private func trimCache() {
        // Retain one oversized file so a visible section cannot endlessly evict and reload itself.
        while cacheOrder.count > 1,
              cached.count > cacheCapacity || cached.values.reduce(0, { $0 + $1.bytes }) > cacheByteLimit {
            guard let index = cacheOrder.firstIndex(where: { !visiblePaths.contains($0) }) else { return }
            let oldest = cacheOrder.remove(at: index); cached[oldest] = nil
        }
    }
}
