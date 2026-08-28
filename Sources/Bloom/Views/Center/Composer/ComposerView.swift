import SwiftUI
import AppKit
import BloomCore

/// The prompt box at the bottom of the centre column.
///
/// The surface itself is `ComposerPrompt`, which the create window uses too. What is left here is
/// everything that is true of a conversation and of nothing else: the draft belongs to a
/// transcript and is saved back to it, the divider above the box, the footer's values coming off
/// a `Session` row, and the first-open defaults.
struct ComposerView: View {
    @Bindable var transcript: TranscriptModel
    /// Optional so the composer can be dropped anywhere a transcript exists. When it is passed,
    /// the session list is kept in step with edits made here.
    var model: WorkspaceModel?
    /// How tall the region the transcript and the composer share is, so a drag can be stopped
    /// before the transcript is squeezed out of it.
    ///
    /// An object rather than a number, and `ComposerRoom` carries the measurement for why: a
    /// number is read by the view that passes it, so the pane publishing a new height rebuilt the
    /// transcript beside this box on every frame that rewrapped a line of the draft.
    var room: ComposerRoom = ComposerRoom()
    /// What the empty box says. The default is what every chat in a worktree says; Ask Bloom
    /// passes its own, because a conversation that cannot change a file should not open by
    /// inviting somebody to ask it to.
    var placeholder: String = ComposerEditor.chatPlaceholder
    var destinationLabel: String?

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
    ///
    /// Rounded, like the pane height it is taken off. This feeds `maxEditorHeight`, which feeds
    /// `editorHeight`, which is the body: raw, a window resize wrote it once a frame and each
    /// write re-ran this view and the footer under it. Up rather than down, because it is
    /// subtracted from the room, so both roundings err on the side of leaving the transcript its
    /// floor. See `PaneMeasure`.
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
            if let destinationLabel {
                HStack(spacing: Metrics.spacingSmall) {
                    Image(systemName: "bubble.left")
                    Text(destinationLabel)
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, Metrics.gutter)
                .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                .background(Palette.surfaceSunken)
                .overlay(alignment: .bottom) { Hairline() }
            }

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
        //
        // Rounded in the action rather than in the probe, unlike `ChatPaneView`: the number being
        // measured is the whole composer and the number being kept is the difference between that
        // and the editor, so a probe that quantised the total would put the rounding error into a
        // subtraction instead of into the answer. The guard is what stops the write: a resize
        // moves the total on every frame and leaves the chrome exactly where it was, and writing
        // an unchanged value into `@State` still re-runs this body.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { total in
            let chrome = PaneMeasure.chrome(total - editorHeight)
            if chrome != chromeHeight { chromeHeight = chrome }
        }
    }

    private var composer: some View {
        ComposerPrompt(
            text: $transcript.draft,
            caret: $caret,
            isFocused: $isFocused,
            mentionRoot: transcript.cwd,
            attachmentRoot: transcript.cwd,
            attachmentKey: transcript.session.id.rawValue,
            reviewComments: reviewComments,
            onRemoveReviewComment: remove(reviewComment:),
            onOpenReviewComment: open(reviewComment:),
            // Declared after the review comments on `ComposerPrompt`, and the memberwise
            // initialiser takes its arguments in declaration order.
            placeholder: placeholder,
            editorHeight: editorHeight,
            onContentHeightChange: { contentHeight = $0 },
            onKey: handle(key:),
            onOpenAttachment: open(attachment:),
            fillsPanel: true
        ) { actions in
            ComposerFooterView(
                controls: controls,
                onChange: apply(controls:),
                context: transcript.contextUsage,
                isRunning: transcript.isRunning,
                canSend: canSend,
                project: transcript.cwd,
                onAttach: actions.attach,
                onQuickPrompt: { fire($0, insert: actions.insert) },
                onSend: send,
                onStop: transcript.stop
            )
        }
        // Command-Backspace is delete-to-start-of-line in every text box on macOS, and the menu bar
        // had it for Archive Workspace. A user typing a prompt reached for it and archived the
        // workspace he was writing in. See `FocusedValues.isTypingProse`.
        .focusedValue(\.isTypingProse, isFocused)
        .task(id: transcript.session.id) { await prepare() }
        .onChange(of: transcript.draft) { _, _ in scheduleDraftSave() }
        // Something put words in the box for the owner to carry on writing, which today is Edit on
        // a queued message. The caret goes to the start rather than the end, because the words that
        // just arrived are at the front and are the ones the button was pressed to change.
        .onChange(of: transcript.composerFocusRequests) { _, _ in
            isFocused = true
            caret = 0
        }
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
        let available = room.height
        guard available > 0 else { return .greatestFiniteMagnitude }
        let left = available - chromeHeight - Self.minTranscriptHeight
        return max(left, ComposerTextEditor.lineHeight)
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

    /// Whether anything but whitespace has been typed.
    ///
    /// Asked rather than trimmed. `trimmingCharacters` allocates a copy of the whole draft to
    /// settle a question the first non-space character settles, and this is read through `canSend`
    /// on every pass of the composer's body.
    private var hasBody: Bool {
        transcript.draft.contains { !$0.isWhitespace }
    }

    private var attachments: [PromptAttachment] {
        PromptAttachmentStore.shared.attachments(for: transcript.session.id.rawValue)
    }

    /// The pending review, which rides with whatever is sent next from this workspace.
    private var reviewComments: [ReviewComment] {
        model?.reviewComments ?? []
    }

    /// Attachments alone are a turn. Dropping a screenshot in and pressing send is a sentence, and
    /// making the user type a word to unlock the button would be asking them to talk to the guard
    /// rather than to the agent. It needs no clause of its own any more: a file is a word in the
    /// draft, so a prompt of nothing but one is a draft that is not empty.
    ///
    /// Review comments alone are a turn for the same reason: each one already says which file,
    /// which line and what to do, and the payload spells out that the comments are the whole
    /// request when nothing else was typed. See `ReviewPromptContext.noMessage`.
    private var canSend: Bool { hasBody || !reviewComments.isEmpty }

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
        let draft = transcript.draft

        // Ask Bloom has no workspace and therefore no tab beside this one to fork into. Its
        // equivalent is a fresh conversation: the old one is archived, so its transcript is
        // retained, while the new backend starts with a thread it actually owns.
        guard let model else {
            Task { @MainActor in
                await app.ask.startFresh(controls: controls, draft: draft)
            }
            return
        }

        guard let store = app.store else { return }
        let title = BackendChange.forkedTitle(transcript.session.title, to: kind)

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

    /// Return, or the button at the end of the footer.
    ///
    /// No longer refused while a turn is running. What happens to the words is
    /// `TranscriptModel.submit`'s decision, not this view's: they join the chat's queue and go
    /// when the queue is allowed to move. Deciding it here would be a second copy of the rule, and
    /// the rule already exists in a place the suite can reach it. See `DeliveryHold`.
    private func send() {
        guard canSend else { return }
        draftSaveTask?.cancel()

        // A file can be moved or deleted between being attached and the prompt going, and naming a
        // path that is not there any more only teaches the agent that Bloom lies about paths. The
        // chip carries a warning while it is on screen; this is the last check before it matters,
        // and a file that fails it is taken out of the sentence rather than sent as a path to
        // nothing.
        let worktree = transcript.cwd
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
            sent: text, sessionID: transcript.session.id.rawValue, workspace: worktree
        )
        caret = 0
        let transcript = transcript
        let comments = reviewComments
        guard !comments.isEmpty else {
            Task { await transcript.submit(text) }
            return
        }

        // The pending review goes with the message, as one turn: what was typed, then every
        // comment with its file, its line and the code around it, composed in the core where the
        // suite can hold it still. Off the main actor because resolving re-reads every commented
        // file. The comments are deleted only after the submit, by id, so a comment added in the
        // gap is not swept out with the ones that went.
        let model = model
        let template = PromptOverrides().template(for: .review)
        Task {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let composed = await Task.detached(priority: .userInitiated) {
                ReviewTurn.compose(
                    message: message,
                    comments: comments,
                    worktreePath: worktree,
                    template: template
                )
            }.value
            await transcript.submit(composed)
            await model?.removeReviewComments(ids: comments.map(\.id))
        }
    }

    // MARK: - Quick prompts

    /// What choosing a quick prompt does here.
    ///
    /// The four routes are `QuickPromptDelivery`'s and not this view's, which is the whole reason
    /// that type exists: the rule has cases worth holding still, and a decision taken in a view is
    /// one nothing can test. What is left here is the doing, and both halves of it are the paths
    /// that already exist. Sending is `send()`, the same function Return and the Send button call,
    /// so a prompt fired while a turn is running queues behind it exactly as a typed message does.
    /// A new chat is `WorkspaceModel.createSession`, which is what the `+` in the strip presses.
    ///
    /// `canOpenNewChat` is a real question rather than a constant: this composer is dropped in
    /// wherever a transcript exists, and without the workspace model there is no strip to open a
    /// second chat on. A prompt that asked for one then writes into this box instead.
    private func fire(_ prompt: QuickPrompt, insert: @MainActor (QuickPrompt) -> Void) {
        switch QuickPromptDelivery.decided(
            for: prompt, canSend: true, canOpenNewChat: model != nil
        ) {
        case .compose:
            insert(prompt)
        case .send:
            // Written into the draft first and then sent, rather than submitted straight from the
            // prompt: what goes is the box, so half a sentence already typed goes with it instead
            // of being left behind under a turn that answered something else. The form's own line
            // says so before the switch is turned on.
            insert(prompt)
            send()
        case .composeInNewChat:
            openChat(for: prompt, sending: false)
        case .sendInNewChat:
            openChat(for: prompt, sending: true)
        }
    }

    /// Opens a chat for a quick prompt and puts the words in it, sent or waiting.
    ///
    /// The draft goes to the store before it goes to the transcript, and that order is the bug
    /// this avoids: the new chat's `TranscriptModel` is already loading by the time
    /// `createSession` returns, and the last thing that load does is read the draft out of the
    /// store. Written the other way round, the load lands afterwards and puts the empty box back.
    /// Both are written, so a load that had already finished is not left holding nothing, and the
    /// two agree because the store now says the same words.
    private func openChat(for prompt: QuickPrompt, sending: Bool) {
        guard let model else { return }
        let text = prompt.text
        Task { @MainActor in
            guard let session = await model.createSession(title: prompt.chatTitle) else { return }
            guard sending else {
                try? await app.store?.saveDraft(sessionID: session.id, body: text)
                model.transcript(for: session).draft = text
                return
            }
            await model.transcript(for: session).submit(text)
        }
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

    /// A comment chip opens the diff it was written on, where its band is.
    private func open(reviewComment comment: ReviewComment) {
        guard let model else { return }
        FileReview.open(path: comment.filePath, in: model)
    }

    private func remove(reviewComment id: ReviewCommentID) {
        guard let model else { return }
        Task { await model.removeReviewComment(id: id) }
    }

    // MARK: - First open

    /// Settle what a new session starts out as, and read back the two values that are not columns.
    /// All of it is only interesting once, hence the `task(id:)`. The precedence rules live in
    /// `ComposerDefaults`.
    private func prepare() async {
        // A `defer`, because this function has five ways out and every one of them is a composer
        // that is ready: the common one by far is the early return below for a session whose
        // defaults were applied on an earlier launch, which is exactly the path a return to a chat
        // tab takes. A mark on the last line would never fire for it. See `TabProbe`.
        defer {
            SwitchTrace.mark("composer.prepared", workspace: transcript.workspace?.id)
            SwitchTrace.markOnScreen("composer.prepared", workspace: transcript.workspace?.id)
        }
        isFocused = true
        caret = (transcript.draft as NSString).length

        guard let store = app.store else { return }
        let sessionID = transcript.session.id
        let storedFastMode = (try? await store.setting(
            ComposerControls.fastModeKey(sessionID: sessionID)
        )) == "1"
        let storedStyle = (try? await store.setting(
            ComposerControls.outputStyleKey(sessionID: sessionID)
        )) ?? OutputStyle.defaultName
        // Checked before every write of the pane's state from here down. The pane is reused
        // across sessions, and an actor call does not stop for cancellation, so a switch made
        // while this task was reading used to let the OLD session's answers resume and land on
        // the state the NEW session's own preparation had just written.
        guard !Task.isCancelled else { return }
        isFastMode = storedFastMode
        outputStyle = storedStyle

        // The marker is what separates "never opened" from "opened and left alone", which the
        // column values cannot express: a session created with the built-in defaults looks exactly
        // like one the user deliberately set to the same values. The create window writes it too,
        // so a model chosen there is never overruled the first time the workspace is opened.
        let appliedKey = ComposerControls.defaultsAppliedKey(sessionID: sessionID)
        let wasPrepared = (try? await store.setting(appliedKey)) == "1"
        guard !wasPrepared, transcript.session.agentSessionID == nil else { return }

        let appDefaults = await AppDefaults.load(from: store)

        // Off the main actor because it reads up to six files from disk.
        var repoSettings = RepoSettings()
        if let workspace = transcript.workspace, let repo = app.repo(for: workspace) {
            let path = repo.path
            repoSettings = await Task.detached(priority: .utility) {
                SettingsLoader.load(repo: path)
            }.value
        }
        guard !Task.isCancelled else { return }

        // A chat with no worktree does not inherit the owner's permission mode, and that is the
        // whole of decision two: the default is Full access, and this is the one conversation in
        // Bloom that sits above every project. See `ComposerDefaults.resolve`.
        let resolved = ComposerDefaults.resolve(
            repo: repoSettings,
            app: appDefaults,
            hasWorktree: transcript.workspace != nil,
            // The chat's own backend, so "start in plan mode" cannot write Plan onto a Codex row.
            backend: transcript.session.agentKind
        )

        if appDefaults.fastMode != isFastMode {
            isFastMode = appDefaults.fastMode
            try? await store.setSetting(
                ComposerControls.fastModeKey(sessionID: sessionID),
                appDefaults.fastMode ? "1" : nil
            )
            guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
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
