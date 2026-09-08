import Foundation
import Observation
import BloomCore

/// Each open Ask tab owns a live transcript. Selection never tears down a running conversation.
@MainActor
@Observable
final class AskModel {
    private(set) var sessions: [Session] = []
    private(set) var selectedID: SessionID?
    private(set) var transcripts: [SessionID: TranscriptModel] = [:]
    private(set) var trouble: String?
    var closingID: SessionID?
    private unowned let app: AppModel
    private var isChanging = false
    private var hasOpened = false
    private var settledModes: Set<SessionID> = []
    private var loading: Set<SessionID> = []

    var transcript: TranscriptModel? { selectedID.flatMap { transcripts[$0] } }
    var session: Session? { transcript?.session ?? sessions.first { $0.id == selectedID } }

    init(app: AppModel) { self.app = app }

    func open() async {
        guard !isChanging, let store = app.store else { return }
        isChanging = true
        defer { isChanging = false }
        if hasOpened {
            if transcript == nil, let selectedID { await select(selectedID) }
            return
        }
        do {
            sessions = try await store.sessionsWithoutWorkspace()
            if sessions.isEmpty {
                let directory = try await newDirectory()
                sessions = [try await store.createAskConversation(directory: directory)]
            }
            let saved = try await store.setting(AskTabs.selectionKey)
            hasOpened = true
            if let id = AskTabs.selection(saved: saved, sessions: sessions) { await select(id) }
        } catch { trouble = error.readableMessage }
    }

    func select(_ id: SessionID) async {
        guard let store = app.store, var chat = sessions.first(where: { $0.id == id }) else { return }
        selectedID = id
        trouble = nil
        do {
            try await store.setSetting(AskTabs.selectionKey, id.rawValue)
            if transcripts[id] != nil || loading.contains(id) { return }
            loading.insert(id)
            defer { loading.remove(id) }
            // Old conversations predate directory preferences and retain their original cwd.
            let saved = try await store.setting(AskTabs.directoryKey(id))
            guard let directory = AskTabs.prepareDirectory(saved ?? "", databasePath: store.path) else {
                throw AskDirectoryError.unavailable(saved ?? AskConversation.directory(besideDatabaseAt: store.path))
            }
            if let mode = AskConversation.modeOnOpening(
                stored: chat.permissionMode, isFirstOpenSinceLaunch: !settledModes.contains(id)
            ) {
                try await store.updateSessionPreferences(id: id, permissionMode: mode)
                chat.permissionMode = mode
            }
            settledModes.insert(id)
            let model = TranscriptModel(askSession: chat, directory: directory, app: app)
            transcripts[id] = model
            await model.load()
        } catch {
            if selectedID == id { trouble = error.readableMessage }
        }
    }

    func newConversation() async {
        guard !isChanging, let store = app.store else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            if !hasOpened { sessions = try await store.sessionsWithoutWorkspace() }
            let directory = try await newDirectory()
            let made = try await store.createAskConversation(directory: directory)
            sessions.append(made)
            hasOpened = true
            await select(made.id)
        } catch { report(error, title: "Could not start a new conversation") }
    }

    /// Explicit fresh-start composer actions replace only their tab, carrying its directory.
    func startFresh(controls: ComposerControls? = nil, draft: String = "") async {
        guard !isChanging, let store = app.store, let current = session else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            let carried: ComposerControls
            if let controls {
                carried = controls
            } else {
                let fast = (try await store.setting(ComposerControls.fastModeKey(sessionID: current.id))) == "1"
                let style = (try await store.setting(ComposerControls.outputStyleKey(sessionID: current.id))) ?? ""
                let window = CodexContextWindow.normalised(
                    try await store.setting(ComposerControls.contextWindowKey(sessionID: current.id))
                )
                carried = ComposerControls(session: current, isFastMode: fast, outputStyle: style,
                                           codexContextWindow: window)
            }
            let made = try await store.replaceAskConversation(id: current.id, controls: carried, draft: draft)
            transcripts.removeValue(forKey: current.id)?.teardown()
            app.bridge?.retire(sessionID: current.id)
            if let index = sessions.firstIndex(where: { $0.id == current.id }) { sessions[index] = made }
            settledModes.insert(made.id)
            await select(made.id)
        } catch { report(error, title: "Could not start a new conversation") }
    }

    func requestClose(_ id: SessionID) {
        if isRunning(id) { closingID = id } else { Task { await close(id) } }
    }

    func close(_ id: SessionID) async {
        guard !isChanging, sessions.count > 1, let store = app.store else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            let next = try await store.closeAskConversation(id: id, selected: selectedID)
            transcripts.removeValue(forKey: id)?.teardown()
            app.bridge?.retire(sessionID: id)
            sessions.removeAll { $0.id == id }
            if let next { await select(next) }
        } catch { report(error, title: "Could not close the conversation") }
    }

    func rename(_ id: SessionID, title: String) async {
        guard let store = app.store else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try await store.update(sessionID: id) { $0.title = title }
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].title = title }
            transcripts[id]?.session.title = title
        } catch { report(error, title: "Could not rename the conversation") }
    }

    func title(for chat: Session) -> String { transcripts[chat.id]?.session.title ?? chat.title }

    func isRunning(_ id: SessionID) -> Bool {
        transcripts[id]?.isRunning == true || transcripts[id]?.subagents.isWorking == true
    }

    var isRunning: Bool { transcripts.keys.contains { isRunning($0) } }
    var isAwaitingPermission: Bool { transcripts.values.contains { $0.isAwaitingPermission } }

    func stopEverything() { for model in transcripts.values { model.terminateNow() } }
    func shutdown() async { for model in transcripts.values { await model.shutdown() } }

    private func newDirectory() async throws -> String {
        guard let store = app.store else { throw AskDirectoryError.unavailable("") }
        let preferences = await DirectoryPreferences.load(from: store)
        guard let path = AskTabs.prepareDirectory(preferences.ask, databasePath: store.path) else {
            throw AskDirectoryError.unavailable(preferences.ask)
        }
        return path
    }

    private func report(_ error: Error, title: String) {
        app.alert = BloomAlert(title: title, message: error.readableMessage)
    }
}

private enum AskDirectoryError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path): "The working directory could not be opened: \(path)"
        }
    }
}
