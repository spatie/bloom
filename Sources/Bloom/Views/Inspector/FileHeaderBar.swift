import SwiftUI
import AppKit
import BloomCore

/// The bar above a file: which file it is, whether it has been reviewed, and every choice that
/// applies to this file rather than to the workspace.
///
/// The layout choice and the whitespace choice are bound straight to the same defaults keys the
/// inspector's own toolbar uses, so there is one source of truth per setting and no way for two
/// controls to disagree about what the diff is showing.
///
/// The control cluster collapses into a menu when the pane is too narrow for it. A segmented
/// control and a row of toggle buttons do not truncate: they overflow and get clipped, which is
/// how a control ends up half visible at the edge of a narrow inspector.
struct FileHeaderBar: View {
    let model: WorkspaceModel
    let file: ChangedFile
    let session: FileEditSession
    /// The parsed patch, for the share text. Nil while it is still being read.
    var diff: FileDiff?
    @Binding var mode: FileViewMode
    /// Absent when the file cannot be edited: binary, gone, or too large to open.
    var isEditable: Bool
    var onRevert: () -> Void

    @AppStorage(DiffLayoutSetting.storageKey) private var isSideBySide = false
    @AppStorage(DiffWhitespaceSetting.storageKey) private var ignoresWhitespace = false

    @State private var isConfirmingRevert = false
    @State private var didCopy = false
    @State private var copyReset: Task<Void, Never>?
    /// The bar's own width, which is the only thing that can decide whether the folder chip has
    /// room. `ViewThatFits` cannot: it is handed the share of the row the layout has already
    /// apportioned, so it dropped the folder while there was still most of a pane to spare.
    @State private var width: CGFloat = 0

    /// Whether this file is holding unsaved edits. Read where the dialog below is built, never
    /// from `body`: see `UnsavedEditsDot` for what reading it here used to cost.
    private var isDirty: Bool { session.isDirty(absolutePath) }

    private var absolutePath: String {
        (model.workspace.path as NSString).appendingPathComponent(file.path)
    }

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            FilePathChip(
                file: file,
                session: session,
                absolutePath: absolutePath,
                showsDirectory: FileBarLayout.showsDirectory(width: width)
            )

            // Lower priority than the name beside it, so a wide bar spends its slack on
            // the gap rather than on squeezing the path chip that has room to spare.
            Spacer(minLength: InspectorLayout.tight)
                .layoutPriority(-1)

