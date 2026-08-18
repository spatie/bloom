import SwiftUI
import AppKit
import BatonCore

/// The prompt box at the bottom of the centre column.
///
/// The view owns the draft, the caret and which completion menu is open, and nothing else: the
/// chrome, the footer controls and the two menus are their own views, and the rules for what the
/// draft means live in `ComposerMenu`. What is left here is the wiring between them, plus the keys,
/// because the text view keeps first responder the whole time and is the only thing that sees them.
struct ComposerView: View {
    @Bindable var transcript: TranscriptModel
    /// Optional so the composer can be dropped anywhere a transcript exists. When it is passed,
    /// the session list is kept in step with edits made here.
    var model: WorkspaceModel?
    /// The transcript owns the scroll position, so it decides whether the unread pill is useful.
    var isScrolledUp: Bool = true
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
    @State private var draftSaveTask: Task<Void, Never>?

    @State private var slashCatalog = SlashCommandCatalog()
    @State private var fileMatches: [FileMatch] = []
    @State private var menuIndex = 0
    @State private var isMenuDismissed = false

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
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            ComposerEditor(
                text: $transcript.draft,
                caret: $caret,
                isFocused: $isFocused,
                height: editorHeight,
                onContentHeightChange: { contentHeight = $0 },
                onKey: handle(key:)
            )

