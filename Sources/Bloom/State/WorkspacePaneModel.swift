import Foundation
import Observation
import BloomCore

/// The existing tab and pane system talks to this interface. Execution stays with its host.
@MainActor
protocol WorkspacePaneModel: WorkspaceFileReview, Observable {
    var browserReviews: [String: BrowserRegionCapture] { get set }
    var sessions: [Session] { get set }
    var activeSessionID: SessionID? { get set }
    var activeSession: Session? { get }
    var activeTranscript: TranscriptModel? { get }
    var hasReadSessions: Bool { get }
    var isRunningSetup: Bool { get }
    var port: Int { get }
    var reviewDestinationID: SessionID? { get set }
    var reviewDestination: Session? { get }
    var localWorkspaceModel: WorkspaceModel? { get }
    var remoteServer: ServerWindowModel? { get }
    func onAppear() async
    func reloadSessions() async
    func makePaneSession(title: String?, controls: ComposerControls?, draft: String) async -> Session?
    func renameSession(_ session: Session, title: String) async
    func closeSession(_ session: Session) async
    func reorderSessions(to ids: [SessionID])
    func isRunning(_ session: Session) -> Bool
    func existingTranscript(for id: SessionID) -> TranscriptModel?
    func prepareTranscript(for id: SessionID)
    @discardableResult func ensurePort() async -> Int
    func browserAddress() async -> String
    func readNote() async throws -> String
    func writeNote(_ body: String) async throws
    func panePosition(pane: String, session: SessionID) -> TranscriptPaneState?
    func rememberPanePosition(_ state: TranscriptPaneState, pane: String, session: SessionID)
}

extension WorkspacePaneModel {
    func browserAddress() async -> String {
        let port = await ensurePort()
        return port > 0 ? "http://localhost:\(port)" : ""
    }

    var browserAddressResolver: (@MainActor (String) async throws -> String)? {
        guard let server = remoteServer else { return nil }
        let identity = paneStores.identity
        return { [weak server] address in
            guard let server, server.paneStores.identity == identity else {
                throw ServerFailure("Reconnect to this browser’s server before opening its preview.")
            }
            let resolved = try await server.forwardedAddress(address)
            guard server.paneStores.identity == identity else {
                throw ServerFailure("The server connection changed while opening this preview.")
            }
            return resolved
        }
    }

    @discardableResult func createSession(title: String? = nil, controls: ComposerControls? = nil, draft: String = "") async -> Session? {
        await makePaneSession(title: title, controls: controls, draft: draft)
    }
}

extension WorkspaceModel: WorkspacePaneModel {
    var localWorkspaceModel: WorkspaceModel? { self }
    var remoteServer: ServerWindowModel? { nil }
    func makePaneSession(title: String?, controls: ComposerControls?, draft: String) async -> Session? {
        await createSession(title: title, controls: controls, draft: draft)
    }
    func renameSession(_ session: Session, title: String) async {
        guard let store else { return }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].title = title }
        try? await store.updateSessionPreferences(id: session.id, title: title)
        await reloadSessions()
    }
    func readNote() async throws -> String { try await store?.note(workspaceID: workspace.id)?.body ?? "" }
    func writeNote(_ body: String) async throws { try await store?.saveNote(workspaceID: workspace.id, body: body) }
}
