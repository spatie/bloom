import SwiftUI
import AppKit
import BatonCore

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

    /// Below this the bar keeps the filename and the controls and drops the folder beside it.
    /// A readable filename, the collapsed control cluster and the pane's own insets, with just
    /// enough left for a folder worth reading.
    private static let folderThreshold: CGFloat = 340

    private var isDirty: Bool { session.isDirty(absolutePath) }

    private var absolutePath: String {
        (model.workspace.path as NSString).appendingPathComponent(file.path)
    }

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            FilePathChip(
                file: file,
                hasUnsavedEdits: isDirty,
                showsDirectory: width >= Self.folderThreshold
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
            layoutToggles
            whitespaceToggle
            copyButton
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

    private var revertButton: some View {
        Button("Revert file", systemImage: "arrow.uturn.backward") {
            isConfirmingRevert = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Throw away the changes to \(file.filename)")
    }

    private var layoutToggles: some View {
        HStack(spacing: Metrics.spacingTight) {
            Toggle(isOn: unified) {
                Label("Unified diff", systemImage: "list.bullet.rectangle")
            }
            .help("Show the diff as one column")

            Toggle(isOn: $isSideBySide) {
                Label("Side by side diff", systemImage: "rectangle.split.2x1")
            }
            .help("Show the diff side by side")
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .controlSize(.small)
        .disabled(mode == .edit)
    }

    /// The two layout buttons are one choice, so the unified one writes the same storage rather
    /// than keeping a second flag that could disagree with it.
    private var unified: Binding<Bool> {
        Binding(get: { !isSideBySide }, set: { isSideBySide = !$0 })
    }

    private var whitespaceToggle: some View {
        Toggle(isOn: $ignoresWhitespace) {
            Label("Ignore whitespace", systemImage: "paragraphsign")
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .controlSize(.small)
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
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(copyTitle)
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

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

            didCopy = true
            copyReset?.cancel()
            copyReset = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        }
    }
}
