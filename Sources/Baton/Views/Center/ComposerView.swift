import SwiftUI
import AppKit
import BatonCore

/// The keys the composer has to answer for itself.
///
/// A menu is open on top of a text view that never loses first responder, so the arrow keys and
/// Return mean different things depending on what is on screen. The text view forwards the
/// question here rather than deciding.
enum ComposerKey {
    case up
    case down
    case returnKey
    case commandReturn
    case escape
    case tab
}

/// The prompt box at the bottom of the centre column.
///
/// Everything the user can change about the next turn lives in this one view: the text, the
/// model, the effort, the permission mode. That is deliberate. A setting that lives in a
/// preferences window is a setting nobody changes per task, and per task is exactly the
/// granularity these need.
struct ComposerView: View {
    @Bindable var transcript: TranscriptModel
    /// Optional so the composer can be dropped anywhere a transcript exists. When it is passed,
    /// the session list is kept in step with edits made here.
    var model: WorkspaceModel?
    /// The transcript owns the scroll position, so it decides whether the unread pill is useful.
    var isScrolledUp: Bool = true

    @Environment(AppModel.self) private var app

    @State private var caret = 0
    @State private var editorHeight: CGFloat = 0
    @State private var isFocused = false
    @State private var isFastMode = false
    @State private var draftSaveTask: Task<Void, Never>?

    @State private var slashCatalog = SlashCommandCatalog()
    @State private var fileMatches: [FileMatch] = []
    @State private var menuIndex = 0
    @State private var isMenuDismissed = false

    private let placeholder = "Ask to make changes, @mention files, run /commands"