            ViewThatFits(in: .horizontal) {
                controls(compact: false)
                controls(compact: true)
                collapsed
            }
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .confirmationDialog(
            "Revert \(file.filename)?",
            isPresented: $isConfirmingRevert,
            titleVisibility: .visible
        ) {
            Button("Revert and lose those changes", role: .destructive, action: onRevert)
            // Escape keeps the changes. See the archive confirmation in `RootView` for why the
            // destructive answer is never the default one and why the cancel button carries no
            // shortcut of its own.
            Button("Keep the changes", role: .cancel) {}
        } message: {
            // Naming what disappears, rather than asking "are you sure?", the way archiving a
            // workspace does.
            Text(FileRevert.losses(for: file, in: model.workspace, hasDraft: isDirty))
        }
        .onDisappear { copyReset?.cancel() }
    }

    // MARK: - Control clusters

    private func controls(compact: Bool) -> some View {
        HStack(spacing: InspectorLayout.gap) {
            viewedToggle(compact: compact)
            revertButton
            layoutPicker
            whitespaceToggle
            copyButton
            shareButton
            modePicker
        }
    }

    /// The narrow arrangement: what this file is, and everything else behind an overflow menu.
    private var collapsed: some View {
        HStack(spacing: InspectorLayout.gap) {
            viewedToggle(compact: true)
            Menu {
                Picker("Layout", selection: $isSideBySide) {
                    Text("Unified").tag(false)
                    Text("Side by side").tag(true)
                }
                .pickerStyle(.inline)
                Toggle("Ignore whitespace", isOn: $ignoresWhitespace)
                Divider()
                Button(copyTitle, action: copy)
                // A `Text` label rather than a title string, because the `.labelStyle(.iconOnly)`
                // below reaches this menu's contents too and would leave the item a bare glyph.
                ShareLink(item: sharedDiff, preview: SharePreview(file.filename)) {
                    Text("Share the diff")
                }
                Button("Revert file", role: .destructive) { isConfirmingRevert = true }
            } label: {
                Label("More for this file", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("More for this file")

            modePicker
        }
    }

    private func viewedToggle(compact: Bool) -> some View {
        ViewedToggle(workspaceID: model.workspace.id, path: file.path, compact: compact)
            // The key is built when the property wrapper is, so the toggle has to be a new view
            // whenever the file changes or it would keep writing to the previous file's key.
            .id("\(model.workspace.id)/\(file.path)")
    }

    /// Destructive, the way the collapsed arrangement already draws it.
    ///
    /// It was a plain `.accessoryBar` glyph, identical in weight to Copy beside it, so the one
    /// control in this bar that throws work away looked exactly like the one that puts it on the
    /// pasteboard. The overflow menu at `collapsed` marks the same action `role: .destructive` and
    /// always has; a bar and its own overflow saying two different things about one action is the
    /// disagreement, not the styling.
    private var revertButton: some View {
        Button(role: .destructive) {
            isConfirmingRevert = true
        } label: {
            Label("Revert file", systemImage: "arrow.uturn.backward")
        }
        .labelStyle(.iconOnly)
        .inspectorBarControl()
        .help("Throw away the changes to \(file.filename)")
    }

    /// Unified or side by side, which is one choice between two values and is therefore a
    /// `Picker`.
    ///
    /// It was two `.toggleStyle(.button)` toggles joined by a hand written inverting `Binding`, so
    /// the one exclusive choice in this bar was the only control in it not drawn as a choice: two
    /// buttons that happen never to be on together. The collapsed arrangement above already draws
    /// it as an inline `Picker`, and `modePicker` two controls along is a segmented one, so this
    /// bar held all three spellings of the same idea.
    ///
    /// `Image` rather than `Label` in the segments: a segmented control on macOS is an
    /// `NSSegmentedControl`, whose cells carry a title or an image and not both, which
    /// `CreateWorkspaceSheet.modePicker` records having found out the hard way.
    private var layoutPicker: some View {
        Picker("Diff layout", selection: $isSideBySide) {
            Image(systemName: "list.bullet.rectangle")
                .accessibilityLabel("Unified diff")
                .tag(false)
            Image(systemName: "rectangle.split.2x1")
                .accessibilityLabel("Side by side diff")
                .tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(mode == .edit)
        .help("Show the diff as one column or side by side")
    }

    private var whitespaceToggle: some View {
        Toggle(isOn: $ignoresWhitespace) {
            Label("Ignore whitespace", systemImage: "paragraphsign")
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .inspectorBarControl()
        .disabled(mode == .edit)
        .help(
            ignoresWhitespace
                ? "Show whitespace-only changes again"
                : "Hide changes that are only whitespace"
        )
    }

    private var copyButton: some View {
        Button(copyTitle, systemImage: didCopy ? "checkmark" : "doc.on.doc", action: copy)
            .labelStyle(.iconOnly)
            .inspectorBarControl()
            .help(copyTitle)
    }

    /// Beside the copy button, because they are the same family: one puts the diff where you paste
    /// it yourself, the other hands it to whatever you were going to paste it into.
    private var shareButton: some View {
        ShareLink(item: sharedDiff, preview: SharePreview(file.filename)) {
            Label("Share the diff", systemImage: "square.and.arrow.up")
        }
        .labelStyle(.iconOnly)
        .inspectorBarControl()
        .help("Share the diff for \(file.filename)")
    }

    /// What both share controls hand over. The patch is only rendered into a message on export,
    /// which is what keeps a four thousand line diff out of every redraw of this bar. See
    /// `SharedDiff`.
    private var sharedDiff: SharedDiff {
        SharedDiff(file: file, diff: diff)
    }

    private var copyTitle: String {
        mode == .edit ? "Copy the file" : "Copy the diff"
    }

    private var modePicker: some View {
        Picker("File view", selection: $mode) {
            ForEach(FileViewMode.allCases, id: \.self) { value in
                Text(value.rawValue).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(!isEditable && mode == .diff)
        .help(
            isEditable
                ? "Switch between the diff and the file"
                : "\(file.filename) cannot be edited here"
        )
    }

    // MARK: - Actions

    private func copy() {
        Task {
            let text: String? = mode == .edit
                ? session.draft(for: absolutePath)?.text
                : await model.patch(for: file)
            guard let text, !text.isEmpty else { return }

            Clipboard.copy(text)

            didCopy = true
            copyReset?.cancel()
            copyReset = Task {
                try? await Task.sleep(for: Clipboard.flashDuration)
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        }
    }
}