            ComposerFooterView(
                session: transcript.session,
                editor: sessionEditor,
                isRunning: transcript.isRunning,
                isFastMode: isFastMode,
                canSend: hasBody,
                onToggleFastMode: toggleFastMode,
                onAttach: attachFiles,
                onSend: send,
                onStop: transcript.stop
            )
        }
        .composerBox(isFocused: $isFocused)
        .overlay(alignment: .topLeading) {
            ComposerMenuOverlay(
                menu: activeMenu,
                commands: slashResults,
                files: fileMatches,
                selectedIndex: menuIndex,
                onPickCommand: pick(command:),
                onPickFile: pick(file:),
                onHighlight: { menuIndex = $0 }
            )
            .alignmentGuide(.top) { $0[.bottom] + Metrics.spacing }
        }
        .overlay(alignment: .top) {
            if isScrolledUp, transcript.unreadCount > 0 {
                NextUnreadPill(count: transcript.unreadCount, action: transcript.jumpToNextUnread)
                    .alignmentGuide(.top) { $0[.bottom] + Metrics.spacing }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, Metrics.gutter)
        .task(id: transcript.session.id) { await prepare() }
        .task(id: transcript.workspace.path) {
            await slashCatalog.load(workspacePath: transcript.workspace.path)
        }
        .task(id: activeMenu.mention?.query) { await refreshFileMatches() }
        .onChange(of: transcript.draft) { _, _ in
            menuIndex = 0
            scheduleDraftSave()
        }
        .onChange(of: menu) { old, new in
            menuIndex = 0
            // Escape only dismisses the menu that was open. Starting a different one, or clearing
            // the token entirely, makes the menu available again.
            if old.kind != new.kind { isMenuDismissed = false }
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

    private var hasBody: Bool {
        !transcript.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the text alone asks for, before Escape gets a say.
    private var menu: ComposerMenu {
        ComposerMenu.resolve(draft: transcript.draft, caret: caret)
    }

    private var activeMenu: ComposerMenu {
        isMenuDismissed ? .none : menu
    }

    private var isMenuOpen: Bool { activeMenu != .none }

    /// Only scored while the slash menu is actually on screen, so a keystroke in an ordinary draft
    /// costs nothing.
    private var slashResults: [SlashCommand] {
        guard case .slash(let query) = activeMenu else { return [] }
        return slashCatalog.matches(query)
    }

    private var menuCount: Int {
        switch activeMenu {
        case .slash: slashResults.count
        case .mention: fileMatches.count
        case .none: 0
        }
    }

    // MARK: - Completion

    private func refreshFileMatches() async {
        guard let token = activeMenu.mention else {
            fileMatches = []
            return
        }
        let paths = await FileIndex.shared.files(workspacePath: transcript.workspace.path)
        let query = token.query
        // Off the main actor: a large repository has tens of thousands of tracked files and this
        // runs on every keystroke after the `@`.
        fileMatches = await Task.detached(priority: .userInitiated) {
            FileMatch.search(paths, query: query, limit: 200)
        }.value
    }

    private func pick(command: SlashCommand) {
        let text = "/\(command.name) "
        transcript.draft = text
        caret = (text as NSString).length
        isFocused = true
    }

    private func pick(file: FileMatch) {
        guard let token = activeMenu.mention else { return }
        let replacement = "@\(file.path) "
        let text = NSMutableString(string: transcript.draft)
        text.replaceCharacters(
            in: NSRange(location: token.start, length: token.length),
            with: replacement
        )
        transcript.draft = text as String
        caret = token.start + (replacement as NSString).length
        isFocused = true
    }

    private func pickHighlighted() {
        switch activeMenu {
        case .slash:
            guard slashResults.indices.contains(menuIndex) else { return }
            pick(command: slashResults[menuIndex])
        case .mention:
            guard fileMatches.indices.contains(menuIndex) else { return }
            pick(file: fileMatches[menuIndex])
        case .none:
            break
        }
    }

    // MARK: - Keys

    /// Returns true when the key was consumed, which is how the text view knows not to type it.
    private func handle(key: ComposerKey) -> Bool {
        if isMenuOpen, menuCount > 0 {
            switch key {
            case .up:
                menuIndex = (menuIndex - 1 + menuCount) % menuCount
                return true
            case .down:
                menuIndex = (menuIndex + 1) % menuCount
                return true
            case .returnKey, .tab:
                pickHighlighted()
                return true
            case .escape:
                isMenuDismissed = true
                return true
            case .commandReturn:
                send()
                return true
            }
        }

        switch key {
        case .returnKey, .commandReturn:
            send()
            return true
        case .escape:
            if isMenuOpen {
                isMenuDismissed = true
            } else {
                isFocused = false
            }
            return true
        case .up, .down, .tab:
            return false
        }
    }

    // MARK: - Actions

    private func send() {
        guard hasBody, !transcript.isRunning else { return }
        draftSaveTask?.cancel()
        let text = transcript.draft
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

    private func toggleFastMode() {
        isFastMode.toggle()
        guard let store = app.store else { return }
        let key = Self.fastModeKey(sessionID: transcript.session.id)
        let value = isFastMode ? "1" : nil
        Task { try? await store.setSetting(key, value) }
    }

    private func attachFiles() {
        Task { await attach() }
    }

    /// A sheet rather than an application-modal panel: `runModal()` stops the run loop, which stops
    /// every other workspace's transcript from streaming for as long as the picker is open.
    private func attach() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: transcript.workspace.path)

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK else { return }

        let root = transcript.workspace.path
        let mentions = panel.urls.map { url -> String in
            let path = url.path
            let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
            return "@\(relative)"
        }
        guard !mentions.isEmpty else { return }

        let separator = transcript.draft.isEmpty || transcript.draft.hasSuffix(" ") ? "" : " "
        transcript.draft += separator + mentions.joined(separator: " ") + " "
        caret = (transcript.draft as NSString).length
        isFocused = true
    }

    // MARK: - First open

    /// Settle what a new session starts out as, and read back the fast mode flag. Both are only
    /// interesting once, hence the `task(id:)`. The precedence rules live in `ComposerDefaults`.
    private func prepare() async {
        isFocused = true
        caret = (transcript.draft as NSString).length

        guard let store = app.store else { return }
        let sessionID = transcript.session.id
        isFastMode = (try? await store.setting(Self.fastModeKey(sessionID: sessionID))) == "1"

        // The marker is what separates "never opened" from "opened and left alone", which the
        // column values cannot express: a session created with the built-in defaults looks exactly
        // like one the user deliberately set to the same values.
        let appliedKey = Self.defaultsAppliedKey(sessionID: sessionID)
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
                Self.fastModeKey(sessionID: sessionID),
                appDefaults.fastMode ? "1" : nil
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

    private static func fastModeKey(sessionID: String) -> String {
        "session.\(sessionID).fastMode"
    }

    /// Records that a session has been through `prepare()`, so reopening it never re-applies the
    /// defaults over choices the user has since made in the footer.
    private static func defaultsAppliedKey(sessionID: String) -> String {
        "session.\(sessionID).defaultsApplied"
    }
}
