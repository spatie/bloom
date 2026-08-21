import SwiftUI
import AppKit
import BloomCore

/// The prompt box at the bottom of the centre column.
///
/// The surface itself is `ComposerPrompt`, which the create sheet uses too. What is left here is
/// everything that is true of a conversation and of nothing else: the draft belongs to a
/// transcript and is saved back to it, the divider above the box, the unread pill, the footer's
/// values coming off a `Session` row, and the first-open defaults.
struct ComposerView: View {
    @Bindable var transcript: TranscriptModel
    /// Optional so the composer can be dropped anywhere a transcript exists. When it is passed,
    /// the session list is kept in step with edits made here.
    var model: WorkspaceModel?
    /// The transcript owns the scroll position, so it decides whether the pill is useful. False
    /// until it says otherwise, because every arrival lands on the live end and a pill offering to
    /// take you where you already are is the state this used to be stuck in. See `ChatPaneView`.
    var isScrolledUp: Bool = false
    /// How tall the region the transcript and the composer share is, so a drag can be stopped
    /// before the transcript is squeezed out of it. Zero reads as "not laid out yet, no cap".
    var availableHeight: CGFloat = 0

    @Environment(AppModel.self) private var app

    /// What the transcript keeps whatever the divider is dragged to. Three or four rows: enough
    /// that the conversation is still readable, rather than a strip above a wall of prompt.
    private static let minTranscriptHeight: CGFloat = 120

    /// The height the user dragged the editor to, or zero for automatic. App-wide rather than per
    /// session on purpose: it is a preference about how you like to write, not a property of one
    /// conversation, and a box that changed height as you switched tabs would read as a bug.
    @AppStorage("composer.editorHeight") private var manualHeight = 0.0

    /// What the wrapped text occupies, already clamped by `ComposerTextEditor` to its line window.
    @State private var contentHeight = ComposerTextEditor.lineHeight
    /// Everything in the composer that is not the editor: the divider, the footer, the box and the
    /// padding. Measured rather than assumed, because the footer's height comes from its controls.
    @State private var chromeHeight: CGFloat = 0
    /// The height the drag started from, and the marker for "a drag is under way".
    @State private var resizeOrigin: CGFloat?
    /// Where the drag has got to so far. Held here rather than written straight to storage, so one
    /// gesture does not rewrite a preference sixty times a second.
    @State private var liveHeight: CGFloat?

    @State private var caret = 0
    @State private var isFocused = false
    @State private var isFastMode = false
    /// The style name this session is on, mirrored out of the store the way fast mode is. Neither
    /// has a column on `Session`, so neither can be read off the row the footer is drawn from.
    @State private var outputStyle = OutputStyle.defaultName
    @State private var draftSaveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ComposerResizeHandle(
                onDrag: resize(by:),
                onDragEnd: endResize,
                onReset: resetHeight
            )

