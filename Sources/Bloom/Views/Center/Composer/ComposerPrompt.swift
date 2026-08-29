import SwiftUI
import AppKit
import BloomCore

/// The prompt surface: the box, what is attached, what is being typed, the completion menus over
/// it, and whatever footer the caller puts under it.
///
/// This is the whole of "the composer" as a thing you can put somewhere. It was pulled out of
/// `ComposerView` when the create window became a composer rather than a form, because creating a
/// workspace is writing the first message of a conversation and it should be the same surface as
/// writing the second: the same chrome, the same drop target, the same `@mention` and `/command`
/// menus, the same paperclip, the same hover cards. Copying that into a sheet would have been two
/// composers to keep in step, which is exactly how the two would have drifted.
///
/// What it does not own is the draft. The text, the caret and the footer belong to the caller,
/// because in a conversation they belong to a transcript and in the sheet they belong to a
/// workspace that does not exist yet, and neither one is this view's business.
///
/// Two roots rather than one, and they are the same string in a conversation but not in the sheet:
/// `mentionRoot` is the checkout whose files `@` offers and whose `/commands` are found, and
/// `attachmentRoot` is where an attached file is copied to. In the sheet the first is the
/// repository and the second is a staging directory, because the worktree the agent will stand in
/// has not been cut yet.
struct ComposerPrompt<Footer: View>: View {
    @Binding var text: String
    @Binding var caret: Int
    @Binding var isFocused: Bool

    /// The checkout `@mentions` and `/commands` are resolved against.
    var mentionRoot: String
    /// Where an attached file is copied to, and what its stored path is relative to.
    var attachmentRoot: String
    /// Which bucket of `PromptAttachmentStore` this prompt is filling: a session id in a
    /// conversation, a draft id in the create window.
    var attachmentKey: String

    /// The review comments riding with the next message, drawn as chips above the text the way
    /// the `/command` chip is. Only a conversation has any: the create window has no diff to have
    /// commented on, so its default stays empty and nothing about the sheet changes.
    var reviewComments: [ReviewComment] = []
    var onRemoveReviewComment: @MainActor (ReviewCommentID) -> Void = { _ in }
    var onOpenReviewComment: @MainActor (ReviewComment) -> Void = { _ in }

    var placeholder: String = ComposerEditor.chatPlaceholder
    /// What to draw the editor at, already clamped by the caller, which is the one place that can
    /// reconcile the text's own height with a divider the user may have dragged.
    var editorHeight: CGFloat
    var onContentHeightChange: @MainActor (CGFloat) -> Void
    /// The keys no open menu has a claim on. Return, Command+Return and Escape reach the caller,
    /// which is what lets the same box send a turn in one place and create a workspace in another.
    var onKey: @MainActor (ComposerKey) -> Bool
    /// What clicking a chip does. A conversation opens the file in its review tab; the sheet has
    /// no tabs to open one in and hands it to the Finder instead.
    var onOpenAttachment: @MainActor (PromptAttachment) -> Void
    var fillsPanel = false
    /// The footer, handed what it can ask this view to write into the draft. Passed in rather than
    /// reached for, because everything an attachment and a quick prompt do lives here and the
    /// footer is only the buttons. See `ComposerPromptActions`.
    @ViewBuilder var footer: (ComposerPromptActions) -> Footer

    @Environment(AppModel.self) private var app

    /// The chip the pointer has settled on, which is the card that is up. Nil is the resting
    /// state, and so is a chip that has since been edited out of the draft.
    @State private var hoveredPath: String?
    /// Whether a drag is currently over the box, so the border can say it will be taken.
    @State private var isDropTarget = false
    /// How wide the box is, which is all the hover card is allowed to be.
    @State private var boxWidth: CGFloat = 0
    /// How far the box is from the top of the window it is in, which is all the room a card that
    /// floats above it has. A sheet is its own window, so this is the sheet's own top edge there.
    @State private var boxTop: CGFloat = 0
    /// How tall the window's content is, which with `boxTop` says how much room a menu that opens
    /// downwards would have. Infinity until the probe reports, which resolves to the upward
    /// placement every composer had before there was a choice to make.
    @State private var windowHeight: CGFloat = .infinity

