import SwiftUI
import BloomCore

/// Edit mode: the file itself, editable, with the save guard underneath it.
///
/// The bar along the bottom is not decoration. It is the only place the user finds out that a
/// save was refused because the agent had already rewritten the file, and the only way back from
/// that: reload, look at what the agent did, and redo the edit on top of it.
///
/// A path rather than a `ChangedFile`, because the two ways into a file are the diff of one the
/// agent touched and the worktree tree, and the tree opens files git has never heard of. Editing
/// is a question about bytes on disk either way, so the pane only ever needed the path.
struct FileEditPane<Model: WorkspacePaneModel>: View {
    let model: Model
    /// Relative to the workspace's worktree, the way every path in the inspector is.
    let path: String
    let session: FileEditSession
    /// Called after a save lands, for a pane whose other half is now showing stale text.
    var onSaved: () -> Void = {}
    var isEditable = true
    var absolutePathOverride: String?

    @Environment(\.colorScheme) private var colorScheme

    @State private var isConfirmingReload = false

    private var absolutePath: String {
        absolutePathOverride ?? (model.workspace.path as NSString).appendingPathComponent(path)
    }

    private var state: SourceEditorState { SourceEditorState.file(absolutePath) }
    @State private var comparing = false

    private var filename: String { (path as NSString).lastPathComponent }

    private var isDirty: Bool { session.isDirty(absolutePath) }

    var body: some View {
        Group {
            switch session.status(for: absolutePath) {
            case .loading:
                LoadingView("Reading the file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(reason):
                EmptyStateView(
                    glyph: "doc.badge.gearshape",
                    title: isEditable ? "Cannot edit this file" : "Cannot read this file",
                    message: reason
                )
            default:
                editor
            }
        }
        .background(Palette.surface)
        .focusedValue(\.saveAction, isEditable ? SaveAction(subject: absolutePath, isEnabled: isDirty && !session.saving.contains(absolutePath), perform: save) : nil)
        .focusedValue(\.isTypingProse, isEditable)
        .onDisappear { state.navigationTask?.cancel() }
        .confirmationDialog(
            "Discard your edits to \(filename)?",
            isPresented: $isConfirmingReload,
            titleVisibility: .visible
        ) {
            Button("Discard and reload", role: .destructive) {
                Task { await session.reload(path: absolutePath) }
            }
            // Escape keeps the edits. See the archive confirmation in `RootView` for why no
            // cancel button in this app carries `.keyboardShortcut(.defaultAction)`.
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The file on disk replaces what you typed. There is no undo for this.")
        }
        .task(id: absolutePath) {
            await session.load(path: absolutePath)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await session.refresh(path: absolutePath)
            }
        }
        .sheet(isPresented: $comparing) { comparison }
    }

