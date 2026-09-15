import Foundation

public struct ServerReviewSnapshot: Codable, Sendable {
    public var revision: String
    /// Nil means the caller already has this revision.
    public var files: [ChangedFile]?
}

public struct ServerPatchSnapshot: Codable, Sendable {
    public var revision: String
    public var patch: String?
}

/// One bounded cache shared by all clients of a runtime. Concurrent readers share Git work;
/// long-held reads deliver change notifications without repeatedly transferring the file list.
public actor ServerReviewCache {
    struct Snapshot: Sendable {
        var revision: String
        var files: [ChangedFile]
        var base: String
        var watchedGeneration: UInt64
        var built: ContinuousClock.Instant
    }
    struct Key: Hashable {
        var id: WorkspaceID; var path: String; var base: String; var scope: ServerDiffScope
        init(workspace: Workspace, scope: ServerDiffScope) { id = workspace.id; path = workspace.path; base = workspace.baseBranch; self.scope = scope }
    }
    struct PatchKey: Hashable { var key: Key; var path: String; var revision: String }
    public struct Metrics: Sendable {
        public var scans = 0
        public var patchBuilds = 0
        public var patchHits = 0
        public var retainedPatchBytes = 0
    }
    public private(set) var metrics = Metrics()
    private var watches: [String: ServerReviewWatch] = [:]
    private var watchOrder: [String] = []
    private var snapshots: [Key: Snapshot] = [:]
    private var scans: [Key: Task<Snapshot, Error>] = [:]
    private var watchTasks: [String: Task<ServerReviewWatch, Error>] = [:]
    private var patches: [PatchKey: String] = [:]
    private var patchOrder: [PatchKey] = []
    private var patchTasks: [PatchKey: Task<String, Error>] = [:]
    private let workers = ReviewWorkers()
    private var closed = false
    private let patchBudget: Int
    private let backstop: Duration
    private let resolveRoots: @Sendable (Workspace) async throws -> [String]
    private var shutdownTask: Task<Void, Never>?

    public init(backstop: Duration = .seconds(30), patchBudget: Int = 32 * 1_024 * 1_024) {
        self.backstop = backstop
        self.patchBudget = max(0, patchBudget)
        resolveRoots = Self.gitRoots
    }

    init(resolveRoots: @escaping @Sendable (Workspace) async throws -> [String]) {
        backstop = .seconds(30)
        patchBudget = 32 * 1_024 * 1_024
        self.resolveRoots = resolveRoots
    }

    private static func gitRoots(_ workspace: Workspace) async throws -> [String] {
        let output = try await Git.check(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: workspace.path)
        return [workspace.path] + output.stdout.split(separator: "\n").map(String.init)
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw ServerFailure("The review connection closed.") }
    }

    public func snapshot(workspace: Workspace, scope: ServerDiffScope, knownRevision: String? = nil, wait: Bool = false) async throws -> ServerReviewSnapshot {
        let deadline = ContinuousClock.now + .seconds(wait ? 15 : 0)
        while true {
            try Task.checkCancellation()
            guard !closed else { throw ServerFailure("The review connection closed.") }
            let value = try await current(workspace: workspace, scope: scope)
            try requireOpen()
            if value.revision != knownRevision { return ServerReviewSnapshot(revision: value.revision, files: value.files) }
            if ContinuousClock.now >= deadline { return ServerReviewSnapshot(revision: value.revision, files: nil) }
            // Checking an in-memory notification counter does no filesystem or Git work.
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func watcher(for workspace: Workspace) async throws -> ServerReviewWatch {
        if let watch = watches[workspace.path] {
            watchOrder.removeAll { $0 == workspace.path }; watchOrder.append(workspace.path)
            return watch
        }
        let task: Task<ServerReviewWatch, Error>
        var created = false
        if let pending = watchTasks[workspace.path] { task = pending } else {
            created = true
            task = Task { [resolveRoots] in
                try Task.checkCancellation()
                let roots = try await resolveRoots(workspace)
                try Task.checkCancellation()
                return ServerReviewWatch(roots: Array(Set(roots)))
            }
            watchTasks[workspace.path] = task
        }
        defer { if created { watchTasks[workspace.path] = nil } }
        let watch = try await task.value
        do { try requireOpen() } catch { if closed { watch.stop() }; throw error }
        if let existing = watches[workspace.path] { return existing }
        watches[workspace.path] = watch; watchOrder.append(workspace.path)
        while watchOrder.count > 8 {
            let old = watchOrder.removeFirst()
            watches.removeValue(forKey: old)?.stop()
            snapshots = snapshots.filter { $0.key.path != old }
            for key in patchOrder.filter({ $0.key.path == old }) { removePatch(key) }
        }
        return watch
    }

    private func current(workspace: Workspace, scope: ServerDiffScope) async throws -> Snapshot {
        try requireOpen()
        let key = Key(workspace: workspace, scope: scope)
        snapshots = snapshots.filter { $0.key.id != key.id || $0.key.scope != key.scope || $0.key == key }
        let watch = try await watcher(for: workspace)
        try requireOpen()
        let age = watch.isReliable ? backstop : .seconds(2)
        if let held = snapshots[key], held.watchedGeneration == watch.generation, held.built.duration(to: .now) < age { return held }
        if let task = scans[key] {
            let value = try await task.value
            try requireOpen()
            return value
        }
        let generation = watch.generation
        metrics.scans += 1
        let task = Task {
            try Task.checkCancellation()
            let base = scope == .branch ? try await Git.baseline(workspace.baseBranch, in: workspace.path) : try await Git.check(["rev-parse", "HEAD"], in: workspace.path).trimmed
            var files = try await ServerReview.changes(workspace: workspace, scope: scope)
            for index in files.indices { files[index].contentRevision = try Self.fileRevision(files[index], workspace: workspace, base: base) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(files)
            let revision = ServerFileOperations.revision(encoded + Data(base.utf8))
            return Snapshot(revision: revision, files: files, base: base, watchedGeneration: generation, built: .now)
        }
        scans[key] = task
        defer { scans[key] = nil }
        let value = try await task.value
        try requireOpen()
        // An event received while Git was reading is consumed by the next scan, never lost.
        if watch.generation == generation { snapshots[key] = value }
        return value
    }

    static func fileRevision(_ file: ChangedFile, workspace: Workspace, base: String) throws -> String {
        var data = Data((base + "\0" + file.path + "\0" + (file.oldPath ?? "") + "\0" + file.change.rawValue).utf8)
        for path in [file.path, file.oldPath].compactMap({ $0 }) {
            let absolute = URL(fileURLWithPath: workspace.path).appendingPathComponent(path).path
            // lstat metadata includes nanosecond mtime and ctime, so equal-size rewrites and
            // restored mtimes still invalidate the cache. Symlink targets are never followed.
            data.append(ServerReviewFileStamp.read(absolute))
        }
        return ServerFileOperations.revision(data)
    }

    public func patch(workspace: Workspace, path: String, scope: ServerDiffScope, knownRevision: String? = nil) async throws -> ServerPatchSnapshot {
        try ServerReview.validateRelativePath(path)
        let key = Key(workspace: workspace, scope: scope)
        for _ in 0..<3 {
            let value = try await current(workspace: workspace, scope: scope)
            try requireOpen()
            guard let file = value.files.first(where: { $0.path == path }), let revision = file.contentRevision else { throw ServerFailure("This file no longer has changes. Refresh the file list.") }
            if try Self.fileRevision(file, workspace: workspace, base: value.base) != revision { snapshots[key] = nil; continue }
            if knownRevision == revision { return ServerPatchSnapshot(revision: revision, patch: nil) }
            let patchKey = PatchKey(key: key, path: path, revision: revision)
            if let held = patches[patchKey] {
                metrics.patchHits += 1
                patchOrder.removeAll { $0 == patchKey }; patchOrder.append(patchKey)
                return ServerPatchSnapshot(revision: revision, patch: held)
            }
            let task: Task<String, Error>
            if let pending = patchTasks[patchKey] { task = pending } else {
                metrics.patchBuilds += 1
                task = Task { [workers] in
                    try await workers.acquire()
                    do {
                        try Task.checkCancellation()
                        let text = try await ServerReview.patch(workspace: workspace, file: file, base: value.base)
                        await workers.release()
                        return text
                    } catch { await workers.release(); throw error }
                }
                patchTasks[patchKey] = task
            }
            let text: String
            do { text = try await task.value } catch { patchTasks[patchKey] = nil; throw error }
            patchTasks[patchKey] = nil
            try requireOpen()
            guard try Self.fileRevision(file, workspace: workspace, base: value.base) == revision else { snapshots[key] = nil; continue }
            if patches[patchKey] == nil {
                patches[patchKey] = text; patchOrder.append(patchKey); metrics.retainedPatchBytes += text.utf8.count
            }
            while metrics.retainedPatchBytes > patchBudget || patchOrder.count > 128 { removePatch(patchOrder[0]) }
            return ServerPatchSnapshot(revision: revision, patch: text)
        }
        throw ServerFailure("This file is changing. Try opening its diff again.")
    }

    private func removePatch(_ key: PatchKey) {
        metrics.retainedPatchBytes -= patches.removeValue(forKey: key)?.utf8.count ?? 0
        patchOrder.removeAll { $0 == key }
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true
        let watchesInFlight = Array(watchTasks.values)
        let scansInFlight = Array(scans.values)
        let patchesInFlight = Array(patchTasks.values)
        for watch in watches.values { watch.stop() }
        for task in watchesInFlight { task.cancel() }
        for task in scansInFlight { task.cancel() }
        for task in patchesInFlight { task.cancel() }
        watches.removeAll(); watchOrder.removeAll(); snapshots.removeAll(); patches.removeAll(); patchOrder.removeAll()
        metrics.retainedPatchBytes = 0
        // A cancelled Git read can still be unwinding. Keep daemon ownership until every child
        // has finished; callers also recheck closed before publishing a result or a watcher.
        let task = Task {
            for pending in watchesInFlight { if let watch = try? await pending.value { watch.stop() } }
            for pending in scansInFlight { _ = try? await pending.value }
            for pending in patchesInFlight { _ = try? await pending.value }
        }
        shutdownTask = task
        await task.value
    }
}

actor ReviewWorkers {
    private var used = 0
    private let maximum: Int
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(maximum: Int = 4) { self.maximum = max(1, maximum) }
    func acquire() async throws {
        try Task.checkCancellation()
        if used < maximum { used += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }
    func release() {
        if waiting.isEmpty { used -= 1 } else { waiting.removeFirst().1.resume() }
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    var waitingCount: Int { waiting.count }
}
