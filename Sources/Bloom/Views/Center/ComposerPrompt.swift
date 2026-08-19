import SwiftUI
import AppKit
import BloomCore

/// The prompt surface: the box, what is attached, what is being typed, the completion menus over
/// it, and whatever footer the caller puts under it.
///
/// This is the whole of "the composer" as a thing you can put somewhere. It was pulled out of
/// `ComposerView` when the create sheet became a composer rather than a form, because creating a
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
    /// conversation, a draft id in the create sheet.
    var attachmentKey: String

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
    /// The footer, handed the action behind its paperclip. Passed in rather than reached for,
    /// because everything an attachment does lives here and the footer is only the button.
    @ViewBuilder var footer: (@escaping @MainActor () -> Void) -> Footer

    @Environment(AppModel.self) private var app

    /// The chip the pointer has settled on, which is the card that is up. Nil is the resting
    /// state, and so is a chip that has since been removed or sent.
    @State private var previewed: PromptAttachment?
    /// Whether a drag is currently over the box, so the border can say it will be taken.
    @State private var isDropTarget = false
    /// How wide the box is, which is all the hover card is allowed to be.
    @State private var boxWidth: CGFloat = 0

    @State private var slashCatalog = SlashCommandCatalog()
    @State private var fileMatches: [FileMatch] = []
    @State private var menuIndex = 0
    @State private var isMenuDismissed = false

    private var attachments: [PromptAttachment] {
        PromptAttachmentStore.shared.attachments(for: attachmentKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            if !attachments.isEmpty {
                AttachmentBar(
                    attachments: attachments,
                    worktree: attachmentRoot,
                    onOpen: open(attachment:),
                    onRemove: remove(attachment:),
                    onHover: { previewed = $0 }
                )
            }

            ComposerEditor(
                text: $text,
                caret: $caret,
                isFocused: $isFocused,
                height: editorHeight,
                onContentHeightChange: onContentHeightChange,
                onKey: handle(key:),
                onAttach: attach(sources:),
                placeholder: placeholder
            )

            footer(attachFiles)
        }
        .composerBox(isFocused: $isFocused, isDropTarget: isDropTarget)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
        // The editor takes the drops that land on the text itself; this takes the ones that land
        // on the chips, the footer and the padding, which is most of the box.
        .dropDestination(for: URL.self) { urls, _ in
            attach(sources: urls.filter(\.isFileURL).map { .file($0) })
        } isTargeted: { isDropTarget = $0 }
        .overlay(alignment: .topLeading) {
            // Above the composer, in the same place and the same card as the two completion
            // menus, and never at the same time as one of them: they would sit on top of each
            // other, and a menu the user is typing into outranks a preview they are only looking
            // at.
            AttachmentCardOverlay(
                attachment: activeMenu == .none ? livePreview : nil,
                worktree: attachmentRoot,
                availableWidth: boxWidth
            )
            .alignmentGuide(.top) { $0[.bottom] + Metrics.spacing }
        }
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
        .onAppear { PromptAttachmentStore.shared.load(sessionID: attachmentKey) }
        .task(id: mentionRoot) { await slashCatalog.load(workspacePath: mentionRoot) }
        .task(id: activeMenu.mention?.query) { await refreshFileMatches() }
        .onChange(of: text) { _, _ in menuIndex = 0 }
        .onChange(of: menu) { old, new in
            menuIndex = 0
            // Escape only dismisses the menu that was open. Starting a different one, or clearing
            // the token entirely, makes the menu available again.
            if old.kind != new.kind { isMenuDismissed = false }
        }
    }

    // MARK: - Derived state

    /// The hover card, once it has been checked against what is still attached. A chip that was
    /// removed, or that went with the turn, takes its card with it without anything having to
    /// remember to put it away.
    private var livePreview: PromptAttachment? {
        guard let previewed, attachments.contains(previewed) else { return nil }
        return previewed
    }

    /// What the text alone asks for, before Escape gets a say.
    private var menu: ComposerMenu {
        ComposerMenu.resolve(draft: text, caret: caret)
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
        let paths = await FileIndex.shared.files(workspacePath: mentionRoot)
        let query = token.query
        // Off the main actor: a large repository has tens of thousands of tracked files and this
        // runs on every keystroke after the `@`.
        fileMatches = await Task.detached(priority: .userInitiated) {
            FileMatch.search(paths, query: query, limit: 200)
        }.value
    }

    private func pick(command: SlashCommand) {
        let replacement = "/\(command.name) "
        text = replacement
        caret = (replacement as NSString).length
        isFocused = true
    }

    private func pick(file: FileMatch) {
        guard let token = activeMenu.mention else { return }
        let replacement = "@\(file.path) "
        let updated = NSMutableString(string: text)
        updated.replaceCharacters(
            in: NSRange(location: token.start, length: token.length),
            with: replacement
        )
        text = updated as String
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
    /// Returns true because two of those callers are AppKit asking "did you take this", and an
    /// answer of no is what makes a drop fall through to the text system and write a path into the
    /// draft again.
    @discardableResult
    private func attach(sources: [AttachmentSource]) -> Bool {
        guard !sources.isEmpty else { return false }
        Task { await add(sources) }
        return true
    }

    private func add(_ sources: [AttachmentSource]) async {
        let failures = await PromptAttachmentStore.shared.add(
            sources,
            sessionID: attachmentKey,
            workspace: attachmentRoot
        )
        isFocused = true
        guard !failures.isEmpty else { return }
        app.alert = BloomAlert(
            title: failures.count == 1 ? "That file was not attached" : "Some files were not attached",
            message: failures.joined(separator: "\n\n")
        )
    }

    private func open(attachment: PromptAttachment) {
        previewed = nil
        onOpenAttachment(attachment)
    }

    private func remove(attachment: PromptAttachment) {
        previewed = nil
        PromptAttachmentStore.shared.remove(
            attachment,
            sessionID: attachmentKey,
            workspace: attachmentRoot
        )
    }

    private func attachFiles() {
        Task { await pickFiles() }
    }

    /// A sheet rather than an application-modal panel: `runModal()` stops the run loop, which stops
    /// every other workspace's transcript from streaming for as long as the picker is open.
    private func pickFiles() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // Files only. A folder has nothing to preview, nothing to open and no honest size, and
        // `@mention` already says "this directory" without pretending it is one attachment.
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: mentionRoot)

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK else { return }

        await add(panel.urls.map { .file($0) })
    }
}