    @ViewBuilder
    private var editor: some View {
        if session.draft(for: absolutePath) != nil {
            VStack(spacing: 0) {
                SourceTools(model: model, path: path, state: state)
                Hairline()
                SourceEditor(
                    text: session.binding(for: absolutePath),
                    language: state.languageOverride ?? Language.detect(path: path),
                    colorScheme: colorScheme,
                    isEditable: isEditable,
                    editorState: state,
                    onOpenReference: openReference,
                    onDefinition: findDefinition,
                    onReferences: findReferences,
                    onNavigateSymbol: navigateSymbol,
                    onAsk: askAboutSelection
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Hairline()
                if let message = state.message {
                    HStack {
                        Text(message).font(Typo.caption).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { state.message = nil }
                    }.padding(InspectorLayout.inset)
                }
                if session.diskVersions[absolutePath] != nil {
                    HStack {
                        Text("Changed on disk. Your edits are safe.").font(Typo.caption)
                        Spacer()
                        Button("Compare") { comparing = true }
                    }.padding(InspectorLayout.inset)
                }
                if isEditable { footer } else if case let .failed(reason) = session.status(for: absolutePath) {
                    Text(reason).font(Typo.caption).foregroundStyle(Palette.negative).padding(InspectorLayout.inset)
                }
            }
        } else {
            LoadingView("Reading the file")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var openReference: ((String, Int, Bool) -> Void)? {
        guard let local = model.localWorkspaceModel else { return nil }
        return { SourceActions.open($0, at: $1, path: path, model: local, state: state, newTab: $2) }
    }

    private var findDefinition: ((Int) -> Void)? {
        guard let local = model.localWorkspaceModel else { return nil }
        return { SourceActions.definition(at: $0, path: path, model: local, state: state) }
    }

    private var findReferences: ((Int) -> Void)? {
        guard let local = model.localWorkspaceModel else { return nil }
        return { SourceActions.references(at: $0, path: path, model: local, state: state) }
    }

    private var navigateSymbol: ((Int, Bool) -> Void)? {
        guard let local = model.localWorkspaceModel else { return nil }
        return { SourceActions.navigate(at: $0, path: path, model: local, state: state, newTab: $1) }
    }

    private var askAboutSelection: (() -> Void)? {
        guard let local = model.localWorkspaceModel else { return nil }
        return { SourceActions.ask(path: path, model: local, state: state) }
    }

    private var footer: some View {
        HStack(spacing: InspectorLayout.gap) {
            statusLabel

            Spacer(minLength: InspectorLayout.tight)

            if isDirty {
                Button("Discard") { isConfirmingReload = true }
                    .disabled(session.saving.contains(absolutePath))
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Throw away your unsaved edits and read the file again")
            }

            Button("Save", action: save)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || session.saving.contains(absolutePath))
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)

    }

    private var comparison: some View {
        VStack(spacing: Metrics.spacing) {
            Text("\(filename) changed on disk").font(Typo.bodyEmphasis)
            HSplitView {
                VStack {
                    Text("Your draft")
                    SourceEditor(text: session.binding(for: absolutePath),
                                 language: state.languageOverride ?? Language.detect(path: path), colorScheme: colorScheme)
                }
                VStack {
                    Text("Current file on disk")
                    SourceEditor(text: .constant(session.diskVersions[absolutePath]?.text ?? ""),
                                 language: state.languageOverride ?? Language.detect(path: path), colorScheme: colorScheme,
                                 isEditable: false)
                }
            }
            HStack {
                Button("Keep editing") { comparing = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use disk version") {
                    comparing = false
                    isConfirmingReload = true
                }
                Button("Save my version over disk") {
                    Task {
                        await session.keepDraftOverDisk(path: absolutePath)
                        if case .saved = session.status(for: absolutePath) {
                            comparing = false
                            model.forgetHeldDiff(for: path)
                            await model.reloadChanges()
                            onSaved()
                        }
                    }
                }
                .disabled(session.diskVersions[absolutePath] == nil || session.saving.contains(absolutePath))
            }
            if case let .failed(reason) = session.status(for: absolutePath) {
                Text(reason).foregroundStyle(Palette.negative).font(Typo.caption)
            }
        }.padding(Metrics.inset).frame(width: 950, height: 580)
    }

    /// A save changes the worktree, so the file list's counts and the diff behind this pane are
    /// both stale the moment it lands.
    private func save() {
        Task {
            await session.save(path: absolutePath)
            guard case .saved = session.status(for: absolutePath) else { return }
            // Including whatever the review pane is holding for this file, which is a picture of
            // the bytes that have just been replaced. See `WorkspaceModel.forgetHeldDiff`.
            model.forgetHeldDiff(for: path)
            await model.reloadChanges()
            onSaved()
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.status(for: absolutePath) {
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.caption)
                .foregroundStyle(Palette.negative)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .saved where !isDirty:
            Label("Saved", systemImage: "checkmark.circle")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        default:
            Text(isDirty ? "Unsaved changes" : "No changes")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}
