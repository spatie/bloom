import SwiftUI
import AppKit
import BloomCore

/// The bar above a file: which file it is, and every choice that applies to this file rather than
/// to the workspace.
///
/// The layout choice and the whitespace choice are bound straight to the same defaults keys the
/// inspector's own toolbar uses, so there is one source of truth per setting and no way for two
/// controls to disagree about what the diff is showing.
///
/// # The controls say what they are
///
/// **Reported by somebody reading a Bloom diff for the first time: this row is a line of glyphs
/// and there is no telling what any of them do.** Six icon-only controls, and the only thing that
/// explained them was a system tooltip about a second and a half away. Both halves of that are
/// answered here and neither of them touches the tooltip delay, which is a setting the person
/// using this Mac owns for every application on it.
///
/// The first answer is the words. `controls` draws each control with its title beside its glyph,
/// and it is the arrangement `ViewThatFits` offers first, so at any ordinary width nothing has to
/// be hovered at all. `compact` is the old glyph row and is what a narrower pane falls back to,
/// and `collapsed` is the overflow menu under that.
///
/// The second is the hint. Every control reports its own sentence into `hint` on hover, and the
/// bar draws it in the slack beside the controls, at once, because a line of text in a row is not
/// a tooltip and has no delay to wait out. See `FileBarHint`.
///
/// The copy is `FileBarControls` in the core rather than string literals here, for the reason that
/// file gives: the one string that was built inline said "Copy the diff" while the pane was
/// showing the file.
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
    var isCollapsed = false
    var onToggleCollapsed: (() -> Void)?

    @AppStorage(DiffLayoutSetting.storageKey) private var isSideBySide = false
    @AppStorage(DiffWhitespaceSetting.storageKey) private var ignoresWhitespace = false

    @State private var isConfirmingRevert = false
    @State private var didCopy = false
    @State private var copyReset: Task<Void, Never>?
    /// The sentence for whichever control the pointer is over, or nil for none of them. Written by
    /// `fileBarHint` and read only here. See `FileBarHint` for why this is not a tooltip.
    @State private var hint: String?
    /// The bar's own width, which is the only thing that can decide how much of the path there is
    /// room for. `ViewThatFits` cannot: it is handed the share of the row the layout has already
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
            if let onToggleCollapsed {
                Button(action: onToggleCollapsed) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(isCollapsed ? "Expand" : "Collapse") \(file.filename)")
                .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(file.filename)")
            }
            FilePathLabel(path: file.path, width: width)

            // Whether Edit mode is holding changes that are not on disk yet. Asked by
            // `UnsavedEditsDot` rather than answered here, so a keystroke invalidates the dot
            // instead of the bar it sits in.
            UnsavedEditsDot(session: session, path: absolutePath)

            // Lower priority than the name beside it, so a wide bar spends its slack on
            // the gap rather than on squeezing the path that has room to spare.
            Spacer(minLength: InspectorLayout.tight)
                .layoutPriority(-1)

            // Between the spacer and the controls, so the sentence appears next to the control it
            // is about, and lower priority than everything else in the row so it is the first
            // thing to give up width.
            //
            // **Always in the row, empty when there is nothing to say.** An `if` here would take
            // the view out of the stack, and a stack with one child fewer is a stack with one gap
            // fewer: the eight points that frees go back to the controls, and a bar sitting on the
            // boundary between two of `ViewThatFits`'s arrangements would swap them as the pointer
            // arrived. The controls have to be the one thing in this bar that never moves while
            // it is being pointed at.
            if onToggleCollapsed != nil {
                reviewControls
            } else {
                FileBarHintLabel(text: hint ?? "")
                    .layoutPriority(-2)

                ViewThatFits(in: .horizontal) {
                    controls
                    compact
                    collapsed
                }
            }
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: onToggleCollapsed == nil ? InspectorLayout.barHeight : InspectorLayout.reviewHeaderHeight)
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

    /// The one that is offered first: every control with its word on it.
    ///
    /// It costs about two hundred points over the glyph row below, which is what the reviewer's
    /// complaint is worth paying: at the widths the review tab actually opens at, this is what is
    /// drawn, and nothing in the row has to be hovered to find out what it is.
    private var controls: some View {
        HStack(spacing: InspectorLayout.gap) {
            viewedToggle(labelled: true)
            revertButton(labelled: true)
            layoutPicker(labelled: true)
            if mode == .diff {
                whitespaceToggle(labelled: true)
            }
            copyButton(labelled: true)
            modePicker
        }
    }

    /// All-files review owns the layout settings. Keep each file's identity and progress
    /// visible, with less frequent and destructive actions in its menu.
    private var reviewControls: some View {
        HStack(spacing: InspectorLayout.gap) {
            if !file.isBinary {
                HStack(spacing: 4) {
                    Text("+\(file.additions)").foregroundStyle(Palette.positive)
                    Text("−\(file.deletions)").foregroundStyle(Palette.negative)
                }
                .font(Typo.caption)
                .monospacedDigit()
                .fixedSize()
                .accessibilityLabel("\(file.additions) additions, \(file.deletions) deletions")
            }
            ViewThatFits(in: .horizontal) {
                viewedToggle(labelled: true)
                viewedToggle(labelled: false)
            }
            Menu {
                if isEditable {
                    Button(mode == .diff ? "Edit file" : "Show diff") {
                        if isCollapsed { onToggleCollapsed?() }
                        mode = mode == .diff ? .edit : .diff
                    }
                }
                Button(FileBarControls.copy(mode: mode).title, action: copy)
                Divider()
                Button(FileBarControls.revert(filename: file.filename).title, role: .destructive) {
                    isConfirmingRevert = true
                }
            } label: {
                Label("File actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("File actions")
        }
    }

    /// The same controls with their words dropped, for a pane too narrow to carry them.
    ///
    /// This is the row as it shipped, and it is a middle rung rather than the top one now. Every
    /// control in it still answers on hover through `fileBarHint`, which is the half of the fix
    /// that this arrangement needs and the wide one above does not.
    private var compact: some View {
        HStack(spacing: InspectorLayout.gap) {
            viewedToggle(labelled: false)
            revertButton(labelled: false)
            layoutPicker(labelled: false)
            if mode == .diff {
                whitespaceToggle(labelled: false)
            }
            copyButton(labelled: false)
            modePicker
        }
    }

    /// The narrow arrangement: what this file is, and everything else behind an overflow menu.
    private var collapsed: some View {
        HStack(spacing: InspectorLayout.gap) {
            overflowMenu
            modePicker
        }
    }

    /// File controls for a bar too narrow to show them inline.
    private var overflowMenu: some View {
        Menu {
            Toggle("Viewed", isOn: Binding(
                get: { model.isViewed(file) },
                set: { value in Task { await model.setViewed(value, file: file) } }
            ))
            Divider()
            Picker(FileBarControls.layout.title, selection: $isSideBySide) {
                Text(FileBarControls.unified).tag(false)
                Text(FileBarControls.sideBySide).tag(true)
            }
            .pickerStyle(.inline)
            if mode == .diff {
                Toggle(FileBarControls.whitespace(ignoring: ignoresWhitespace).title,
                       isOn: $ignoresWhitespace)
            }
            Divider()
            Button(FileBarControls.copy(mode: mode).title, action: copy)
            Button(FileBarControls.revert(filename: file.filename).title, role: .destructive) {
                isConfirmingRevert = true
            }
        } label: {
            Label(FileBarControls.more.title, systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .fileBarHint(FileBarControls.more, into: $hint)
    }

    private func viewedToggle(labelled: Bool) -> some View {
        ViewedToggle(model: model, file: file)
            .fileBarLabelStyle(labelled: labelled)
            .fileBarHint(FileBarControl(
                title: "Viewed", hint: ReviewedMarkAction(isViewed: model.isViewed(file)).help(for: file.filename)
            ), into: $hint)
    }

    /// Destructive, the way the collapsed arrangement already draws it.
    ///
    /// It was a plain `.accessoryBar` glyph, identical in weight to Copy beside it, so the one
    /// control in this bar that throws work away looked exactly like the one that puts it on the
    /// pasteboard. The overflow menu at `collapsed` marks the same action `role: .destructive` and
    /// always has; a bar and its own overflow saying two different things about one action is the
    /// disagreement, not the styling.
    private func revertButton(labelled: Bool) -> some View {
        let control = FileBarControls.revert(filename: file.filename)
        return Button(role: .destructive) {
            isConfirmingRevert = true
        } label: {
            Label(control.title, systemImage: "arrow.uturn.backward")
        }
        .fileBarLabelStyle(labelled: labelled)
        .inspectorBarControl()
        .fileBarHint(control, into: $hint)
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
    /// `Image` rather than `Label` in the narrow segments: a segmented control on macOS is an
    /// `NSSegmentedControl`, whose cells carry a title or an image and not both, which
    /// `CreateWorkspaceView.modePicker` records having found out the hard way. That limit is why
    /// the wide arrangement drops the glyphs rather than putting the words next to them.
    private func layoutPicker(labelled: Bool) -> some View {
        // Two whole pickers rather than one with a branch inside it. A `Picker` finds its
        // selection by reading the tags out of its content, and content wrapped in a
        // `_ConditionalContent` is content it has to walk into to find them. Neither branch has a
        // conditional in it this way, and the cost is a repeated title.
        Group {
            if labelled {
                Picker(FileBarControls.layout.title, selection: $isSideBySide) {
                    Text(FileBarControls.unified).tag(false)
                    Text(FileBarControls.sideBySide).tag(true)
                }
            } else {
                Picker(FileBarControls.layout.title, selection: $isSideBySide) {
                    Image(systemName: "list.bullet.rectangle")
                        .accessibilityLabel(FileBarControls.unified)
                        .tag(false)
                    Image(systemName: "rectangle.split.2x1")
                        .accessibilityLabel(FileBarControls.sideBySide)
                        .tag(true)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(mode == .edit)
        .fileBarHint(FileBarControls.layout, into: $hint)
    }

    private func whitespaceToggle(labelled: Bool) -> some View {
        let control = FileBarControls.whitespace(ignoring: ignoresWhitespace)
        return Toggle(isOn: $ignoresWhitespace) {
            Label(control.title, systemImage: "paragraphsign")
        }
        .fileBarLabelStyle(labelled: labelled)
        .toggleStyle(.button)
        .inspectorBarControl()
        .fileBarHint(control, into: $hint)
    }

    /// The glyph flashes to a tick after a press and the word does not change, which is the whole
    /// reason `FileBarControls.copy` keeps one title across both states: a button whose label
    /// grows or shrinks as it is pressed moves every control to the left of it while the pointer
    /// is still on the one that moved.
    ///
    /// What does say so in words is the hint, and it says so for free: the pointer is on this
    /// button at the moment of the press, so the sentence beside the controls turns into "The diff
    /// is on the clipboard" as the tick appears.
    private func copyButton(labelled: Bool) -> some View {
        let control = FileBarControls.copy(mode: mode, didCopy: didCopy)
        return Button(action: copy) {
            Label(control.title, systemImage: didCopy ? "checkmark" : "doc.on.doc")
        }
        .fileBarLabelStyle(labelled: labelled)
        .inspectorBarControl()
        .fileBarHint(control, into: $hint)
    }

    private var modePicker: some View {
        Picker(FileBarControls.mode(filename: file.filename, isEditable: isEditable).title,
               selection: $mode) {
            ForEach(FileViewMode.allCases, id: \.self) { value in
                Text(value.rawValue).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(!isEditable && mode == .diff)
        .fileBarHint(
            FileBarControls.mode(filename: file.filename, isEditable: isEditable), into: $hint
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

/// Whether a control in this bar wears its word or only its glyph.
///
/// A `@ViewBuilder` rather than a ternary over two label styles, because SwiftUI has no
/// `AnyLabelStyle` to put the two branches behind one type.
private extension View {
    @ViewBuilder
    func fileBarLabelStyle(labelled: Bool) -> some View {
        if labelled {
            labelStyle(.titleAndIcon)
        } else {
            labelStyle(.iconOnly)
        }
    }
}
