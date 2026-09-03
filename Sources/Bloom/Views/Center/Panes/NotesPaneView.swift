import SwiftUI
import BloomCore

/// The workspace's notes: one piece of scratch text, kept for as long as the workspace is.
///
/// It exists for the thing you notice at eleven at night and want the morning agent to fix. That
/// makes two things load bearing and everything else decoration. It has to still be there after the
/// app has been quit, which is why the text is a row in SQLite rather than anything this view owns.
/// And it must never send itself anywhere: the note reaches an agent only when the button below is
/// pressed, and even then it lands in the composer as a draft the user still has to read and send.
///
/// **What this view decides is nothing.** Where the text lives, when it is worth writing, what
/// counts as blank and what a note becomes on its way to the composer are all `WorkspaceNote` in
/// the core, where the tests can see them. What is left here is a text field, a save that is
/// scheduled, and a button.
struct NotesPaneView: View {
    @Bindable var model: WorkspaceModel

    @Environment(AppModel.self) private var app

    @State private var text = ""
    /// What the database is known to hold, so a save that would rewrite the same row is skipped.
    /// See `WorkspaceNote.needsSave`.
    @State private var saved = ""
    @State private var hasLoaded = false
    /// Set when the row could not be read, which keeps the editor disabled. Not a bool, because
    /// the pane has three states and a blank field is the wrong drawing of two of them.
    @State private var couldNotLoad = false
    /// Set when a write was refused, cleared by the write that succeeds.
    @State private var couldNotSave = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(spacing: 0) {
            editor
            Hairline()
            footer
        }
        .background(Palette.surface)
        .task {
            await load()
            // The caret, because this pane is one text field and nobody opens it to look at it.
            // It is reached by Shift+Cmd+N or by picking Notes out of the `+` menu, both of which
            // are somebody saying "I want to write this down"; without this the first sentence
            // they typed went nowhere and had to be typed again after a click.
            //
            // After `load`, and not in the same breath as it: the editor is `.disabled` until the
            // row has been read back, and focus does not stick to a disabled field. `hasLoaded` is
            // set inside `load`, so by here the field is live.
            isEditing = true
        }
        // The two moments the debounce is not enough on its own. Leaving the field is the ordinary
        // one; the pane going away covers switching tab, switching workspace and closing the tab,
        // all of which tear this view down while a scheduled save is still sleeping.
        .onChange(of: isEditing) { _, editing in if !editing { saveNow() } }
        // Command-Backspace is delete-to-start-of-line in every text box on macOS, and the
        // menu bar had it for Archive Workspace. See `FocusedValues.isTypingProse`.
        .focusedValue(\.isTypingProse, isEditing)
        .onDisappear(perform: saveNow)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .focused($isEditing)
            // The system hangs a Writing Tools button off a text view, and on an empty one it
            // lands at the view's leading edge outside the pane: the owner's report was a circle
            // floating half over the sidebar, attached to nothing he could name. `ComposerTextEditor`
            // turned it off for the same reason and records that there is no setting that keeps the
            // feature and loses the circle.
            //
            // The cost is smaller here than it looks. This box holds a line somebody wants to
            // remember about a workspace, and proofreading a note to yourself is not a job anybody
            // has wanted done.
            .writingToolsBehavior(.disabled)
            .font(Typo.body)
            .foregroundStyle(Palette.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.spacingWide)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { placeholder }
            .onChange(of: text) { _, _ in scheduleSave() }
            .disabled(!hasLoaded)
    }

    /// Drawn over the field rather than inside it, because `TextEditor` has no prompt of its own.
    /// Hit testing off, or the first click would land on the label instead of the caret.
    @ViewBuilder
    private var placeholder: some View {
        if couldNotLoad {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text(WorkspaceNote.unreadable)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: 380, alignment: .leading)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.bordered)
                    .font(Typo.label)
            }
            .padding(.horizontal, Metrics.inset + 5)
            .padding(.vertical, Metrics.spacingWide + 8)
        } else if hasLoaded, text.isEmpty {
            Text("Anything worth remembering about this workspace. It is never sent to the agent on its own.")
                .font(Typo.body)
                .foregroundStyle(Palette.textPlaceholder)
                .frame(maxWidth: 380, alignment: .leading)
                // Five points and eight on top of the field's own insets, which is where AppKit
                // puts the first glyph of a `TextEditor`. Measured against a typed character
                // rather than guessed, so the placeholder and the text it stands in for start in
                // the same place instead of a few points apart.
                .padding(.horizontal, Metrics.inset + 5)
                .padding(.vertical, Metrics.spacingWide + 8)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        HStack(spacing: Metrics.spacing) {
            // The one place the pane says whether the text is on disk, so a refused write has
            // somewhere to be seen. It used to say "Kept with this workspace" through a failure.
            Text(couldNotSave ? WorkspaceNote.unwritable : "Kept with this workspace")
                .font(Typo.caption)
                .foregroundStyle(couldNotSave ? Palette.warning : Palette.textSecondary)

            Spacer()

            // The one door from a pane into the next prompt, which is `ComposerHandoff` and
            // eventually `PromptAttachmentStore`. A second route into the composer is a second set
            // of rules about what a draft may contain.
            Button("Send to composer", systemImage: "arrow.turn.down.left", action: handOff)
                .buttonStyle(.accessoryBar)
                .font(Typo.label)
                .disabled(WorkspaceNote.handoff(text) == nil)
                .help("Puts this note at the end of the conversation's draft. It does not send it.")
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: Metrics.barHeight)
        .background(Palette.surfaceSunken)
    }

    // MARK: - Loading and saving

    /// Not `try?` and not `?? ""`. A refused read used to be indistinguishable from no note at
    /// all, so the pane showed a blank page over a real one and the first keystroke wrote the
    /// blank version over it. A missing row is still an empty note; a database that would not
    /// answer leaves the field disabled and says so.
    private func load() async {
        guard !hasLoaded, let store = model.store else { return }
        do {
            let stored = try await store.note(workspaceID: model.workspace.id)?.body ?? ""
            text = stored
            saved = stored
            couldNotLoad = false
            hasLoaded = true
        } catch {
            couldNotLoad = true
        }
    }

    /// Waits out the typing rather than writing on every keystroke, for the reasons written down on
    /// `WorkspaceNote.autosaveDelay`. The task is replaced on each keystroke, so the write happens
    /// once the user stops.
    private func scheduleSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: WorkspaceNote.autosaveDelay)
            guard !Task.isCancelled else { return }
            await write()
        }
    }

    /// The scheduled save brought forward, for a pane that is about to stop existing. Detached from
    /// the view's own lifetime on purpose: `onDisappear` runs as this view goes, so a `.task` of its
    /// would be cancelled before it wrote anything.
    private func saveNow() {
        saveTask?.cancel()
        guard hasLoaded, WorkspaceNote.needsSave(stored: saved, typed: text) else { return }
        guard let store = model.store else { return }
        let workspaceID = model.workspace.id
        let body = text
        // Detached, so `saved` is set from inside rather than out here. This view is usually gone
        // by the time the write lands, and a `saved` moved before the write is the same lie the
        // debounced path told.
        Task { @MainActor in
            do {
                try await store.saveNote(workspaceID: workspaceID, body: body)
                saved = body
                couldNotSave = false
            } catch {
                couldNotSave = true
            }
        }
    }

    /// `saved` moves only when the row actually took the text.
    ///
    /// It used to move whatever the write did, and `needsSave` compares against nothing else, so
    /// one refused write convinced this pane forever that the note was on disk: no further
    /// autosave fired, `saveNow` returned early, and the text existed only in `@State` until the
    /// pane went away. Left where it was, the next keystroke tries again.
    private func write() async {
        guard let store = model.store else { return }
        guard WorkspaceNote.needsSave(stored: saved, typed: text) else { return }
        let body = text
        do {
            try await store.saveNote(workspaceID: model.workspace.id, body: body)
            saved = body
            couldNotSave = false
        } catch {
            couldNotSave = true
        }
    }

    /// **It does not send the turn**, which is the same rule the browser's screenshot button
    /// follows. What lands in the composer is the note and a caret, and the user decides whether
    /// that is the prompt they meant.
    private func handOff() {
        guard let sentence = WorkspaceNote.handoff(text) else { return }
        Task {
            let outcome = await ComposerHandoff.write(sentence, to: model)
            guard let failure = outcome.failure else { return }
            app.alert = BloomAlert(title: "That note was not handed over", message: failure)
        }
    }
}
