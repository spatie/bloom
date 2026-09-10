import BloomCore
import Foundation

extension WorkspaceModel {
    @discardableResult
    func openSideConversation(from parent: TranscriptModel, question: String = "", fresh: Bool = false) -> Bool {
        guard parent.session.sideConversationParentID == nil, store != nil else { return false }
        let parentID = parent.session.id
        let state = sideConversations[parentID] ?? SideConversationState()
        sideConversations[parentID] = state
        state.isVisible = true
        guard !state.isOpening else { return false }
        state.isOpening = true
        state.error = nil
        if !question.isEmpty { state.pendingQuestion = question }
        state.task = Task { [weak self] in
            defer { state.isOpening = false; state.task = nil }
            guard let self, let store else { return }
            do {
                if fresh, let previous = state.transcript {
                    // A new detour keeps the old one in a tab, including its draft and any live
                    // turn. Starting fresh must not silently throw away an answer still arriving.
                    _ = try await store.keepSideConversation(sessionID: previous.session.id)
                    state.transcript = nil
                }
                try Task.checkCancellation()
                let session = try await store.openSideConversation(
                    parentID: parentID, streamingText: parent.streamingText
                )
                try Task.checkCancellation()
                await reloadSessions()
                let child = transcript(for: session)
                state.transcript = child
                state.snapshot = try await store.sideConversationSnapshot(sessionID: session.id)
                await child.load()
                try Task.checkCancellation()
                if !state.pendingQuestion.isEmpty {
                    let question = state.pendingQuestion
                    state.pendingQuestion = ""
                    await child.submit(question)
                }
                if state.isVisible { child.focusComposer() }
            } catch is CancellationError {
                // Workspace teardown owns this cancellation; there is no new action to report.
            } catch {
                state.error = error.readableMessage
            }
        }
        return true
    }

    func dismissSideConversation(from parent: TranscriptModel) {
        sideConversations[parent.session.id]?.isVisible = false
        parent.focusComposer()
    }

    func keepSideConversation(from parent: TranscriptModel) {
        guard let state = sideConversations[parent.session.id], let child = state.transcript,
              !state.isOpening, let store else { return }
        state.isOpening = true
        state.task = Task { [weak self] in
            defer { state.isOpening = false; state.task = nil }
            guard let self else { return }
            do {
                guard let kept = try await store.keepSideConversation(sessionID: child.session.id) else { return }
                try Task.checkCancellation()
                child.session = kept
                state.isVisible = false
                state.transcript = nil
                await reloadSessions()
                paneStores.tabs.reveal(.chat(kept.id), in: self)
            } catch is CancellationError {
            } catch {
                state.error = error.readableMessage
            }
        }
    }
}
