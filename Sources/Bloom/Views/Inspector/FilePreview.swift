import SwiftUI
import BloomCore

/// A file the agent did not touch: its source, highlighted with the same primitives the diff
/// uses, and the same file editable.
///
/// The View / Edit pair is the whole point of the bar. Every route into a changed file gets
/// `FileHeaderBar`, which names both of its states in words; a file git has nothing to say about
/// used to get this bar, which named neither, and offered no way into the editor at all. The one
/// control it did carry was a `square.and.pencil` menu that hands the file to Zed or VS Code, so
/// the only glyph in the bar meant "edit somewhere else" while there was no way to edit here.
struct FilePreview: View {
    let model: WorkspaceModel
    let path: String

    /// Far more than fits on a screen, and enough that scrolling never reaches the truncation on
    /// any file a person would open on purpose.
    private static let lineLimit = 5_000
    /// A horizontal scroll wider than this helps nobody and makes the scroller useless.
    private static let columnLimit = 800
    /// The same cap `FilePathChip` puts on the folder above a diff.
    private static let chipWidth: CGFloat = 170

    /// Below this the bar keeps the filename and the controls and drops the folder beside it.
    /// The same rule and the same number as `FileHeaderBar`, so the two bars give the folder up at
    /// the same pane width rather than a few points apart.
    private static let folderThreshold: CGFloat = 340

    @State private var lines: [String] = []
    @State private var carries: [LexState] = []
    @State private var language: Language = .plainText
    @State private var maxColumns = 0
    @State private var isTruncated = false
    @State private var isLoading = true
    @State private var isEditing = false
    /// False until the first read says otherwise: binary, missing and oversized files have no
    /// editor to offer, and offering one that refuses is worse than not offering it.
    @State private var isEditable = false
    /// The bar's own width, for the same reason `FileHeaderBar` measures its own: `ViewThatFits`
    /// only ever sees the share of the row the layout has already apportioned.
    @State private var width: CGFloat = 0

    /// Editing buffers outlive this view, so flipping back to View, walking to the next file or
    /// switching workspace cannot discard what was typed.
    private let session = FileEditSession.shared

    /// Opens on the file, unless there is unsaved text for it, in which case it opens on the
    /// editor. `DiffView` seeds its own mode the same way and for the same reason: coming back to
    /// a file you were typing in and finding the read only half is indistinguishable from finding
    /// the typing gone.
    init(model: WorkspaceModel, path: String) {
        self.model = model
        self.path = path
        let absolute = (model.workspace.path as NSString).appendingPathComponent(path)
        _isEditing = State(initialValue: FileEditSession.shared.isDirty(absolute))
    }

