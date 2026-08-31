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
    let absolutePathOverride: String?
    let canEditInBloom: Bool

    /// Far more than fits on a screen, and enough that scrolling never reaches the truncation on
    /// any file a person would open on purpose.
    private static let lineLimit = 5_000
    /// A horizontal scroll wider than this helps nobody and makes the scroller useless.
    private static let columnLimit = 800

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
    init(
        model: WorkspaceModel,
        path: String,
        absolutePathOverride: String? = nil,
        canEditInBloom: Bool = true
    ) {
        self.model = model
        self.path = path
        self.absolutePathOverride = absolutePathOverride
        self.canEditInBloom = canEditInBloom
        let absolute = absolutePathOverride
            ?? (model.workspace.path as NSString).appendingPathComponent(path)
        _isEditing = State(
            initialValue: canEditInBloom && FileEditSession.shared.isDirty(absolute)
        )
    }

    private struct LoadID: Hashable {
        var workspaceID: WorkspaceID
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
            // Top, for the reason `ReviewPaneView` gives where it holds this view: an unaligned
            // fill centres, and a short file centred in a tall pane reads as a layout accident.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            FilePathLabel(path: path, width: width)

            // The same dot `FileHeaderBar` puts after a changed file's name, because Edit mode
            // holds its text in `FileEditSession` rather than on this view: switching to View,
            // to another file or to another workspace keeps the typing, and the dot is the only
            // thing that says so.
            UnsavedEditsDot(session: session, path: absolutePath)

            Spacer(minLength: InspectorLayout.tight)

            openInMenu
            if canEditInBloom {
                modePicker
            }
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
    /// `OpenInAppItems` rather than `OpenInItems`, so the hold shows the applications themselves
    /// and not one submenu row holding them. This control already means "open in", which is what a
    /// context menu's submenu title has to say in words, and a menu whose only content is a
    /// submenu is a menu you have to open twice.
    ///
    /// `arrow.up.forward.app` rather than `square.and.pencil`. The pencil is the mark this
    /// platform puts on "edit this, here", and beside a control whose other half literally is
    /// that, a second pencil meaning "edit it in another application" would be the ambiguity the
    /// bar just got rid of. An arrow leaving a window is what macOS draws for handing something
    /// to somewhere else.
    private var openInMenu: some View {
        Menu {
            OpenInAppItems(target: .file(absolutePath))
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

    private var filename: String { (path as NSString).lastPathComponent }

    private var absolutePath: String {
        absolutePathOverride
            ?? (model.workspace.path as NSString).appendingPathComponent(path)
    }

    /// Names the application, so the button says what it will do before it is pressed.
    private var openTitle: String {
        guard let app = OpenIn.preferred(for: .file(absolutePath), repo: model.repo?.id)
        else { return "Open \(filename) in your editor" }
        return "Open \(filename) in \(app.app.name)"
    }

    /// One call, because `Reveal.inEditor` now asks `OpenIn.preferred` itself and records the
    /// choice the same way. This used to ask, open, and hand the miss to a second answer.
    private func openInPreferredApp() {
        Reveal.inEditor(absolutePath, repo: model.repo?.id)
    }

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
                    ForEach(runs, id: \.lowerBound) { range in
                        run(range, width: width)
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

    /// The file in blocks, so a selection can run across lines.
    ///
    /// **A file was a `Text` per line and could not be selected across two of them**, which is the
    /// same report the diff got on 0.20.0 and the same answer: sibling `Text`s are separate
    /// selection scopes on this system. Nothing here needs the diff's machinery, since a file that
    /// has not changed has no washes, no markers and no comment buttons, so it is a column of
    /// numbers beside one `CodeRunText`.
    ///
    /// Blocks rather than the whole file, through the same rule the diff groups by, because a run
    /// is one item in a lazy stack however many lines it holds and this pane will show five
    /// thousand of them.
    private var runs: [Range<Int>] {
        DiffRunGrouping.chunks(count: lines.count, isLine: { _ in true }).map { chunk in
            switch chunk {
            case let .single(index): index..<(index + 1)
            case let .run(range): range
            }
        }
    }

    /// No tint behind the numbers, for the reason `DiffGutter` gives: a grey column against the
    /// ground the code sits on draws a hard vertical edge down the left of the file, and a hard
    /// edge reads as a boundary between two things rather than as the margin of one. It also has
    /// to match, because Diff, Preview and Edit are three views of one file and this pane is the
    /// one you land in by clicking a file that has not changed.
    private func run(_ range: Range<Int>, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(range, id: \.self) { index in
                    Text("\(index + 1)")
                        .font(Typo.codeTiny)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: CodeMetrics.numberWidth, alignment: .trailing)
                        .padding(.trailing, CodeMetrics.gutterPadding)
                        // One fixed height cell per line, which is what the block of text beside
                        // this column is tuned to match. See `CodeMetrics.rowSpacing`.
                        .frame(height: CodeMetrics.rowHeight)
                }
            }
            CodeRunText(
                lines: range.map { index in
                    CodeRunLine(
                        text: lines[index],
                        carry: index < carries.count ? carries[index] : LexState()
                    )
                },
                language: language
            )
            // The diff pays for this with its marker column. Without it here the first character
            // of every line sits against the gutter's edge, and the width computed above already
            // reserves the room.
            .padding(.leading, CodeMetrics.textInset)
            Spacer(minLength: 0)
        }
        .frame(
            width: width,
            height: CodeMetrics.rowHeight * CGFloat(range.count),
            alignment: .leading
        )
    }

    private func load() async {
        isLoading = true

        // Whether Edit mode is offered at all is a question about the bytes on disk, not about
        // what this view manages to highlight, so it is asked once here and off the main thread.
        // Same call and same answer as `DiffView`, so the two bars never disagree about whether a
        // file can be edited.
        let absolute = absolutePath
        guard canEditInBloom else {
            isEditable = false
            return
        }
        isEditable = await Task.detached(priority: .utility) {
            FileEditor.isEditable(absolute)
        }.value

        guard !Task.isCancelled else { return }

        let detected = Language.detect(path: path)
        let lineLimit = Self.lineLimit
        let columnLimit = Self.columnLimit

        // Reading the file, splitting it and measuring its widest line all happen here, in one hop
        // and off the main actor. The read is the whole file off disk, the split walks all of it,
        // and the width is a per-character loop over up to five thousand lines: on a large file
        // that is the window held still for the length of all three. Only the carry pass used to
        // be moved off, and on a file with no lexer at all that is the one of the four that costs
        // nothing.
        let prepared = await Task.detached(priority: .userInitiated) { () -> Prepared? in
            guard let source = try? String(contentsOfFile: absolute, encoding: .utf8) else {
                return nil
            }
            let all = source.components(separatedBy: "\n")
            let truncated = all.count > lineLimit
            let kept = truncated ? Array(all.prefix(lineLimit)) : all
            return Prepared(
                lines: kept,
                carries: CarryPass.states(for: kept, language: detected),
                maxColumns: min(
                    kept.reduce(0) { max($0, CodeMetrics.columns(of: $1)) }, columnLimit
                ),
                isTruncated: truncated
            )
        }.value

        guard !Task.isCancelled else { return }

        guard let prepared else {
            lines = []
            isLoading = false
            return
        }

        lines = prepared.lines
        carries = prepared.carries
        language = detected
        isTruncated = prepared.isTruncated
        maxColumns = prepared.maxColumns
        isLoading = false
    }

    /// Everything the reader needs about a file, so the whole of the reading is one hop.
    private struct Prepared: Sendable {
        var lines: [String]
        var carries: [LexState]
        var maxColumns: Int
        var isTruncated: Bool
    }
}
