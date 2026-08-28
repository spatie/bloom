import Foundation
import Observation
import BloomCore

/// The state behind Ask Bloom: one conversation, above every project.
///
/// It is `WorkspaceModel` with everything a worktree brings taken out. There is no diff, no
/// terminal, no pull request, no setup script and no tab strip, because none of those is about a
/// conversation. What is left is a session row, the transcript over it, and the directory the
/// agent runs in.
///
/// **One chat rather than a list.** The design is one conversation that sits above every project,
/// and a strip of tabs here would be a second answer to "which Ask Bloom am I in" for a room with
/// one chair in it. Starting a new one archives the old, which is what `Session.archivedAt`
/// already means and what leaves the transcript readable rather than deleted.
@MainActor
@Observable
final class AskModel {
    /// The chat, once it has been read back or made. Nil for the moment between the pane opening
    /// and the store answering, which is the only time this pane draws nothing.
    private(set) var session: Session?
    private(set) var transcript: TranscriptModel?
    /// Set when the working directory could not be made, which is the one failure that stops this
    /// pane rather than degrading it. See `directory`.
    private(set) var trouble: String?

    private unowned let app: AppModel
    /// Whether `open()` is already running, so the pane's `.task` and a reselection of the row do
    /// not both create a chat. The store is an actor, so two callers really can both read "no
    /// session" before either writes one.
    private var isOpening = false
    /// Whether the permission mode has been settled since Bloom started.
    ///
    /// This model is built once and kept for the life of the window, so its first `open()` is the
    /// launch boundary. See `AskConversation.modeOnOpening` for why there has to be one.
    private var hasSettledMode = false

    init(app: AppModel) {
        self.app = app
    }

    /// The empty directory the agent runs in, made once.
    ///
    /// Read the argument on `AskConversation.directory`: this is a permission decision, and it is
    /// the second of two. A chat started in the owner's home directory would treat every file in
    /// it as inside the working directory, which is the one place any permission mode stops asking
    /// about.
    private var directory: String? {
        guard let store = app.store else { return nil }
        return AskConversation.prepareDirectory(besideDatabaseAt: store.path)
    }

    /// Reads the chat back, or makes it, and builds its transcript. Safe to call again: the second
    /// call finds the session and returns.
    func open() async {
        guard !isOpening, let store = app.store else { return }
        isOpening = true
        defer { isOpening = false }

        guard let directory else {
            trouble = "Bloom could not make the folder this conversation runs in, "
                + "inside its own Application Support directory."
            return
        }
        trouble = nil

        // Oldest first, and the first is the one. More than one can only exist if somebody made a
        // second by hand in the database; taking the oldest means the chat the owner has been
        // using stays the chat the owner has been using.
        let existing = (try? await store.sessionsWithoutWorkspace()) ?? []
        var chat: Session
        if let first = existing.first {
            chat = first
        } else if let made = try? await store.upsert(AskConversation.newSession()) {
            chat = made
        } else {
            // The database refused the insert. Nothing is drawn rather than a pane pretending to
            // be a conversation, and the next selection of the row tries again.
            return
        }

        // Back to Ask on the first open of the launch, whatever the owner left it on. The picker
        // still works and still lasts the rest of the launch; what expires is the presence that
        // justified the choice, not the choice. See `AskConversation.modeOnOpening`.
        if let mode = AskConversation.modeOnOpening(
            stored: chat.permissionMode, isFirstOpenSinceLaunch: !hasSettledMode
        ) {
            // The one column, through the method that names it: the runner owns the state, the
            // counters and the agent session id on this row and may have written any of them.
            try? await store.updateSessionPreferences(id: chat.id, permissionMode: mode)
            chat.permissionMode = mode
        }
        hasSettledMode = true

        session = chat
        if transcript?.session.id != chat.id {
            let model = TranscriptModel(askSession: chat, directory: directory, app: app)
            transcript = model
            await model.load()
        }
    }

    /// Puts this conversation away and opens an empty one.
    ///
    /// Archived rather than deleted, which is what the column already means everywhere else: the
    /// old conversation is still in the database, with its cost and its permission history, and
    /// nothing that has been said is thrown away because somebody wanted a clean start.
    func startFresh(controls: ComposerControls? = nil, draft: String = "") async {
        guard let store = app.store, let current = session else { return }

        let carriedControls: ComposerControls
        if let controls {
            carriedControls = controls
        } else {
            let isFastMode = (try? await store.setting(
                ComposerControls.fastModeKey(sessionID: current.id)
            )) == "1"
            let outputStyle = (try? await store.setting(
                ComposerControls.outputStyleKey(sessionID: current.id)
            )) ?? OutputStyle.defaultName
            carriedControls = ComposerControls(
                session: current,
                isFastMode: isFastMode,
                outputStyle: outputStyle
            )
        }

        transcript?.teardown()
        transcript = nil
        session = nil
        // One column. The runner owns the state, the counters and the agent session id on this
        // row and may have written any of them since this copy was read.
        _ = try? await store.update(sessionID: current.id) { $0.archivedAt = Date() }
        app.bridge?.retire(sessionID: current.id)

        var next = AskConversation.newSession()
        next.model = carriedControls.model
        next.effort = carriedControls.effort
        next.agentKind = carriedControls.agentKind
        next.permissionMode = carriedControls.permissionMode
        if let made = try? await store.upsert(next) {
            await carriedControls.store(sessionID: made.id, in: store)
            if !draft.isEmpty {
                try? await store.saveDraft(sessionID: made.id, body: draft)
            }
        }
        await open()
    }

    /// Signals the agent, without waiting. `AppModel.shutdownEverything` calls this on every model
    /// first so the SIGTERM escalations all run at once rather than one after another.
    ///
    /// **This chat has to be in that sweep.** macOS reparents a child process to launchd rather
    /// than killing it, so a conversation left out of the teardown would leave a `claude` running
    /// against Bloom's own Application Support directory for the rest of the day, with nothing on
    /// screen to say so.
    func stopEverything() {
        transcript?.terminateNow()
    }

    func shutdown() async {
        await transcript?.shutdown()
    }

    /// Whether the agent in this chat is mid turn, for the sidebar row's own mark.
    ///
    /// Read off the live transcript rather than out of `Store.sessionActivity`, and that is the
    /// right source rather than a shortcut: that query joins the workspaces table to answer "which
    /// worktrees have an agent in them", and this conversation is in none of them.
    var isRunning: Bool {
        transcript?.isRunning ?? false
    }

    var isAwaitingPermission: Bool {
        transcript?.isAwaitingPermission ?? false
    }
}
