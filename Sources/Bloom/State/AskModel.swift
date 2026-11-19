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
    private(set) var paneStates: [SessionID: ConversationPaneState] = [:]
    private(set) var trouble: String?
    private(set) var archiveRevision = 0
    private(set) var pinnedConversations: Set<SessionID> = []
    private(set) var unreadConversations: Set<SessionID> = []
    private(set) var conversationColours: [SessionID: String] = [:]
    var closingID: SessionID?
    private unowned let app: AppModel
    private var isChanging = false
    private var hasOpened = false
    private var openingTask: Task<Void, Never>?
    private var loading: Set<SessionID> = []
    private var sessionsWithHistory: Set<SessionID> = []

    var transcript: TranscriptModel? { selectedID.flatMap { transcripts[$0] } }
    func transcript(for id: SessionID) -> TranscriptModel? { transcripts[id] }
    func paneState(for id: SessionID) -> ConversationPaneState? { paneStates[id] }
    var session: Session? { transcript?.session ?? sessions.first { $0.id == selectedID } }

    init(app: AppModel) { self.app = app }

    func open() async {
        if let openingTask {
            await openingTask.value
            return
        }
        if hasOpened {
            if transcript == nil, let selectedID { await select(selectedID) }
            return
        }
        guard !isChanging, let store = app.store else { return }
        isChanging = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadInitial(from: store)
        }
        openingTask = task
        await task.value
        openingTask = nil
        isChanging = false
    }

    private func loadInitial(from store: Store) async {
        do {
            sessions = try await store.sessionsWithoutWorkspace()
            sessionsWithHistory = try await store.projectFreeSessionsWithHistory()
            unreadConversations = try await store.unreadProjectFreeConversationIDs()
            await loadMarks(from: store)
            let saved = try await store.setting(AskTabs.selectionKey)
            hasOpened = true
            if let id = AskTabs.selection(saved: saved, sessions: sessions) { await select(id) }
        } catch { trouble = error.readableMessage }
    }

    func select(_ id: SessionID) async {
        guard let store = app.store, let chat = sessions.first(where: { $0.id == id }) else { return }
        selectedID = id
        // `open()` restores a saved selection even when the window is showing a workspace.
        // Only a conversation actually on screen has been read.
        if app.selection == .conversation(id) { unreadConversations.remove(id) }
        trouble = nil
        do {
            try await store.setSetting(AskTabs.selectionKey, id.rawValue)
            if transcripts[id] != nil, paneStates[id] != nil { return }
            if loading.contains(id) { return }
            loading.insert(id)
            defer { loading.remove(id) }
            // Old conversations predate directory preferences and retain their original cwd.
            let saved = try await store.setting(AskTabs.directoryKey(id))
            guard let directory = AskTabs.prepareDirectory(saved ?? "", databasePath: store.path) else {
                throw AskDirectoryError.unavailable(saved ?? AskConversation.directory(besideDatabaseAt: store.path))
            }
            if paneStates[id] == nil {
                paneStates[id] = ConversationPaneState(sessionID: id, directory: directory)
            }
            if transcripts[id] != nil { return }
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
            // A blank conversation is already a new one. Making another would only pile up rows
            // the rail does not show.
            if let blank = sessions.first(where: isBlank) {
                hasOpened = true
                await select(blank.id)
                return
            }
            let directory = try await newDirectory()
            let made = try await store.createAskConversation(directory: directory)
            sessions.append(made)
            hasOpened = true
            await select(made.id)
        } catch { report(error, title: "Could not start a new conversation") }
    }

    /// A persistent conversation started from the New Workspace sheet.
    /// Its directory is beside this copy's database, independent of project settings and Git.
    @discardableResult
    func startWorkspaceConversation(
        prompt: String, controls: ComposerControls, staged: StagedAttachments?
    ) async -> Session? {
        await open()
        guard !isChanging, let store = app.store else { return nil }
        let stagedPaths = staged?.attachments.map(\.path) ?? []
        let spoken = WorkspaceStartAttachments.spoken(prompt, staged: stagedPaths)
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        isChanging = true
        defer { isChanging = false }
        do {
            let id = SessionID.new()
            guard let directory = AskConversation.prepareWorkspaceDirectory(
                besideDatabaseAt: store.path, id: id
            ) else {
                throw AskDirectoryError.unavailable(
                    AskConversation.workspaceDirectory(besideDatabaseAt: store.path, id: id)
                )
            }
            let made = try await store.createAskConversation(
                directory: directory, controls: controls,
                title: Git.title(from: spoken, maxLength: 40), id: id
            )
            sessions.append(made)
            hasOpened = true
            await select(made.id)
            let arrived: Set<String> = staged.map {
                WorkspaceStartAttachments.adopt(stagedPaths, from: $0.directory, into: directory)
            } ?? []
            let opening = WorkspaceStartAttachments.opening(
                prompt, staged: stagedPaths, arrived: arrived, isChatWorkspace: true
            )
            app.selection = .conversation(made.id)
            guard let opening, await transcripts[made.id]?.submit(opening) == true else {
                throw AskDirectoryError.couldNotSend
            }
            return made
        } catch {
            report(error, title: "Could not create the conversation")
            return nil
        }
    }

    func archivedConversations() async -> [Session] {
        guard let store = app.store else { return [] }
        let archived = (try? await store.sessionsWithoutWorkspace(includeArchived: true)) ?? []
        let used = (try? await store.projectFreeSessionsWithHistory(includeArchived: true)) ?? []
        return archived.filter { used.contains($0.id) || !AskConversation.isBlank($0) }
    }

    func restore(_ id: SessionID) async {
        guard let store = app.store else { return }
        do {
            guard let restored = try await store.restoreConversation(id: id) else { return }
            sessions.append(restored)
            sessionsWithHistory.insert(id)
            archiveRevision &+= 1
            await select(id)
            app.selection = .conversation(id)
        } catch { report(error, title: "Could not restore the conversation") }
    }

    func deleteArchived(_ id: SessionID) async {
        guard let store = app.store else { return }
        do {
            let directory = try await store.setting(AskTabs.directoryKey(id))
            guard try await store.deleteArchivedConversation(id: id) else { return }
            paneStates.removeValue(forKey: id)?.discard()
            ConversationPaneState.discardStoredLayout(for: id)
            pinnedConversations.remove(id)
            conversationColours[id] = nil
            archiveRevision &+= 1
            if app.selection == .archivedConversation(id) { app.selection = .home }
            let owned = AskConversation.workspaceDirectory(besideDatabaseAt: store.path, id: id)
            if directory == owned {
                // A fresh conversation can inherit the previous one's directory. Keep its
                // files while any other conversation still points there.
                if let directories = try? await store.settings(prefix: "ask.directory."),
                   !directories.contains(where: { $0.value == owned }) {
                    try? await Task.detached(priority: .utility) {
                        try FileManager.default.removeItem(atPath: owned)
                    }.value
                }
            }
        } catch { report(error, title: "Could not delete the conversation") }
    }

    /// Explicit fresh-start composer actions replace only their tab, carrying its directory.
    func startFresh(controls: ComposerControls? = nil, draft: String = "") async {
        guard !isChanging, let store = app.store, let current = session else { return }
        isChanging = true
        defer { isChanging = false }
        var preparedDirectory: String?
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
                let codexFastMode = CodexSpeed.override(stored: try await store.setting(
                    CodexSpeed.key(sessionID: current.id)
                ))
                let advisor = ChatAdvisor(stored: try await store.setting(ChatAdvisor.key(sessionID: current.id)))
                carried = ComposerControls(session: current, isFastMode: fast, outputStyle: style,
                                           codexContextWindow: window, codexFastMode: codexFastMode,
                                           advisor: advisor)
            }
            let nextID = SessionID.new()
            let currentDirectory = try await store.setting(AskTabs.directoryKey(current.id))
            let owned = AskConversation.workspaceDirectory(
                besideDatabaseAt: store.path, id: current.id
            )
            if currentDirectory == owned {
                guard let directory = AskConversation.prepareWorkspaceDirectory(
                    besideDatabaseAt: store.path, id: nextID
                ) else { throw AskDirectoryError.unavailable(owned) }
                preparedDirectory = directory
            }
            let made = try await store.replaceAskConversation(
                id: current.id, controls: carried, draft: draft,
                nextID: nextID, replacementDirectory: preparedDirectory
            )
            preparedDirectory = nil
            transcripts.removeValue(forKey: current.id)?.teardown()
            paneStates.removeValue(forKey: current.id)?.discard()
            app.bridge?.retire(sessionID: current.id)
            unreadConversations.remove(current.id)
            if let index = sessions.firstIndex(where: { $0.id == current.id }) { sessions[index] = made }
            await select(made.id)
        } catch {
            if let preparedDirectory { try? FileManager.default.removeItem(atPath: preparedDirectory) }
            report(error, title: "Could not start a new conversation")
        }
    }

    func requestClose(_ id: SessionID) {
        if isRunning(id) { closingID = id } else { Task { await close(id) } }
    }

    /// Closing the last conversation archives it and leaves a blank one in its place, rather than
    /// refusing. The owner wanted to be able to close it, and a pane with no conversation at all
    /// has no composer to type into: the blank one is what shows the empty state, its suggestions
    /// and a real composer, with the model and settings the closed one had.
    func close(_ id: SessionID) async {
        if sessions.count == 1, let only = sessions.first, only.id == id {
            // Already the blank one the close would leave behind.
            if isBlank(only) { return }
            if selectedID != id { await select(id) }
            await startFresh()
            archiveRevision &+= 1
            if app.selection == .conversation(id) { app.selection = .home }
            return
        }
        guard !isChanging, sessions.count > 1, let store = app.store else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            let next = try await store.closeAskConversation(id: id, selected: selectedID)
            transcripts.removeValue(forKey: id)?.teardown()
            paneStates.removeValue(forKey: id)?.suspend()
            app.bridge?.retire(sessionID: id)
            sessions.removeAll { $0.id == id }
            unreadConversations.remove(id)
            archiveRevision &+= 1
            if let next { await select(next) }
            if app.selection == .conversation(id) { app.selection = .home }
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

    /// The conversations the rail lists: everything but the blank ones. See `AskConversation.isBlank`.
    var listedSessions: [Session] { sessions.filter { !isBlank($0) } }

    var workspaceConversations: [Session] {
        ConversationListing.ordered(listedSessions, pinned: pinnedConversations)
    }

    func togglePin(_ id: SessionID) async {
        guard let store = app.store else { return }
        let isPinned = pinnedConversations.contains(id)
        do {
            try await store.setSetting(ConversationListing.pinnedKey(id), isPinned ? nil : "1")
            if isPinned {
                pinnedConversations.remove(id)
            } else {
                pinnedConversations.insert(id)
            }
        } catch { report(error, title: "Could not change the pin") }
    }

    func setColour(_ colour: String?, for id: SessionID) async {
        guard let store = app.store else { return }
        do {
            try await store.setSetting(ConversationListing.colourKey(id), colour)
            conversationColours[id] = colour
        } catch { report(error, title: "Could not change the colour") }
    }

    func reorderConversations(from offsets: IndexSet, to destination: Int) async {
        guard let store = app.store else { return }
        let before = workspaceConversations
        guard let after = ConversationListing.reordered(
            before, pinned: pinnedConversations, from: offsets, to: destination
        ) else {
            app.notice = BloomNotice(message: "Pinned conversations stay at the top.")
            return
        }
        let storageOrder = after.reversed().map(\.id)
        do {
            try await store.reorderSessions(ids: storageOrder)
            for (order, id) in storageOrder.enumerated() {
                if let index = sessions.firstIndex(where: { $0.id == id }) {
                    sessions[index].sortOrder = order
                }
            }
        } catch { report(error, title: "Could not reorder conversations") }
    }

    private func loadMarks(from store: Store) async {
        let pins = (try? await store.settings(prefix: "conversation.pinned.")) ?? []
        pinnedConversations = Set(pins.filter { $0.value == "1" }.map {
            SessionID(String($0.key.dropFirst("conversation.pinned.".count)))
        })
        let colours = (try? await store.settings(prefix: "conversation.colour.")) ?? []
        conversationColours = Dictionary(uniqueKeysWithValues: colours.map {
            (SessionID(String($0.key.dropFirst("conversation.colour.".count))), $0.value)
        })
    }

    /// Blank by its row, unless its transcript already has something in it, which covers the
    /// moment between a message going out and the title it earns being written.
    func isBlank(_ chat: Session) -> Bool {
        if sessionsWithHistory.contains(chat.id) { return false }
        if transcripts[chat.id]?.hasNothingToShow == false { return false }
        return AskConversation.isBlank(transcripts[chat.id]?.session ?? chat)
    }

    /// Names a conversation after its first message. See `AskConversation.automaticTitle`.
    func nameFromFirstMessage(_ id: SessionID, prompt: String) async {
        let current = transcripts[id]?.session.title ?? sessions.first { $0.id == id }?.title ?? ""
        guard let title = AskConversation.automaticTitle(current: current, prompt: prompt) else { return }
        await rename(id, title: title)
    }

    func title(for chat: Session) -> String { transcripts[chat.id]?.session.title ?? chat.title }

    func isRunning(_ id: SessionID) -> Bool {
        transcripts[id]?.isRunning == true || transcripts[id]?.subagents.isWorking == true
    }

    /// The mark one conversation's row wears in the sidebar.
    func status(for id: SessionID) -> WorkspaceStatus {
        ConversationListing.status(
            isRunning: isRunning(id),
            isAwaitingPermission: transcripts[id]?.isAwaitingPermission == true,
            isUnread: unreadConversations.contains(id)
        )
    }

    func noteTurnFinished(_ id: SessionID, wasViewed: Bool) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if wasViewed {
            unreadConversations.remove(id)
        } else {
            unreadConversations.insert(id)
        }
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
    case couldNotSend

    var errorDescription: String? {
        switch self {
        case .unavailable(let path): "The working directory could not be opened: \(path)"
        case .couldNotSend: "The conversation was saved, but its first message could not be sent."
        }
    }
}
