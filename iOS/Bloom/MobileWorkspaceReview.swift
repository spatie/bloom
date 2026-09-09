import Foundation
import BloomClient

/// A window's read-only review cache. Execution, file access and revision ownership stay on the server.
@MainActor
final class MobileWorkspaceReview {
    let connection: MobileConnection
    let workspace: RemoteWorkspace
    private let origin: String
    private(set) var changes: [ChangedFile] = []
    private(set) var paths: [String] = []
    private(set) var diffs: [String: FileDiff] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var scope: RemoteDiffScope = .branch
    private var revision: String?
    private var generation = 0
    private var pending: [String: Task<Void, Never>] = [:]
    var changed: (() -> Void)?

    init(connection: MobileConnection, workspace: RemoteWorkspace) {
        self.connection = connection
        self.workspace = workspace
        origin = connection.address
    }

    var service: RemoteWorkspaceService? { connection.address == origin ? connection.service : nil }

    func setScope(_ scope: RemoteDiffScope) async {
        guard self.scope != scope else { return }
        generation += 1
        self.scope = scope
        revision = nil
        changes = []
        hasLoaded = false
        error = nil
        pending.values.forEach { $0.cancel() }
        pending = [:]
        diffs = [:]
        errors = [:]
        isLoading = false
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        guard let service else { error = "Reconnect to this server to load its files."; changed?(); return }
        isLoading = true
        let generation = generation
        changed?()
        defer { if generation == self.generation { isLoading = false; changed?() } }
        do {
            let snapshot = try await service.changes(workspaceID: workspace.id, scope: scope, knownRevision: revision)
            guard generation == self.generation, !Task.isCancelled else { return }
            if let files = snapshot.files {
                if snapshot.revision != revision {
                    pending.values.forEach { $0.cancel() }
                    pending = [:]
                    diffs = [:]
                    errors = [:]
                }
                changes = files
            }
            revision = snapshot.revision
            error = nil
            hasLoaded = true
            changed?()
            let paths = try await service.files(workspaceID: workspace.id)
            guard generation == self.generation, !Task.isCancelled else { return }
            self.paths = paths
        } catch {
            if generation == self.generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func loadDiff(path: String) {
        guard diffs[path] == nil, pending[path] == nil, errors[path] == nil, pending.count < 2 else { return }
        guard let service else { errors[path] = "Reconnect to this server to read this diff."; changed?(); return }
        let generation = generation
        let scope = scope
        let workspaceID = workspace.id
        pending[path] = Task { [weak self] in
            do {
                let result = try await service.diff(workspaceID: workspaceID, path: path, scope: scope)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                guard let patch = result.patch else { throw ConnectionFailure("The server did not return this file's diff. Refresh to try again.") }
                let files = DiffParser.parse(patch)
                self.diffs[path] = files.first ?? FileDiff(oldPath: path, newPath: path)
                self.pending[path] = nil
                self.changed?()
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.pending[path] = nil
                self.errors[path] = error.localizedDescription
                self.changed?()
            }
        }
    }

    func retry(path: String) { errors[path] = nil; loadDiff(path: path) }

    func cancel() {
        generation += 1
        pending.values.forEach { $0.cancel() }
        pending = [:]
        isLoading = false
    }
}
