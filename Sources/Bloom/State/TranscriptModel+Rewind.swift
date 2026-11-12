import BloomCore
import Foundation

/// Rewinding a Claude chat to before one of the owner's messages, from the Rewind menu on
/// that message. The decisions (which message to resume at, which uuid restores files, what goes
/// back in the composer) are `ClaudeRewind`'s; this is the order the steps run in.
///
/// **The order is the point.** Files first, because restoring them needs the conversation as it
/// was: `--rewind-files` looks the message up in the session being rewound. Then the runner goes,
/// so the next turn starts a new process with the resume point. The resume point is written
/// before the rows are removed, so a crash in between leaves a transcript that still shows them
/// and a conversation that would fork without them on the next send, rather than the other way
/// round, where the agent would remember what the owner can no longer see.
extension TranscriptModel {
    enum RewindScope {
        case conversation
        case conversationAndFiles
    }

    func rewind(toBefore seq: Int, scope: RewindScope) async {
        guard let store = rewindStore else { return }
        guard isIdleForRewind else {
            report("Stop the agent and let queued messages go first, then rewind.")
            return
        }
        do {
            let messages = try await store.messages(sessionID: session.id)
            guard let plan = ClaudeRewind.plan(rewindingTo: seq, in: messages) else { return }
            guard let runner = await claudeRunnerForRewind() else {
                report("Only a Claude chat outside the terminal can be rewound here. In a terminal chat, use /rewind.")
                return
            }

            if scope == .conversationAndFiles {
                guard let point = plan.fileRewindPoint else {
                    report("This message was sent before Bloom kept the id that restoring files needs. Rewind the conversation only, or restore the files with git.")
                    return
                }
                try await runner.rewindFiles(to: point)
            }

            await dropRunnerForRewind()
            // A fork from the message before, or a new conversation when this was the first.
            let agentSessionID = plan.resumeAt == nil ? nil : session.agentSessionID
            try await store.setSetting(ClaudeRewind.settingKey(session.id), plan.resumeAt)
            if plan.resumeAt == nil {
                try await store.update(sessionID: session.id) { $0.agentSessionID = nil }
            }
            try await store.removeMessages(sessionID: session.id, fromSeq: plan.removeFromSeq)

            await reloadAfterRewind(agentSessionID: agentSessionID)
            draft = plan.prompt
            await saveDraft()
        } catch {
            report("The rewind did not finish: \(error.readableMessage)")
        }
    }

    private func report(_ message: String) {
        showRewindAlert(message)
    }
}