    var body: some View {
        box
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.gutter)
            .padding(.top, Metrics.cornerSmall)
            .background(Palette.surface)
            .task(id: transcript.session.id) { await prepare() }
            .task(id: transcript.workspace.path) {
                await slashCatalog.load(workspacePath: transcript.workspace.path)
            }
            .task(id: mentionToken?.query) { await refreshFileMatches() }
            .onChange(of: transcript.draft) { _, _ in
                menuIndex = 0
                scheduleDraftSave()
            }
            .onChange(of: menuTrigger) { old, new in
                menuIndex = 0
                // Escape only dismisses the menu that was open. Starting a different one, or
                // clearing the token entirely, makes the menu available again.
                if old.kind != new.kind { isMenuDismissed = false }
            }
            .onDisappear {
                draftSaveTask?.cancel()
                let current = transcript
                Task { await current.saveDraft() }
            }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: Metrics.corner) {
            editor
            footer
        }
        .padding(Metrics.gutter)
        // The tap lives on the background rather than the box, so a click inside the text view
        // still lands on the text view and only the padding acts as a focus target.
        .background {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .fill(Palette.surfaceRaised)
                .onTapGesture { isFocused = true }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .stroke(
                    isFocused ? Palette.accent : Palette.border,
                    lineWidth: isFocused ? Metrics.hairline * 2 : Metrics.hairline
                )
        }
        .shadow(color: isFocused ? Palette.accent.opacity(0.24) : .clear, radius: Metrics.cornerSmall)
        .overlay(alignment: .topLeading) {
            menuOverlay
                .alignmentGuide(.top) { $0[.bottom] + Metrics.corner }
        }
        .overlay(alignment: .top) {
            unreadOverlay
                .alignmentGuide(.top) { $0[.bottom] + Metrics.corner }
        }
    }

    // MARK: - Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if transcript.draft.isEmpty {
                Text(placeholder)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textTertiary)
                    .allowsHitTesting(false)
            }
            ComposerTextEditor(
                text: $transcript.draft,
                caret: $caret,
                isFocused: $isFocused,
                onHeightChange: { editorHeight = $0 },
                onKey: handle(key:)
            )
            .frame(height: max(editorHeight, ComposerTextEditor.lineHeight))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Metrics.cornerSmall) {
            modelPicker
            fastToggle
            effortPicker
            permissionPicker

            Spacer(minLength: 8)

            Button(action: attach) {
                Image(systemName: "plus")
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
            }
            .buttonStyle(.borderless)
            .help("Attach a file")

            sendButton
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(ComposerOption.models) { option in
                Button {
                    update { $0.model = option.id }
                } label: {
                    if transcript.session.model == option.id { Text("\(option.label) \u{2713}") }
                    else { Text(option.label) }
                }
            }
        } label: {
            Label(
                ComposerOption.label(for: transcript.session.model, in: ComposerOption.models),
                systemImage: "sparkle"
            )
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the model")
    }

    /// Fast mode has no column on `Session`, so it is kept in the store's key value table. It is
    /// still per session and it still survives a relaunch, which is all the toggle promises.
    private var fastToggle: some View {
        Button {
            isFastMode.toggle()
            let key = Self.fastModeKey(sessionID: transcript.session.id)
            let value = isFastMode ? "1" : nil
            if let store = app.store {
                Task { try? await store.setSetting(key, value) }
            }
        } label: {
            ComposerControlLabel(
                systemImage: "bolt.fill",
                text: "Fast",
                tint: isFastMode ? Palette.accent : Palette.textSecondary,
                isActive: isFastMode
            )
        }
        .buttonStyle(.borderless)
        .help("Fast mode trades some reasoning for a quicker reply")
    }

    private var effortPicker: some View {
        Menu {
            ForEach(ComposerOption.efforts) { option in
                Button {
                    update { $0.effort = option.id }
                } label: {
                    if transcript.session.effort == option.id { Text("\(option.label) \u{2713}") }
                    else { Text(option.label) }
                }
            }
        } label: {
            Label(
                ComposerOption.label(for: transcript.session.effort, in: ComposerOption.efforts),
                systemImage: "chart.bar.fill"
            )
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose reasoning effort")
    }

    private var permissionPicker: some View {
        Menu {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Button {
                    update { $0.permissionMode = mode }
                } label: {
                    if transcript.session.permissionMode == mode { Text("\(mode.label) \u{2713}") }
                    else { Text(mode.label) }
                }
            }
        } label: {
            Label(
                transcript.session.permissionMode.label,
                systemImage: Self.permissionGlyph(transcript.session.permissionMode)
            )
            .font(Typo.caption)
            .foregroundStyle(
                transcript.session.permissionMode == .bypassPermissions
                    ? Palette.warning
                    : Palette.textSecondary
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose permission mode")
    }

    private var sendButton: some View {
        Button {
            if transcript.isRunning { transcript.stop() } else { send() }
        } label: {
            Image(systemName: transcript.isRunning ? "stop.fill" : "arrow.up")
                .font(Typo.captionEmphasis)
                .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(transcript.isRunning ? Palette.negative : Palette.accent)
        .disabled(!transcript.isRunning && !hasBody)
        .help(transcript.isRunning ? "Stop the agent" : "Send (Return)")
    }

    private var hasBody: Bool {
        !transcript.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Overlays

    @ViewBuilder
    private var menuOverlay: some View {
        switch activeMenu {
        case .slash(let query):
            SlashCommandMenu(
                commands: slashResults,
                query: query,
                selectedIndex: menuIndex,
                onPick: pick(command:),
                onHighlight: { menuIndex = $0 }
            )
        case .mention(let query):
            FileMentionMenu(
                matches: fileMatches,
                query: query,
                selectedIndex: menuIndex,
                onPick: pick(file:),
                onHighlight: { menuIndex = $0 }
            )
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var unreadOverlay: some View {
        if isScrolledUp, transcript.unreadCount > 0 {
            NextUnreadPill(count: transcript.unreadCount) {
                transcript.jumpToNextUnread()
            }
        }
    }

    // MARK: - Menus

    private enum ActiveMenu: Equatable {
        case none
        case slash(String)
        case mention(String)

        enum Kind { case none, slash, mention }

        var kind: Kind {
            switch self {
            case .none: .none
            case .slash: .slash
            case .mention: .mention
            }
        }
    }

    /// What the text alone asks for, before Escape gets a say.
    private var menuTrigger: ActiveMenu {
        if let query = slashQuery { return .slash(query) }
        if let token = mentionToken { return .mention(token.query) }
        return .none
    }

    /// The draft plus the caret is enough to know which menu belongs on screen, so there is no
    /// separate "menu is open" flag to get out of step with the text.
    private var activeMenu: ActiveMenu {
        isMenuDismissed ? .none : menuTrigger
    }

    private var isMenuOpen: Bool { activeMenu != .none }

    /// A slash command is only offered while the whole draft is one unbroken `/word`, because
    /// that is the only shape the CLI treats as a command.
    private var slashQuery: String? {
        let text = transcript.draft
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return nil }
        return String(rest)
    }

    private struct MentionToken: Equatable {
        var start: Int
        var length: Int
        var query: String
    }

    /// Everything here counts in UTF-16, the unit `NSTextView` reports its caret in, so a path
    /// with an emoji in it cannot shift the replacement range by a character.
    private var mentionToken: MentionToken? {
        let text = transcript.draft as NSString
        let location = min(max(caret, 0), text.length)
        guard location > 0 else { return nil }

        let before = text.substring(to: location) as NSString
        let at = before.range(of: "@", options: .backwards)
        guard at.location != NSNotFound else { return nil }

        let query = before.substring(from: at.location + 1)
        guard !query.contains(" "), !query.contains("\n"), !query.contains("\t") else { return nil }

        if at.location > 0 {
            let previous = before.substring(with: NSRange(location: at.location - 1, length: 1))
            guard [" ", "\n", "\t", "(", "["].contains(previous) else { return nil }
        }

        return MentionToken(start: at.location, length: location - at.location, query: query)
    }

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

    private func refreshFileMatches() async {
        guard let token = mentionToken else {
            fileMatches = []
            return
        }
        let paths = await FileIndex.shared.files(workspacePath: transcript.workspace.path)
        let query = token.query
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
        guard let token = mentionToken else { return }
        let replacement = "@\(file.path) "
        let text = NSMutableString(string: transcript.draft)
        text.replaceCharacters(in: NSRange(location: token.start, length: token.length), with: replacement)
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

    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: transcript.workspace.path)
        guard panel.runModal() == .OK else { return }

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

    /// Writes a session edit through to the store, and into the workspace's own copy so the tab
    /// strip and the inspector do not keep showing the value from before the change.
    private func update(_ change: (inout Session) -> Void) {
        var session = transcript.session
        change(&session)
        session.updatedAt = Date()
        transcript.session = session

        if let model, let index = model.sessions.firstIndex(where: { $0.id == session.id }) {
            model.sessions[index] = session
        }
        // Only the columns this view owns are written. A whole-row upsert here would race the
        // agent runner, which writes the agent session id, the state and the token counters on
        // the same row, and the losing write silently breaks resume.
        Task {
            await transcript.updatePreferences(
                title: session.title,
                model: session.model,
                effort: session.effort,
                permissionMode: session.permissionMode
            )
        }
    }

    /// First open of a session: settle what it starts out as, and read back the fast mode flag.
    /// Both are only interesting once, hence the `task(id:)`.
    ///
    /// Precedence, most specific first:
    ///
    /// 1. **The session itself.** Once it has been prepared, or once it has run an agent, nothing
    ///    here touches it again. A choice the user made in the footer is never overwritten.
    /// 2. **The repository's settings file**, via `SettingsLoader.load(repo:)`. A repo that pins
    ///    `models.default` means it, and it means it more than a global preference does.
    /// 3. **The app-level defaults** from Settings, Models (`AppDefaults`).
    /// 4. **The built-in fallbacks**, which `AppDefaults` holds and `Session.init` matches.
    ///
    /// The repository file has no say over permission mode, plan mode or fast mode, because it
    /// has no keys for them, so those fall straight from level 3 to level 4.
    private func prepare() async {
        isFocused = true
        caret = (transcript.draft as NSString).length

        guard let store = app.store else { return }
        let sessionID = transcript.session.id
        isFastMode = (try? await store.setting(Self.fastModeKey(sessionID: sessionID))) == "1"

        // Level 1. The marker is what separates "never opened" from "opened and left alone",
        // which the column values cannot express: a session created with the built-in defaults
        // looks exactly like one the user deliberately set to the same values.
        let appliedKey = Self.defaultsAppliedKey(sessionID: sessionID)
        let wasPrepared = (try? await store.setting(appliedKey)) == "1"
        guard !wasPrepared, transcript.session.agentSessionID == nil else { return }

        // Level 3, read first because level 2 only overrides two of its fields.
        let defaults = await AppDefaults.load(from: store)

        // Level 2. Off the main actor because it reads up to six files from disk.
        var repoSettings = RepoSettings()
        if let repo = app.repo(for: transcript.workspace) {
            let path = repo.path
            repoSettings = await Task.detached(priority: .utility) {
                SettingsLoader.load(repo: path)
            }.value
        }
        guard !Task.isCancelled else { return }

        let model = Self.firstNonEmpty(repoSettings.defaultModel, defaults.model)
        let effort = Self.firstNonEmpty(repoSettings.defaultEffort, defaults.effort)
        // "Start in plan mode" is the more specific instruction of the two, so it beats the
        // permission mode picker when both are set rather than the two fighting over one column.
        let permissionMode = defaults.planMode ? PermissionMode.plan : defaults.permissionMode

        if defaults.fastMode != isFastMode {
            isFastMode = defaults.fastMode
            try? await store.setSetting(
                Self.fastModeKey(sessionID: sessionID),
                defaults.fastMode ? "1" : nil
            )
        }

        var session = transcript.session
        if session.model != model || session.effort != effort || session.permissionMode != permissionMode {
            session.model = model
            session.effort = effort
            session.permissionMode = permissionMode
            update { $0 = session }
        }

        // Written last, so a cancelled preparation is retried rather than silently skipped.
        try? await store.setSetting(appliedKey, "1")
    }

    private static func fastModeKey(sessionID: String) -> String {
        "session.\(sessionID).fastMode"
    }

    /// A settings file with an empty value in it is a missing value, not an instruction to blank
    /// the session's model out.
    private static func firstNonEmpty(_ preferred: String?, _ fallback: String) -> String {
        guard let preferred, !preferred.trimmingCharacters(in: .whitespaces).isEmpty else {
            return fallback
        }
        return preferred
    }

    /// Records that a session has been through `prepare()`, so reopening it never re-applies the
    /// defaults over choices the user has since made in the footer.
    private static func defaultsAppliedKey(sessionID: String) -> String {
        "session.\(sessionID).defaultsApplied"
    }

    private static func permissionGlyph(_ mode: PermissionMode) -> String {
        switch mode {
        case .auto: "hand.raised"
        case .acceptEdits: "checkmark.shield"
        case .bypassPermissions: "exclamationmark.shield"
        case .plan: "list.bullet.rectangle"
        }
    }
}

// MARK: - Footer pieces

/// The picker labels in the footer are all the same shape: a glyph, a word, and a hint that it
/// opens. Defining it once keeps them on one baseline.
struct ComposerControlLabel: View {
    var systemImage: String
    var text: String
    var tint: Color = Palette.textSecondary
    var isActive: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Metrics.cornerSmall) {
            Image(systemName: systemImage)
                .font(Typo.micro)
            Text(text)
                .font(Typo.caption)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Metrics.corner)
        .frame(height: Metrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(isActive ? Palette.selected : (isHovered ? Palette.hover : .clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// One entry in a footer picker. The id is what gets written to `Session`, the label is what the
/// user reads, and the two are different on purpose: the CLI wants `opus`, the user wants Opus 5.
struct ComposerOption: Identifiable, Hashable {
    var id: String
    var label: String

    static let models = [
        ComposerOption(id: "opus", label: "Opus 5"),
        ComposerOption(id: "sonnet", label: "Sonnet 5"),
        ComposerOption(id: "haiku", label: "Haiku 4.5"),
    ]

    static let efforts = [
        ComposerOption(id: "low", label: "Low"),
        ComposerOption(id: "medium", label: "Medium"),
        ComposerOption(id: "high", label: "High"),
        ComposerOption(id: "xhigh", label: "Xhigh"),
        ComposerOption(id: "max", label: "Max"),
    ]

    /// Falls back to the raw value so a model set in a settings file that Baton has never heard
    /// of is still shown rather than silently rewritten.
    static func label(for id: String, in options: [ComposerOption]) -> String {
        options.first { $0.id == id }?.label ?? (id.isEmpty ? options[0].label : id.capitalized)
    }
}

/// The floating "you are behind" affordance.
///
/// It lives here rather than in the transcript because it is anchored to the composer, but the
/// transcript renders one too when the user scrolls far up, so it is a type rather than a
/// private helper.
struct NextUnreadPill: View {
    var count: Int
    var action: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.cornerSmall) {
                Image(systemName: "arrow.down")
                    .font(Typo.micro)
                Text(count == 1 ? "Next unread" : "Next unread (\(count))")
                    .font(Typo.captionEmphasis)
            }
            .foregroundStyle(Palette.textInverted)
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.rowHeight)
            .background(Palette.accent.opacity(isHovered ? 1 : 0.9), in: Capsule())
            .shadow(
                color: Palette.textPrimary.opacity(0.2),
                radius: Metrics.corner,
                y: Metrics.hairline * 2
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - The text view

/// The composer's editor, as an `NSTextView` rather than a `TextEditor`.
///
/// Two things force it. SwiftUI's `TextEditor` will not tell anyone the height its content wants,
/// so a box that grows from one line to twelve and only then scrolls cannot be built on top of
/// it. And Return has to send while Shift+Return inserts a newline, which means seeing the key
/// event before the text system does. Both are one override away in AppKit and impossible above
/// it.
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Caret offset in UTF-16 units, so the composer can find the `@token` around it.
    @Binding var caret: Int
    @Binding var isFocused: Bool
    var minLines: Int = 1
    var maxLines: Int = 12
    var onHeightChange: @MainActor (CGFloat) -> Void
    var onKey: @MainActor (ComposerKey) -> Bool

    static var font: NSFont { NSFont.preferredFont(forTextStyle: .body) }
    static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Built out of an explicit TextKit 1 stack. A text view made the modern way answers with
        // a TextKit 2 layout, and `usedRect(for:)` is the only measurement that reports the exact
        // height wrapped text occupies.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = ComposerTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.keyHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event) ?? false
        }
        // Wrapping depends on the width, so the measurement is only valid until the window is
        // resized. Re-measuring on the frame change is cheaper than laying out speculatively.
        textView.onWidthChange = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.reportHeight(of: textView)
        }
        // Clicking straight into the text makes it first responder without SwiftUI asking, so
        // the flag has to follow AppKit rather than the other way round.
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(to: focused)
        }
        textView.font = Self.font
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.autoresizingMask = [.width]
        textView.minSize = CGSize(width: 0, height: 0)
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            textView.string = text
            textView.font = Self.font
            textView.textColor = NSColor.labelColor
            let location = min(max(caret, 0), (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        } else if !isFocused, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }

        context.coordinator.reportHeight(of: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }
            parent.text = textView.string
            parent.caret = textView.selectedRange().location
            reportHeight(of: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }
            let location = textView.selectedRange().location
            if parent.caret != location { parent.caret = location }
        }

        /// Deferred by one turn of the run loop: the responder change can land in the middle of a
        /// SwiftUI update, and writing state there is how a view ends up fighting itself.
        func focusChanged(to focused: Bool) {
            guard parent.isFocused != focused else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isFocused != focused else { return }
                self.parent.isFocused = focused
            }
        }

        /// Maps a raw key event to composer intent. Shift+Return is deliberately not mapped: it
        /// falls through to AppKit, which inserts the newline for us.
        func handle(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 36, 76: // Return, Enter
                if flags.contains(.shift) { return false }
                return parent.onKey(flags.contains(.command) ? .commandReturn : .returnKey)
            case 53: // Escape
                return parent.onKey(.escape)
            case 125: // Down
                return parent.onKey(.down)
            case 126: // Up
                return parent.onKey(.up)
            case 48: // Tab
                return parent.onKey(.tab)
            default:
                return false
            }
        }

        /// Measures what the text actually occupies and clamps it to the growth window. Reported
        /// asynchronously because this runs inside a SwiftUI update and must not write state back
        /// into the same pass.
        func reportHeight(of textView: ComposerTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            // Before the first layout pass the view has no width, and text wrapped to nothing
            // measures as one line per word. Measuring then would open the box at full height.
            guard textView.bounds.width > 1 else { return }

            layout.ensureLayout(for: container)

            let line = layout.defaultLineHeight(for: textView.font ?? ComposerTextEditor.font)
            let used = layout.usedRect(for: container).height
            let minimum = CGFloat(parent.minLines) * line
            let maximum = CGFloat(parent.maxLines) * line
            let height = min(max(used, minimum), maximum).rounded(.up)

            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            let report = parent.onHeightChange
            DispatchQueue.main.async { report(height) }
        }
    }
}

/// An `NSTextView` that offers each key press to the composer before typing it, and says when it
/// was resized or focused so the SwiftUI side can keep up.
final class ComposerTextView: NSTextView {
    var keyHandler: (@MainActor (NSEvent) -> Bool)?
    var onWidthChange: (@MainActor () -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onWidthChange?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// Without this the window's default button, or the field editor's own cancel handling, can
    /// swallow Escape before `keyDown` ever sees it.
    override func cancelOperation(_ sender: Any?) {
        // Handled in keyDown. Overridden so AppKit does not beep.
    }
}