            composer
        }
        .background(Palette.surface)
        // The chrome is whatever is left once the editor's share is taken off, so this settles on
        // the first pass and only moves again when the footer's controls change size.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { total in
            chromeHeight = total - editorHeight
        }
    }

    private var composer: some View {
        ComposerPrompt(
            text: $transcript.draft,
            caret: $caret,
            isFocused: $isFocused,
            mentionRoot: transcript.workspace.path,
            attachmentRoot: transcript.workspace.path,
            attachmentKey: transcript.session.id,
            editorHeight: editorHeight,
            onContentHeightChange: { contentHeight = $0 },
            onKey: handle(key:),
            onOpenAttachment: open(attachment:)
        ) { onAttach in
            ComposerFooterView(
                controls: controls,
                onChange: apply(controls:),
                context: ContextWindowUsage.latest(in: transcript.rows),
                isRunning: transcript.isRunning,
                canSend: canSend,
                project: transcript.workspace.path,
                onAttach: onAttach,
                onSend: send,
                onStop: transcript.stop
            )
        }
        .overlay(alignment: .top) {
            if isScrolledUp {
                JumpToNewestPill(action: transcript.jumpToLiveEnd)
                    .alignmentGuide(.top) { $0[.bottom] + Metrics.spacing }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, Metrics.gutter)
        .task(id: transcript.session.id) { await prepare() }
        .onChange(of: transcript.draft) { _, _ in scheduleDraftSave() }
        .onDisappear(perform: saveDraftNow)
    }

    // MARK: - Height

    /// How tall the editor is drawn, and the whole of the rule.
    ///
    /// Two modes, and the divider is what switches between them. Left alone, the box grows with the
    /// text from one line to `ComposerTextEditor.maxLines` and then scrolls, exactly as it always
    /// has. Once the divider has been dragged the height belongs to the user and stops following
    /// the text, until they drag again or double click the divider to hand it back. The alternative
    /// (a manual height that content could still push past) would mean the box never stays where it
    /// was put, which is the one thing a resize has to promise.
    private var editorHeight: CGFloat {
        let stored = manualHeight > 0 ? CGFloat(manualHeight) : contentHeight
        let wanted = liveHeight ?? stored
        return min(max(wanted, ComposerTextEditor.lineHeight), maxEditorHeight)
    }

    /// The tallest the editor may be drawn without leaving the transcript nowhere to go. Applied on
    /// every render and not only while dragging, so shrinking the window shrinks the composer back
    /// rather than pushing the transcript off the top.
    private var maxEditorHeight: CGFloat {
        guard availableHeight > 0 else { return .greatestFiniteMagnitude }
        let room = availableHeight - chromeHeight - Self.minTranscriptHeight
        return max(room, ComposerTextEditor.lineHeight)
    }

    /// The drag begins from whatever is on screen, so switching out of automatic sizing never jumps.
    private func resize(by translation: CGFloat) {
        let origin = resizeOrigin ?? editorHeight
        resizeOrigin = origin
        // Down is positive in view coordinates, and dragging the top edge up is what makes the box
        // taller, so the translation is subtracted rather than added.
        let wanted = origin - translation
        liveHeight = min(max(wanted, ComposerTextEditor.lineHeight), maxEditorHeight)
    }

    private func endResize() {
        if let liveHeight { manualHeight = Double(liveHeight) }
        liveHeight = nil
        resizeOrigin = nil
    }

    private func resetHeight() {
        manualHeight = 0
        liveHeight = nil
        resizeOrigin = nil
    }

    // MARK: - Derived state

    private var sessionEditor: ComposerSessionEditor {
        ComposerSessionEditor(transcript: transcript, model: model)
    }

    private var controls: ComposerControls {
        ComposerControls(
            session: transcript.session,
            isFastMode: isFastMode,
            outputStyle: outputStyle
        )
    }

    private var hasBody: Bool {
        !transcript.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var attachments: [PromptAttachment] {
        PromptAttachmentStore.shared.attachments(for: transcript.session.id)
    }

    /// Attachments alone are a turn. Dropping a screenshot in and pressing send is a sentence, and
    /// making the user type a word to unlock the button would be asking them to talk to the guard
    /// rather than to the agent. It needs no clause of its own any more: a file is a word in the
    /// draft, so a prompt of nothing but one is a draft that is not empty.
    private var canSend: Bool { hasBody }

    // MARK: - Keys

    /// Everything `ComposerPrompt` did not claim for a menu it has open.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .returnKey, .commandReturn:
            send()
            return true
        case .escape:
            isFocused = false
            return true
        case .up, .down, .tab:
            return false
        }
    }

    // MARK: - Actions

    /// Writes the footer's choices back where a conversation keeps them: the four that are columns
    /// go on the session row, and fast mode and the output style go in the store's key value table.
    private func apply(controls new: ComposerControls) {
        if new.isFastMode != isFastMode {
            isFastMode = new.isFastMode
            if let store = app.store {
                let key = ComposerControls.fastModeKey(sessionID: transcript.session.id)
                let value = new.isFastMode ? "1" : nil
                Task { try? await store.setSetting(key, value) }
            }
        }

        if new.outputStyle != outputStyle {
            outputStyle = new.outputStyle
            if let store = app.store {
                let key = ComposerControls.outputStyleKey(sessionID: transcript.session.id)
                // The default is stored as no row at all, so a session that was set back to it
                // reads the same as one that was never asked. See `AgentRunner.refreshOutputStyle`.
                let value = OutputStyle.isDefault(new.outputStyle) ? nil : new.outputStyle
                Task { try? await store.setSetting(key, value) }
            }
        }

        let session = transcript.session

        // Picking a model out of the other backend's section is picking that backend, and what
        // that means depends on whether this chat has said anything yet.
        switch BackendChange.decide(
            from: session.agentKind,
            to: new.agentKind,
            hasSpoken: !transcript.rows.isEmpty
        ) {
        case .fork(let kind):
            fork(onto: kind, with: new)
            return
        case .changeInPlace, .unchanged:
            break
        }

        guard new.model != session.model
            || new.effort != session.effort
            || new.agentKind != session.agentKind
            || new.permissionMode != session.permissionMode
        else { return }

        sessionEditor.apply {
            $0.model = new.model
            $0.effort = new.effort
            $0.agentKind = new.agentKind
            $0.permissionMode = new.permissionMode
        }
    }

    /// A chat that has already spoken gets a new chat beside it rather than being turned into
    /// something else.
    ///
    /// Its rows are written in its backend's vocabulary, its thread id names a thread on that
    /// backend's server and its context lives there, so changing it in place would leave a
    /// transcript half in one vocabulary and half in the other, and a resume that resumes nothing.
    /// Same workspace, same worktree, same branch: a fork is cheap, and it is far less surprising
    /// than losing the conversation that is on screen.
    private func fork(onto kind: AgentKind, with controls: ComposerControls) {
        guard let model, let store = app.store else { return }
        let title = BackendChange.forkedTitle(transcript.session.title, to: kind)
        let draft = transcript.draft

        Task { @MainActor in
            guard let session = await model.createSession(title: title) else { return }
            // Narrow, as every write from this side has to be: `upsert` would put back the state
            // and the counters a runner owns, and this row already exists by the time we get here.
            try? await store.updateSessionPreferences(
                id: session.id,
                model: controls.model,
                effort: controls.effort,
                permissionMode: controls.permissionMode,
                agentKind: kind
            )
            await controls.store(sessionID: session.id, in: store)
            // The words that were typed go with it. A picker press must never be a way to lose a
            // prompt somebody is halfway through writing.
            if !draft.isEmpty {
                try? await store.saveDraft(sessionID: session.id, body: draft)
            }
            await model.reloadSessions()
        }
    }

    private func send() {
        guard canSend, !transcript.isRunning else { return }
        draftSaveTask?.cancel()

        // A file can be moved or deleted between being attached and the prompt going, and naming a
        // path that is not there any more only teaches the agent that Bloom lies about paths. The
        // chip carries a warning while it is on screen; this is the last check before it matters,
        // and a file that fails it is taken out of the sentence rather than sent as a path to
        // nothing.
        let worktree = transcript.workspace.path
        let text = AttachmentDraft
            .parse(transcript.draft, paths: attachments.map(\.path))
            .keeping { path in
                FileManager.default.fileExists(
                    atPath: PromptAttachment.sent(path: path).url(in: worktree).path
                )
            }

        // The records go and the files the message names stay. The prompt the agent is now reading
        // names those paths, and deleting them out from under it would break the one thing they
        // were for.
        PromptAttachmentStore.shared.settle(
            sent: text, sessionID: transcript.session.id, workspace: worktree
        )
        caret = 0
        let transcript = transcript
        Task { await transcript.send(text) }
    }

    /// Half a second is long enough that a fast typist writes one row instead of forty, and short
    /// enough that a crash mid sentence loses at most a word.
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let transcript = transcript
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await transcript.saveDraft()
        }
    }

    private func saveDraftNow() {
        draftSaveTask?.cancel()
        let transcript = transcript
        Task { await transcript.saveDraft() }
    }

    /// A chip opens the file where every other file in Bloom opens: the review tab, through
    /// `FileReview`. An attachment is not a special kind of file and does not get a special kind
    /// of tab.
    private func open(attachment: PromptAttachment) {
        guard let model else { return }
        FileReview.open(path: attachment.path, in: model)
    }

    // MARK: - First open

    /// Settle what a new session starts out as, and read back the two values that are not columns.
    /// All of it is only interesting once, hence the `task(id:)`. The precedence rules live in
    /// `ComposerDefaults`.
    private func prepare() async {
        isFocused = true
        caret = (transcript.draft as NSString).length

        guard let store = app.store else { return }
        let sessionID = transcript.session.id
        isFastMode = (try? await store.setting(
            ComposerControls.fastModeKey(sessionID: sessionID)
        )) == "1"
        outputStyle = (try? await store.setting(
            ComposerControls.outputStyleKey(sessionID: sessionID)
        )) ?? OutputStyle.defaultName

        // The marker is what separates "never opened" from "opened and left alone", which the
        // column values cannot express: a session created with the built-in defaults looks exactly
        // like one the user deliberately set to the same values. The create sheet writes it too,
        // so a model chosen there is never overruled the first time the workspace is opened.
        let appliedKey = ComposerControls.defaultsAppliedKey(sessionID: sessionID)
        let wasPrepared = (try? await store.setting(appliedKey)) == "1"
        guard !wasPrepared, transcript.session.agentSessionID == nil else { return }

        let appDefaults = await AppDefaults.load(from: store)

        // Off the main actor because it reads up to six files from disk.
        var repoSettings = RepoSettings()
        if let repo = app.repo(for: transcript.workspace) {
            let path = repo.path
            repoSettings = await Task.detached(priority: .utility) {
                SettingsLoader.load(repo: path)
            }.value
        }
        guard !Task.isCancelled else { return }

        let resolved = ComposerDefaults.resolve(repo: repoSettings, app: appDefaults)

        if appDefaults.fastMode != isFastMode {
            isFastMode = appDefaults.fastMode
            try? await store.setSetting(
                ComposerControls.fastModeKey(sessionID: sessionID),
                appDefaults.fastMode ? "1" : nil
            )
        }

        // Same shape as fast mode, and for the same reason: neither is a column, so neither can be
        // settled by the `sessionEditor.apply` below. The repository's settings file has no say
        // here, because it has no key for an output style: Bloom's TOML schema does not carry one
        // and Claude Code's own `.claude/settings.json` is already read by the CLI itself, so
        // copying its value up into this picker would be Bloom claiming to have chosen it.
        if appDefaults.outputStyle != outputStyle {
            outputStyle = appDefaults.outputStyle
            try? await store.setSetting(
                ComposerControls.outputStyleKey(sessionID: sessionID),
                OutputStyle.isDefault(appDefaults.outputStyle) ? nil : appDefaults.outputStyle
            )
        }

        let session = transcript.session
        if session.model != resolved.model
            || session.effort != resolved.effort
            || session.permissionMode != resolved.permissionMode {
            sessionEditor.apply {
                $0.model = resolved.model
                $0.effort = resolved.effort
                $0.permissionMode = resolved.permissionMode
            }
        }

        // Written last, so a cancelled preparation is retried rather than silently skipped.
        try? await store.setSetting(appliedKey, "1")
    }
}