    private struct LoadID: Hashable {
        var workspaceID: String
        var path: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            Group {
                if isEditing {
                    FileEditPane(model: model, path: path, session: session) {
                        // The read-only half is a snapshot of the bytes at load time, so a save
                        // leaves it a version behind. Re-read rather than left to be noticed.
                        Task { await load() }
                    }
                } else if isLoading {
                    LoadingView("Reading the file")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty {
                    EmptyStateView(
                        glyph: "doc",
                        title: "Nothing to show",
                        message: "\(filename) is empty, or is not text."
                    )
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
        .background { shortcut }
        .task(id: LoadID(workspaceID: model.workspace.id, path: path)) { await load() }
        .onChange(of: isEditable) { _, editable in
            if !editable { isEditing = false }
        }
    }

    /// Cmd+E, the same key `DiffView` binds to the same choice, so one keystroke means "the other
    /// half of this bar" whichever kind of file is open. A hidden button rather than a menu
    /// command, for the reason spelled out in `SessionTabsView`: the menu bar is built elsewhere,
    /// and a key equivalent is only offered to the menu bar and to the view hierarchy.
    private var shortcut: some View {
        Button("Toggle View and Edit") {
            guard isEditable else { return }
            isEditing.toggle()
        }
        .keyboardShortcut("e", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// The same bar `DiffView` puts over a changed file, so clicking through the worktree tree
    /// does not land the reader in an unlabelled wall of code. It says less because there is less
    /// to say: nothing here has a diff, a revert or two layouts to choose between.
    private var header: some View {
        HStack(spacing: InspectorLayout.gap) {
            if width >= Self.folderThreshold, !directory.isEmpty {
                Chip(text: directory)
                    .frame(maxWidth: Self.chipWidth, alignment: .leading)
                    .layoutPriority(-1)
            }

            Text(filename)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            // The same dot `FilePathChip` puts after a changed file's name, because Edit mode
            // holds its text in `FileEditSession` rather than on this view: switching to View,
            // to another file or to another workspace keeps the typing, and the dot is the only
            // thing that says so.
            if isDirty {
                Circle()
                    .fill(Palette.accent)
                    .frame(width: Metrics.dot, height: Metrics.dot)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }

            Spacer(minLength: InspectorLayout.tight)

            openInMenu
            modePicker
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .help(path)
    }

    /// A menu with a primary action: clicking it opens the file in whatever this project was last
    /// opened in, holding it offers everywhere else. The one control does both, which is what
    /// keeps a bar this narrow from growing a second button.
    ///
    /// `arrow.up.forward.app` rather than `square.and.pencil`. The pencil is the mark this
    /// platform puts on "edit this, here", and beside a control whose other half literally is
    /// that, a second pencil meaning "edit it in another application" would be the ambiguity the
    /// bar just got rid of. An arrow leaving a window is what macOS draws for handing something
    /// to somewhere else.
    private var openInMenu: some View {
        Menu {
            OpenInItems(target: .file(absolutePath))
        } label: {
            Label(openTitle, systemImage: "arrow.up.forward.app")
        } primaryAction: {
            openInPreferredApp()
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .help(openTitle)
        .environment(\.openInRepoID, model.repo?.id)
    }

    /// Two segments that both say what they are, rather than one glyph that toggles.
    ///
    /// A segmented control because that is what this app already uses for a small mode choice in
    /// exactly this row: the Diff / Edit pair in `FileHeaderBar` beside it, and the inspector's own
    /// tab row. It is also the only shape that shows the state you are in AND the state you can
    /// reach at the same time, which a button labelled with the other state cannot: "Edit" on a
    /// button is a promise, and on a segment it is a place.
    ///
    /// Disabled rather than hidden when the file cannot be edited, so the answer to "why can I not
    /// edit this one" is on the control itself instead of being a missing thing to notice.
    private var modePicker: some View {
        Picker("File view", selection: $isEditing) {
            Text("View").tag(false)
            Text("Edit").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(!isEditable)
        .help(
            isEditable
                ? "Read \(filename), or edit it here"
                : "\(filename) cannot be edited here. It is not UTF-8 text, or it is over "
                    + "\(FileEditor.sizeLimit / 1_048_576) MB."
        )
    }

    private var isDirty: Bool { session.isDirty(absolutePath) }

    private var filename: String { (path as NSString).lastPathComponent }

    private var absolutePath: String {
        (model.workspace.path as NSString).appendingPathComponent(path)
    }

    /// Names the application, so the button says what it will do before it is pressed.
    private var openTitle: String {
        guard let app = OpenIn.preferred(for: .file(absolutePath), repo: model.repo?.id)
        else { return "Open \(filename) in your editor" }
        return "Open \(filename) in \(app.app.name)"
    }

    private func openInPreferredApp() {
        guard let app = OpenIn.preferred(for: .file(absolutePath), repo: model.repo?.id) else {
            Reveal.inEditor(absolutePath)
            return
        }
        OpenIn.open(absolutePath, with: app, repo: model.repo?.id)
    }

    private var directory: String { (path as NSString).deletingLastPathComponent }

    /// `GeometryReader` because the sheet has to be at least as wide as the container AND at least
    /// as wide as the longest line, and there is no container-relative modifier that expresses a
    /// maximum of the two.
    private var content: some View {
        GeometryReader { proxy in
            let width = max(
                proxy.size.width,
                CGFloat(maxColumns) * CodeMetrics.advance
                    + CodeMetrics.numberWidth
                    + CodeMetrics.textInset
                    + CodeMetrics.gutterPadding * 2
            )
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        row(at: index, width: width)
                    }
                    if isTruncated {
                        Text("Showing the first \(Self.lineLimit.formatted()) lines")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(InspectorLayout.inset)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
            // As in `DiffView`: two axes centre content that does not fill the pane.
            .defaultScrollAnchor(.topLeading)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func row(at index: Int, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("\(index + 1)")
                .font(Typo.codeTiny)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .frame(width: CodeMetrics.numberWidth, alignment: .trailing)
                .padding(.trailing, CodeMetrics.gutterPadding)
                .background(Palette.diffGutter)
            CodeText(
                line: lines[index],
                language: language,
                carry: index < carries.count ? carries[index] : LexState()
            )
            // The diff pays for this with its marker column. Without it here the first character
            // of every line sits against the gutter's edge, and the width computed above already
            // reserves the room.
            .padding(.leading, CodeMetrics.textInset)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
    }

    private func load() async {
        isLoading = true

        // Whether Edit mode is offered at all is a question about the bytes on disk, not about
        // what this view manages to highlight, so it is asked once here and off the main thread.
        // Same call and same answer as `DiffView`, so the two bars never disagree about whether a
        // file can be edited.
        let absolute = absolutePath
        isEditable = await Task.detached(priority: .utility) {
            FileEditor.isEditable(absolute)
        }.value

        guard !Task.isCancelled else { return }

        let source = model.contents(of: path)
        let detected = Language.detect(path: path)

        guard let source else {
            lines = []
            isLoading = false
            return
        }

        let all = source.components(separatedBy: "\n")
        let truncated = all.count > Self.lineLimit
        let kept = truncated ? Array(all.prefix(Self.lineLimit)) : all

        let states = await Task.detached(priority: .userInitiated) {
            CarryPass.states(for: kept, language: detected)
        }.value

        guard !Task.isCancelled else { return }
        lines = kept
        carries = states
        language = detected
        isTruncated = truncated
        maxColumns = min(kept.reduce(0) { max($0, CodeMetrics.columns(of: $1)) }, Self.columnLimit)
        isLoading = false
    }
}