    /// The way into the text view for a file that has finished copying, so it arrives as an edit
    /// the text system can undo rather than as a draft replaced behind its back.
    @State private var editor = ComposerEditorHandle()

    /// The `/command` list for the checkout this composer points at.
    ///
    /// Swapped for the shared one in the task below rather than owned. A composer that owned its
    /// catalogue re-scanned six directories every time the centre column changed tab, because the
    /// pane and everything in it is built again on the way back. This starts as an empty one so
    /// there is something to read on the pass before that task runs. See
    /// `SlashCommandCatalog.shared(for:)`.
    @State private var slashCatalog = SlashCommandCatalog()
    /// Whether the pointer has settled on the command chip, which is what puts its card up.
    @State private var isCommandPreviewed = false
    @State private var fileMatches: [FileMatch] = []
    @State private var menuIndex = 0
    @State private var isMenuDismissed = false

    private var attachments: [PromptAttachment] {
        PromptAttachmentStore.shared.attachments(for: attachmentKey)
    }

    var body: some View {
        // Everything derived from the draft, worked out once at the top and threaded down.
        //
        // Both of these parse the whole draft. `SlashCommandDraft.parse` splits the leading
        // `/command` off the prompt, and `ComposerMenu.resolve` takes the text before the caret
        // and the token around it, which is three `NSString` copies of the draft per call. They
        // were computed properties, and this body read them about fourteen times between the chip,
        // the drop target, the three floating overlays, the placement rule they share and the four
        // task ids underneath, on every keystroke.
        //
        // The local is named `draft` rather than `command` deliberately: the drop closure below
        // reads `command.body` when a file is let go, which must be the draft as it is THEN and
        // not as it was when this pass ran.
        let draft = command
        let menu = ComposerMenu.resolve(draft: draft.body, caret: caret)
        // Escape only takes down the menu that was open. See `activeMenu`.
        let openMenu = isMenuDismissed ? ComposerMenu.none : menu
        // One lookup for the chip and its hover card, which are the same command.
        let named = draft.name.flatMap { slashCatalog.command(named: $0) }
        let attachments = self.attachments
        // Shared by all three floating panels, so the menus and the hover cards cannot end up on
        // different sides of the same box.
        let typedLineBottom = typedLineBottom(hasCommand: draft.name != nil)
        let placement = menuPlacement(typedLineBottom: typedLineBottom)
        let guide = floatingGuide(isBelow: placement.isBelow, typedLineBottom: typedLineBottom)

        return VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            if !reviewComments.isEmpty {
                ChipFlow(spacing: Metrics.spacingSmall, lineSpacing: Metrics.spacingSmall) {
                    ForEach(reviewComments) { comment in
                        ReviewCommentChip(
                            comment: comment,
                            onRemove: { onRemoveReviewComment(comment.id) },
                            onOpen: { onOpenReviewComment(comment) }
                        )
                    }
                }
            }

            if let name = draft.name {
                HStack(alignment: .top, spacing: Metrics.spacingSmall) {
                    SlashCommandChip(
                        name: name,
                        command: named,
                        onRemove: removeCommand,
                        onHover: { isCommandPreviewed = $0 }
                    )

                    promptEditor(attachments: attachments)
                }
            } else {
                promptEditor(attachments: attachments)
            }

            footer(ComposerPromptActions(attach: attachFiles, insert: insert(quickPrompt:)))
        }
        .composerBox(
            isFocused: $isFocused,
            isDropTarget: isDropTarget,
            fillsPanel: fillsPanel
        )
        // Publish this from the shared prompt rather than individual screens. This keeps prose
        // editing shortcuts, including Command-Backspace, inside every prompt editor.
        .focusedValue(\.isTypingProse, isFocused)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            boxWidth = frame.width
            boxTop = frame.minY
        }
        // Global space says where the box is in its window and nothing about where the window
        // ends, and the completion menus need both. See the placement rule on `menuPlacement`.
        .background { WindowHeightReader { windowHeight = $0 } }
        // The editor takes the drops that land on the text itself; this takes the ones that land
        // on the chips, the footer and the padding, which is most of the box.
        // A drop on the chrome has no character under it, so it goes to the end of the draft,
        // which is where the next word would have been typed.
        .dropDestination(for: URL.self) { urls, _ in
            attach(
                sources: urls.filter(\.isFileURL).map { .file($0) },
                replacing: NSRange(location: (command.body as NSString).length, length: 0)
            )
        } isTargeted: { isDropTarget = $0 }
        .overlay(alignment: .topLeading) {
            // In the same place and the same card as the two completion menus, and never at the
            // same time as one of them: they would sit on top of each other, and a menu the user
            // is typing into outranks a preview they are only looking at.
            AttachmentCardOverlay(
                attachment: openMenu == .none
                    ? hoveredAttachment(in: draft, among: attachments)
                    : nil,
                worktree: attachmentRoot,
                availableWidth: boxWidth
            )
            .alignmentGuide(.top, computeValue: guide)
        }
        .overlay(alignment: .topLeading) {
            // Same place, same card, same rule as the attachment preview: a menu the user is
            // typing into outranks anything they are only looking at.
            SlashCommandCardOverlay(
                name: openMenu == .none && isCommandPreviewed ? draft.name : nil,
                command: named,
                availableWidth: boxWidth,
                availableHeight: placement.room
            )
            .alignmentGuide(.top, computeValue: guide)
        }
        .overlay(alignment: .topLeading) {
            ComposerMenuOverlay(
                menu: openMenu,
                commands: slashResults(in: openMenu),
                commandsAreLoaded: slashCatalog.isLoaded,
                files: fileMatches,
                selectedIndex: menuIndex,
                maxHeight: placement.menuHeight,
                availableWidth: boxWidth,
                onPickCommand: pick(command:),
                onPickFile: pick(file:),
                onHighlight: { menuIndex = $0 }
            )
            .alignmentGuide(.top, computeValue: guide)
        }
        // Keyed on the session rather than run on first appearance, because this view is not built
        // again for each one. An unsplit centre column is now the same pane in every workspace, so
        // a composer that read its staged attachments in `onAppear` would read the first session's
        // and then draw them under every session the window visited afterwards. See
        // `CenterPanesView.soloPane`.
        .task(id: attachmentKey) {
            PromptAttachmentStore.shared.load(sessionID: attachmentKey)
            adoptAttachmentsKeptBesideTheDraft()
            applyCaptureDraft()
            applyCaptureAttachments()
        }
        .task(id: mentionRoot) {
            let catalog = SlashCommandCatalog.shared(for: mentionRoot)
            slashCatalog = catalog
            await catalog.load(workspacePath: mentionRoot)
        }
        // Opening the menu is the only moment a stale list can be seen, so it is the only moment
        // worth re-reading one. A skill written in another window while Bloom stayed open is in
        // the list by the time the user has finished typing the slash.
        .task(id: openMenu.kind == .slash) {
            guard openMenu.kind == .slash else { return }
            await slashCatalog.refreshIfStale(workspacePath: mentionRoot)
        }
        .task(id: openMenu.mention?.query) { await refreshFileMatches() }
        .onChange(of: text) { _, _ in menuIndex = 0 }
        .onChange(of: menu) { old, new in
            menuIndex = 0
            // Escape only dismisses the menu that was open. Starting a different one, or clearing
            // the token entirely, makes the menu available again.
            if old.kind != new.kind { isMenuDismissed = false }
        }
    }

    /// The command is a prefix of the prompt rather than a separate row. Keeping the editor in
    /// one helper lets the chipped and ordinary forms share exactly the same text behaviour while
    /// the chipped form can place it immediately after the command.
    private func promptEditor(attachments: [PromptAttachment]) -> some View {
        ComposerEditor(
            text: promptBody,
            caret: $caret,
            isFocused: $isFocused,
            height: editorHeight,
            onContentHeightChange: onContentHeightChange,
            onKey: handle(key:),
            onBackspaceAtStart: backspaceCommand,
            onAttach: attach(sources:replacing:),
            attachmentPaths: attachments.map(\.path),
            onOpenAttachment: open(path:),
            onHoverAttachment: { hoveredPath = $0 },
            handle: editor,
            placeholder: placeholder
        )
    }

    /// Files that were attached before a file was a word in the draft.
    ///
    /// A draft saved by an earlier build has its attachments in a list beside it and no mention of
    /// them in the text, which would now read as a prompt carrying nothing: the chips would be
    /// gone and the paths would never reach the agent. Any of them the draft does not already name
    /// is written onto the end of it, once, which is where they were drawn before.
    private func adoptAttachmentsKeptBesideTheDraft() {
        let held = attachments.map(\.path)
        guard !held.isEmpty else { return }

        var draft = command
        let named = Set(AttachmentDraft.parse(draft.body, paths: held).paths)
        let missing = held.filter { !named.contains($0) }
        guard !missing.isEmpty else { return }

        let written = AttachmentDraft.inserting(
            missing, into: draft.body, at: (draft.body as NSString).length
        )
        draft.body = written.text
        text = draft.text
        caret = written.caret
    }

    /// `--composer-draft "/revi"` fills the box on first appearance, and `--composer-preview`
    /// raises the command chip's hover card with it.
    ///
    /// A completion menu is the one part of the composer a still of the window cannot otherwise
    /// show: it only exists while something is half typed, and the capture run has no keyboard.
    /// Debug builds only, for the same reason `--running` is: a shipped copy has no business
    /// putting words in the user's draft.
    private func applyCaptureDraft() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--composer-draft"), index + 1 < arguments.count,
              text.isEmpty else { return }
        text = arguments[index + 1]
        caret = (SlashCommandDraft.parse(text).body as NSString).length
        isFocused = true
        // `--composer-preview` raises the command chip's card, which otherwise only a pointer
        // resting on the chip can do, and a capture run has no pointer either.
        isCommandPreviewed = arguments.contains("--composer-preview")
        #endif
    }

    /// `--composer-attach <file>[,<file>] [--composer-caret <offset>]` attaches real files to the
    /// draft on first appearance, at that offset, through exactly the door a drop uses.
    ///
    /// The only way to look at what a dropped file does to the box without a pointer, and the only
    /// way to read the sentence that comes out of it without a keyboard. It copies for real, into
    /// the real shielded folder, and writes the paths into the draft through the same
    /// `attach(sources:replacing:)` a drag, a paste and the paperclip go through, so what a capture
    /// shows is what a drop does. The draft it produces is printed, because the picture shows the
    /// chip and the point of the chip is the sentence underneath it.
    ///
    /// Debug builds only, for the same reason `--composer-draft` is: a shipped copy has no
    /// business writing files into somebody's checkout because of a command line flag.
    private func applyCaptureAttachments() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--composer-attach"),
              index + 1 < arguments.count else { return }

        let files = arguments[index + 1]
            .split(separator: ",")
            .map { AttachmentSource.file(URL(filePath: String($0))) }
        let at = arguments.firstIndex(of: "--composer-caret")
            .map { $0 + 1 }
            .flatMap { $0 < arguments.count ? Int(arguments[$0]) : nil } ?? caret

        Task {
            // After the draft this session was holding has been read back, or the file would be
            // dropped into an empty box that is about to be filled from the database.
            try? await Task.sleep(for: .seconds(2))
            await add(files, replacing: NSRange(location: at, length: 0))
            print("[composer-draft] \(text)")
        }
        #endif
    }

    // MARK: - Derived state

    /// The hover card, once it has been checked against what the draft still says. A file that was
    /// typed out of the sentence, or that went with the turn, takes its card with it without
    /// anything having to remember to put it away.
    ///
    /// Handed the draft and the records the caller has already read, because the body has both to
    /// hand and parsing the draft a second time to answer a question about the pointer is the cost
    /// this whole pass was written to stop paying.
    private func hoveredAttachment(
        in draft: SlashCommandDraft, among attachments: [PromptAttachment]
    ) -> PromptAttachment? {
        guard let hoveredPath else { return nil }
        let files = AttachmentDraft.parse(draft.body, paths: attachments.map(\.path))
        guard files.paths.contains(hoveredPath) else { return nil }
        return attachment(for: hoveredPath, among: attachments)
    }

    /// What is known about one of the paths in the draft. A path with no record beside it is
    /// still a file: it is drawn, opened and sent from the path alone, which is what makes a
    /// restored draft work when nothing else survived the relaunch.
    private func attachment(
        for path: String, among attachments: [PromptAttachment]
    ) -> PromptAttachment {
        attachments.first { $0.path == path } ?? .sent(path: path)
    }

    /// The draft, split into the command it leads with and the prompt written after it.
    ///
    /// Derived rather than stored. Nothing here remembers that a chip is up, so nothing can
    /// disagree with the draft about whether one should be, and `command.text` is byte for byte
    /// the string that gets sent. See `SlashCommandDraft`.
    private var command: SlashCommandDraft {
        SlashCommandDraft.parse(text)
    }

    /// What the editor is actually editing: everything except the leading `/command`, which is
    /// drawn as a chip above instead. Writes go back through the split, so the literal text keeps
    /// its command however the prompt under it is edited.
    private var promptBody: Binding<String> {
        Binding {
            SlashCommandDraft.parse(text).body
        } set: { edited in
            var draft = SlashCommandDraft.parse(text)
            draft.body = edited
            text = draft.text
        }
    }

    /// What the text alone asks for, before Escape gets a say.
    ///
    /// Resolved against the body rather than the whole draft, because the chip is not text any
    /// more: with `/review ` already picked, a `@` in the prompt is a mention and a second `/` is
    /// a new command, and both are measured from where the editor's own caret is. Both are also
    /// found anywhere in the body, not only at its start, so completion is offered for the `/rev`
    /// of "do a /rev of this" exactly as it is for the `@Sou` of "look at @Sou".
    private var menu: ComposerMenu {
        ComposerMenu.resolve(draft: command.body, caret: caret)
    }

    private var activeMenu: ComposerMenu {
        isMenuDismissed ? .none : menu
    }

    private var isMenuOpen: Bool { activeMenu != .none }

    /// Only scored while the slash menu is actually on screen, so a keystroke in an ordinary draft
    /// costs nothing.
    private func slashResults(in menu: ComposerMenu) -> [SlashCommandMatch] {
        guard let token = menu.slash else { return [] }
        return slashCatalog.matches(token.query)
    }

    private var menuCount: Int {
        switch activeMenu {
        case .slash: slashResults(in: activeMenu).count
        case .mention: fileMatches.count
        case .none: 0
        }
    }

    /// Which side of the box the floating panels open on, and how much room that side has.
    ///
    /// In a conversation the composer sits at the foot of the window and the room above it is the
    /// whole transcript, so this resolves to `above` and nothing moves. In the create window the
    /// box sits under one heading in a window sized exactly to its content, and a menu that
    /// opened upwards there was clipped at the sheet's top edge: two arbitrary rows survived, the
    /// ranked ones, the selected one among them, were cut off, and the header controls were
    /// covered by what was left. See `MenuLayout.placement` for the rule.
    private func menuPlacement(typedLineBottom: CGFloat) -> MenuLayout.Placement {
        MenuLayout.placement(
            above: boxTop - Metrics.spacing * 2,
            below: windowHeight - boxTop - typedLineBottom - Metrics.spacing * 2
        )
    }

    /// How far under the box's top edge the line being typed ends: the box's own padding, the
    /// chip strip when the draft leads with a command, and one line of text. A panel that opens
    /// downwards starts here, so the token being completed stays visible above it. A caret on a
    /// later line of a long draft can end up under the panel, and both menus can now be opened
    /// there, since a slash completes anywhere it begins a word. The filtering each menu does is
    /// the feedback for what is being typed, so a covered caret costs the reader nothing.
    private func typedLineBottom(hasCommand: Bool) -> CGFloat {
        Metrics.gutter
            + (hasCommand ? AttachmentChip.height + Metrics.spacingWide : 0)
            + ComposerTextEditor.lineHeight
    }

    /// The one `.top` guide all three floating panels share, so the menus and the hover cards
    /// cannot end up on different sides of the same box. Above: the panel's bottom hangs a step
    /// over the box. Below: the panel's top hangs a step under the line being typed.
    ///
    /// A closure built here rather than a method passed by name, because `alignmentGuide` runs
    /// its closure during layout, off the main actor, and a main actor method cannot go there.
    /// The two numbers can: they are read while the body is being built.
    private func floatingGuide(
        isBelow: Bool, typedLineBottom: CGFloat
    ) -> @Sendable (ViewDimensions) -> CGFloat {
        let drop = typedLineBottom + Metrics.spacing
        return { isBelow ? -drop : $0[.bottom] + Metrics.spacing }
    }

    // MARK: - Completion

    private func refreshFileMatches() async {
        guard let token = activeMenu.mention else {
            fileMatches = []
            return
        }
        let paths = await FileIndex.shared.files(workspacePath: mentionRoot)
        let query = token.query
        // Off the main actor: a large repository has tens of thousands of tracked files and this
        // runs on every keystroke after the `@`.
        fileMatches = await Task.detached(priority: .userInitiated) {
            FileMatch.search(paths, query: query, limit: 200)
        }.value
    }

    /// Accepting a row replaces the token the menu was opened on, and only that token.
    ///
    /// Which is the whole prompt when the slash began it, and one word of a sentence when it did
    /// not. `SlashCommandDraft.picking` owns both shapes; this writes the answer back.
    private func pick(command picked: SlashCommand) {
        guard let token = activeMenu.slash else { return }
        let insertion = command.picking(command: picked.name, token: token)
        text = insertion.draft.text
        caret = insertion.caret
        isFocused = true
    }

    /// Takes the command off and leaves the prompt written after it exactly as it was.
    private func removeCommand() {
        let draft = command
        text = draft.removingCommand().text
        caret = 0
        isCommandPreviewed = false
        isFocused = true
    }

    /// Backspace at the very start of the prompt, where the thing to the left of the caret is the
    /// chip. See `SlashCommandDraft.backspacingCommand`.
    private func backspaceCommand() -> Bool {
        let draft = command
        guard let after = draft.backspacingCommand() else { return false }
        text = after.text
        caret = draft.caretAfterBackspace
        isCommandPreviewed = false
        return true
    }

    /// A quick prompt written into the draft where the caret is. Nothing here sends it: see
    /// `ComposerPromptActions.insert` for who decides that and `QuickPromptDelivery` for the rule.
    ///
    /// Written into the body rather than into the whole draft, exactly as a picked file is: the
    /// caret the composer holds counts from the start of the prompt written after any `/command`,
    /// and writing it back through the split is what keeps the command intact.
    private func insert(quickPrompt: QuickPrompt) {
        var draft = command
        let insertion = QuickPromptInsertion.inserting(quickPrompt, into: draft.body, at: caret)
        draft.body = insertion.text
        text = draft.text
        caret = insertion.caret
        isFocused = true
    }

    private func pick(file: FileMatch) {
        guard let token = activeMenu.mention else { return }
        let replacement = "@\(file.path) "
        var draft = command
        // Measured against the body, which is what the token was found in and what the editor's
        // caret counts from. Writing it back through the split is what keeps the command intact.
        let updated = NSMutableString(string: draft.body)
        updated.replaceCharacters(
            in: NSRange(location: token.start, length: token.length),
            with: replacement
        )
        draft.body = updated as String
        text = draft.text
        caret = token.start + (replacement as NSString).length
        isFocused = true
    }

    private func pickHighlighted() {
        switch activeMenu {
        case .slash:
            let results = slashResults(in: activeMenu)
            guard results.indices.contains(menuIndex) else { return }
            pick(command: results[menuIndex].command)
        case .mention:
            guard fileMatches.indices.contains(menuIndex) else { return }
            pick(file: fileMatches[menuIndex])
        case .none:
            break
        }
    }

    // MARK: - Keys

    /// Returns true when the key was consumed, which is how the text view knows not to type it.
    ///
    /// An open menu answers first, because the arrow keys and Return belong to the menu while it is
    /// up. Everything else goes to the caller, which is the only thing that knows what Return is
    /// for here.
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
                return onKey(key)
            }
        }

        // A menu with nothing in it still swallows Escape, so dismissing an empty result list does
        // not also drop focus or close the sheet the box is sitting in.
        if key == .escape, isMenuOpen {
            isMenuDismissed = true
            return true
        }

        return onKey(key)
    }

    // MARK: - Attachments

    /// The one way a file becomes an attachment, whichever door it came through: the paperclip, a
    /// drag onto the box, a drag onto the text, or the clipboard.
    ///
    /// `replacing` is where it goes. A drop carries the character the pointer let go over, so the
    /// file lands on the word it was dropped on; a paste carries the selection, so it replaces
    /// what was selected exactly as pasting anything else does. Both are measured in the draft the
    /// editor is editing, which is the prompt written after any `/command`.
    ///
    /// Returns true because two of those callers are AppKit asking "did you take this", and an
    /// answer of no is what makes a drop fall through to the text system and write a path into the
    /// draft as a sentence about the file instead of attaching it.
    @discardableResult
    private func attach(sources: [AttachmentSource], replacing range: NSRange) -> Bool {
        guard !sources.isEmpty else { return false }
        Task { await add(sources, replacing: range) }
        return true
    }

    private func add(_ sources: [AttachmentSource], replacing range: NSRange) async {
        let added = await PromptAttachmentStore.shared.add(
            sources,
            sessionID: attachmentKey,
            workspace: attachmentRoot
        )
        write(added.paths, replacing: range)
        isFocused = true
        guard !added.failures.isEmpty else { return }
        app.alert = BloomAlert(
            title: added.failures.count == 1
                ? "That file was not attached"
                : "Some files were not attached",
            message: added.failures.joined(separator: "\n\n")
        )
    }

    /// Writes the files into the draft where they were put, and leaves the caret after them.
    ///
    /// Clamped rather than trusted: copying a large file takes long enough that the sentence can
    /// have moved on underneath it, and a stale offset is a reason to land at the end of what is
    /// there now rather than to trap.
    private func write(_ paths: [String], replacing range: NSRange) {
        guard !paths.isEmpty else { return }
        // Through the editor where there is one holding this draft, so Command+Z takes the file
        // back out in order with the words typed around it. The write below is the same edit made
        // without the text system, which is what happens when the copy outlived the box it was
        // dropped into or the draft moved on while it ran.
        var draft = command
        guard !editor.insert(paths, replacing: range, into: draft.body) else { return }

        let body = draft.body as NSString
        let start = min(max(range.location, 0), body.length)
        let length = min(max(range.length, 0), body.length - start)
        let cleared = body.replacingCharacters(in: NSRange(location: start, length: length), with: "")

        let written = AttachmentDraft.inserting(paths, into: cleared, at: start)
        draft.body = written.text
        text = draft.text
        caret = written.caret
    }

    private func open(path: String) {
        hoveredPath = nil
        onOpenAttachment(attachment(for: path, among: attachments))
    }

    private func attachFiles() {
        Task { await pickFiles() }
    }

    /// A sheet rather than an application-modal panel, for the reason `NSSavePanel.present`
    /// gives: `runModal()` stops the run loop, which stops every other workspace's transcript from
    /// streaming for as long as the picker is open.
    private func pickFiles() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // Files only. A folder has nothing to preview, nothing to open and no honest size, and
        // `@mention` already says "this directory" without pretending it is one attachment.
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: mentionRoot)

        guard await panel.present() == .OK else { return }

        // The paperclip has no pointer and no drop point, so the file goes where the writing is:
        // at the caret, over the selection if there is one.
        await add(panel.urls.map { .file($0) }, replacing: NSRange(location: caret, length: 0))
    }
}
