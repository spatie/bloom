import Foundation
import BloomClient

/// Device connection selection is native. Review revisions, retries and request lifetime are
/// the same store the Mac uses, so new review behaviours reach both clients together.
@MainActor
final class MobileWorkspaceReview {
    let connection: MobileConnection
    let workspace: RemoteWorkspace
    private let origin: String
    private let store: WorkspaceReviewStore
    var changed: (@MainActor () -> Void)? { get { store.changed } set { store.changed = newValue } }
    var changes: [ChangedFile] { store.changes }
    var paths: [String] { store.paths }
    var diffs: [String: FileDiff] { store.diffs }
    var errors: [String: String] { store.errors }
    var error: String? { store.error }
    var isLoading: Bool { store.isLoading || store.isLoadingFiles }
    var hasLoaded: Bool { store.hasLoaded }
    var scope: RemoteDiffScope { store.scope }

    init(connection: MobileConnection, workspace: RemoteWorkspace) {
        self.connection = connection; self.workspace = workspace
        origin = connection.address
        store = WorkspaceReviewStore(workspaceID: workspace.id)
    }

    var service: RemoteWorkspaceService? { connection.address == origin ? connection.service : nil }

    func setScope(_ scope: RemoteDiffScope) async {
        guard scope != store.scope else { return }
        store.setScope(scope)
        await refresh()
    }

    func refresh() async {
        guard let service else { store.reportConnectionFailure("Reconnect to this server to load its files."); return }
        await store.refresh(using: service, refreshFiles: true)
    }

    func loadDiff(path: String) {
        guard let service else { store.reportConnectionFailure("Reconnect to this server to read its diffs."); return }
        store.loadDiff(path: path, using: service)
    }

    func retry(path: String) {
        guard let service else { store.reportConnectionFailure("Reconnect to this server to read its diffs."); return }
        store.retry(path: path, using: service)
    }

    func readFile(path: String) async throws -> RemoteTextFile {
        guard let service else { throw ConnectionFailure("Reconnect to this server to read the file.") }
        return try await store.readFile(path: path, using: service)
    }

    func setVisiblePaths(_ paths: Set<String>) { store.setVisiblePaths(paths) }

    func cancel() { store.cancel() }
}
