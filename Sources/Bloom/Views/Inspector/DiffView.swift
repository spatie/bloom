import SwiftUI
import BloomCore

/// One file, under a bar that says which file it is: the diff in either layout, or the file
/// itself, editable.
///
/// The bar lives here rather than in the panes above, because this is the one view every route to
/// a file goes through: the changes tab, the file tree and the review pane all end up in it, and a
/// header bar bolted onto each of them would be three bars to keep in step.
struct DiffView: View {
    let model: WorkspaceModel
    let file: ChangedFile

    /// Above this many changed lines the diff is gated behind a tap. Rendering is lazy and would
    /// survive it, but the preparation pass and the user's attention would both rather not.
    private static let largeDiffLimit = 5_000
    /// How much context a single tap on a between-hunks expander reveals.
    private static let gapStep = 24
    /// Context runs longer than this collapse to three lines at each end.
    private static let collapseThreshold = 8
    private static let keptContext = 3

    @AppStorage(DiffLayoutSetting.storageKey) private var isSideBySide = false
    @AppStorage(DiffWhitespaceSetting.storageKey) private var ignoresWhitespace = false

    @State private var phase: Phase = .loading
    @State private var rows: [DiffRow] = []
    @State private var expandedRuns: Set<Int> = []
    @State private var revealedGaps: [Int: Int] = [:]
    @State private var fileLines: [String]?

    /// Where every pending comment on this file draws, recomputed by `rebuild` so the bands and
    /// the rows they sit under always come from the same pass. See `ReviewPlacements`.
    @State private var placements: [ReviewPlacement] = []
    /// Which printed lines wear a comment or the open editor, for the row tint. Assigned in the
    /// same pass as `placements` above, which is the invariant that pass exists to hold. It was a
    /// computed property building a `Set` out of `placements`, and `isCommented` reads it once per
    /// rendered row and twice per row in the split layout, so the set was rebuilt from scratch for
    /// every line of the diff on every pass.
    @State private var commentedSpots: Set<ReviewSpot> = []
    /// Highlighting for the top of the diff, warmed off the main thread. Cancelled when another
    /// file is presented, because those lines are not the ones anybody is about to read. See
    /// `prime`.
    @State private var priming: Task<Void, Never>?
    /// The comment being written on this file, read through the model rather than held as view
    /// state, because everything that edits it outlives this view and this view does not: the
    /// editor row sits in a lazy stack and is destroyed when scrolled away, and the whole view is
    /// keyed by path in `ReviewPaneView` and destroyed by walking to another file. View state
    /// answered the first death and not the second; see `WorkspaceModel.reviewDrafts` for the
    /// fragment that committing on disappear minted instead.
    private var draft: ReviewDraft? { model.reviewDrafts[file.path] }
    private var draftSpot: ReviewSpot? { draft?.spot }

    /// The cancel waiting on an answer, or nil when nothing has been asked.
    ///
    /// Held by this view rather than by the band, because the confirmation is a sheet and the
    /// bands are rows in a lazy stack: a row scrolled away takes its sheet with it. That is the
    /// same reason `TranscriptListView` hangs the queued message question on the list instead of
    /// on the row it is about.
    @State private var discarding: PendingDiscard?

    /// The patch as git wrote it, kept so the whitespace toggle can refold it without going back
    /// to git for a diff it has already been given.
    @State private var source: FileDiff?
    @State private var mode: FileViewMode
    @State private var isEditable = false
    /// The file whose diff is on screen, which is not the same question as `file`.
    ///
    /// `file` is what this view has been asked for, and it changes before `load` runs. This is what
    /// `load` last finished, and the difference between the two is exactly what decides whether a
    /// reload may keep what the reader is looking at. See `load`.
    @State private var presented: String?
    @State private var revertProblem: String?
    /// Editing buffers outlive this view, so flipping back to the diff, walking to the next file
    /// or switching workspace cannot discard what the user typed.
    private let session = FileEditSession.shared

    /// Opens on the diff, unless there is unsaved text for this file, in which case it opens on
    /// the text. That case is not hypothetical: saving an untracked file, or the agent touching one
    /// while it is being read, turns it into a changed file, and the centre column answers by
    /// swapping `FilePreview` out for this view. Landing on a diff would leave the typing on screen
    /// nowhere, which reads exactly like losing it.
    init(model: WorkspaceModel, file: ChangedFile) {
        self.model = model
        self.file = file
        let absolute = (model.workspace.path as NSString).appendingPathComponent(file.path)
        _mode = State(initialValue: FileEditSession.shared.isDirty(absolute) ? .edit : .diff)
    }

    private enum Phase {
        case loading
        case notice(symbol: String, title: String, detail: String)
        case gated(FileDiff, changed: Int)
        case ready(DiffDocument)
    }

    private struct LoadID: Hashable {
        var workspaceID: WorkspaceID
        var file: ChangedFile
    }

    /// One cancel that has been asked about: what would be lost, and which editor to close once
    /// the answer comes back. The editor stays open and holding its text while the question is up,
    /// so an answer of "keep" needs no restoring.
    private struct PendingDiscard: Equatable {
        var target: Target
        var question: ReviewCommentDiscard

        enum Target: Equatable {
            /// The editor the gutter `+` opened.
            case draft
            /// The editor the pencil opened, on the comment it is rewriting.
            case edit(ReviewCommentID)
        }
    }

    private var absolutePath: String {
        (model.workspace.path as NSString).appendingPathComponent(file.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            FileHeaderBar(
                model: model,
                file: file,
                session: session,
                diff: source,
                mode: $mode,
                isEditable: isEditable,
                onRevert: revert
            )
            Hairline()

            switch mode {
            case .diff:
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .edit:
                FileEditPane(model: model, path: file.path, session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
        .background { shortcut }
        .task(id: LoadID(workspaceID: model.workspace.id, file: file)) { await load() }
        .onChange(of: isSideBySide) { _, _ in rebuild() }
        .onChange(of: ignoresWhitespace) { _, _ in refold() }
        .onChange(of: fileComments) { _, _ in rebuild() }
        .onChange(of: draftSpot) { _, _ in rebuild() }
        .onChange(of: model.changesGeneration) { _, _ in refreshWorktreeCopy() }
        // Nothing commits on disappear. Leaving the file used to commit whatever had been typed,
        // on the argument that a visible chip beats a sentence silently gone, and it made chips
        // out of fragments: a reviewer four words in glanced at the next file and "they" was
        // already committed as a review comment. The draft lives on the model now, so leaving
        // loses nothing and the editor reopens holding the text; only Return and the Comment
        // button commit, and only Cancel and Escape discard.
        .onChange(of: isEditable) { _, editable in
            if !editable { mode = .diff }
        }
        .onDisappear { priming?.cancel() }
        .alert(
            "Could not revert \(file.filename)",
            isPresented: $revertProblem.isPresent(),
            presenting: revertProblem
        ) { _ in
        } message: { problem in
            Text(problem)
        }
        // Cancel and Escape ask before they throw typed text away. On this view rather than on the
        // band, for the reason `discarding` gives.
        .confirmation($discarding) { pending in
            pending.question.confirmation
        } onConfirm: { pending in
            switch pending.target {
            case .draft:
                discardDraft()
            case let .edit(id):
                closeEdit(of: id)
            }
        }
    }

    /// Cmd+E flips between the diff and the file, which is what Conductor binds the same choice
    /// to. A hidden button rather than a menu command, for the reason spelled out in
    /// `SessionTabsView`: the menu bar is built elsewhere, and a key equivalent is only offered to
    /// the menu bar and to the view hierarchy. Only alive while a file is actually open.
    private var shortcut: some View {
        Button("Toggle Diff and Edit") {
            guard isEditable else { return }
            mode = mode == .diff ? .edit : .diff
        }
        .keyboardShortcut("e", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            LoadingView("Reading the diff")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .notice(symbol, title, detail):
            placeholder(symbol: symbol, title: title, detail: detail)
        case let .gated(fileDiff, changed):
            gate(fileDiff, changed: changed)
        case let .ready(document):
            diff(document)
        }
    }

    // MARK: Loading

    private func load() async {
        priming?.cancel()
        // **A reload of the file already on screen keeps what is on screen.**
        //
        // This used to say `phase = .loading` unconditionally, and the reader paid for it twice.
        // The changed file poll runs every six seconds and hands this view a fresh `ChangedFile`
        // whenever a count moves, which re-runs the `task` keyed on it: the diff they were reading
        // was replaced by "Reading the diff" and came back a moment later, mid sentence. And the
        // whitespace and layout toggles go through the same door.
        //
        // Only the same file, and `presented` is what says so rather than `file`, because `file`
        // IS the task's id and has already changed by the time this runs. Walking to another file
        // still drops to the spinner, because the alternative is holding one file's diff under
        // another file's name.
        //
        // It does not answer the case a rebuilt view has. A tab switch destroys this view, so the
        // way back starts at `Phase.loading` from the state's own initialiser whatever this does,
        // and what shortens that is `PatchCache` already having the patch: no `git diff`, only the
        // parse. See `WorkspaceModel.patch(for:)`.
        if presented != file.path {
            phase = .loading
            rows = []
            expandedRuns = []
            revealedGaps = [:]
            fileLines = nil
            source = nil
            // Another file's answer to another file's question. It is set at the foot of this
            // function rather than in the middle of it now, so without this the header bar would
            // offer Edit on the strength of the file the reader has just walked away from.
            isEditable = false
        }

        let patch = await model.patch(for: file)
        let path = file.path
        let parsed = await Task.detached(priority: .userInitiated) {
            DiffDocument.parse(patch: patch, path: path)
        }.value

        guard !Task.isCancelled else { return }

        presented = file.path

        guard let parsed else {
            phase = .notice(
                symbol: "doc.plaintext",
                title: "No diff",
                detail: "Git reported no changes for this file."
            )
            return
        }
        source = parsed
        await apply(parsed)

        // Whether Edit mode is even offered is a question about the bytes on disk rather than
        // about the patch, so it is asked off the main thread, and it is asked AFTER the diff is
        // on screen rather than before. It used to sit between the parse and the presentation,
        // where a `stat` and a read of the first bytes of the file stood between the reader and
        // the thing they had clicked. Nothing above it needs the answer; only the header bar's
        // Edit control does, and it appears with the bar rather than with the diff.
        let absolute = absolutePath
        let binary = file.isBinary
        let editable = await Task.detached(priority: .utility) {
            !binary && FileEditor.isEditable(absolute)
        }.value
        guard !Task.isCancelled else { return }
        isEditable = editable
    }

    /// Turn the parsed patch into whatever the current settings say it should be.
    private func apply(_ raw: FileDiff) async {
        let fileDiff = ignoresWhitespace ? raw.ignoringWhitespace() : raw

        if ignoresWhitespace, fileDiff.hunks.isEmpty, !raw.hunks.isEmpty {
            phase = .notice(
                symbol: "paragraphsign",
                title: "Only whitespace changed",
                detail: "Every change to \(file.filename) is indentation or trailing space."
            )
            return
        }
        if let notice = Self.notice(for: fileDiff, file: file) {
            phase = notice
            return
        }

        let changed = fileDiff.additions + fileDiff.deletions
        if changed > Self.largeDiffLimit {
            phase = .gated(fileDiff, changed: changed)
            return
        }
        await present(fileDiff)
    }

    /// Refolding drops what the reader expanded, because a run that was expanded no longer exists
    /// once whitespace-only changes have folded back into context.
    private func refold() {
        guard let source else { return }
        expandedRuns = []
        revealedGaps = [:]
        Task { await apply(source) }
    }

    /// Throw the file's changes away. Only ever reached through the confirmation in the header
    /// bar, which names what is about to go.
    private func revert() {
        Task {
            session.discard(path: absolutePath)
            revertProblem = await FileRevert.revert(file: file, in: model.workspace)
            await model.refreshChanges()
        }
    }

    private func present(_ fileDiff: FileDiff) async {
        let path = file.path
        let worktree = model.workspace.path
        // The worktree copy is read here rather than after the await, which is where it used to be
        // and where it read and split a whole file on the main actor on every file click.
        //
        // It is what the between-hunks expanders reveal. A file git deleted, or one that is not
        // text, simply has no expanders. Split by the anchor's own rule rather than
        // `components(separatedBy:)`, which counts a phantom last line on a file ending in a
        // newline: the review payload resolves against `ReviewCommentAnchor.split`, and the bands
        // resolve against these lines, so the two splits disagreeing at the end of the file is
        // exactly the band-versus-payload disagreement `ReviewCommentRender` warns against.
        let prepared = await Task.detached(priority: .userInitiated) {
            (
                document: DiffDocument.prepare(file: fileDiff, path: path),
                lines: WorkspaceModel.contents(of: path, in: worktree)
                    .map(ReviewCommentAnchor.split)
            )
        }.value

        guard !Task.isCancelled else { return }

        let document = prepared.document
        fileLines = prepared.lines
        phase = .ready(document)
        rebuild()
        prime(document)
    }

    /// How much of a diff is highlighted before anybody scrolls to it. Several screens, which is
    /// what a reader gets through before the cache is warm anyway, and far short of the four
    /// thousand lines `SyntaxCache` holds across every open file: priming a whole large diff would
    /// evict what it had just put in, and a diff between that limit and `largeDiffLimit` can
    /// already thrash it by being scrolled.
    private static let primeLimit = 600

    /// Highlight the top of the diff off the main thread, so the rows a reader actually reaches
    /// are a lookup rather than a lex.
    ///
    /// Every line was lexed twice. `DiffDocument.prepare` walks the file to thread the carry state
    /// and throws the tokens away, and then `SyntaxCache` lexed the same line again, on the main
    /// actor, the first time each row was built. The cache is an `NSCache` and documented thread
    /// safe for exactly this, so the second pass can happen before the first row is asked for.
    private func prime(_ document: DiffDocument) {
        let language = document.language
        let lines = document.linesToPrime(limit: Self.primeLimit)
        priming?.cancel()
        priming = Task.detached(priority: .utility) {
            for line in lines {
                guard !Task.isCancelled else { return }
                _ = SyntaxCache.attributed(line: line.text, language: language, carry: line.carry)
            }
        }
    }

    /// Quiet explanations for the changes that have no lines to show.
    private static func notice(for fileDiff: FileDiff, file: ChangedFile) -> Phase? {
        if fileDiff.isBinary || file.isBinary {
            return .notice(
                symbol: "shippingbox",
                title: "Binary file",
                detail: "\(file.filename) changed. Binary content is not shown."
            )
        }
        guard fileDiff.hunks.isEmpty else { return nil }

        if fileDiff.isRename {
            let from = fileDiff.oldPath ?? file.oldPath ?? "somewhere else"
            return .notice(
                symbol: "arrow.uturn.right",
                title: "Renamed",
                detail: "Moved from \(from) with no change to its contents."
            )
        }
        if fileDiff.isModeChangeOnly {
            let from = fileDiff.oldMode ?? "unknown"
            let to = fileDiff.newMode ?? "unknown"
            return .notice(
                symbol: "lock.shield",
                title: "Mode changed",
                detail: "File mode went from \(from) to \(to). The contents are identical."
            )
        }
        if fileDiff.isNew {
            return .notice(
                symbol: "doc.badge.plus",
                title: "New empty file",
                detail: "\(file.filename) was added with no content."
            )
        }
        if fileDiff.isDeleted {
            return .notice(
                symbol: "trash",
                title: "Deleted",
                detail: "\(file.filename) was removed."
            )
        }
        return .notice(
            symbol: "equal.circle",
            title: "No textual changes",
            detail: "Git found nothing to show for \(file.filename)."
        )
    }

    // MARK: Placeholders

    private func placeholder(symbol: String, title: String, detail: String) -> some View {
        EmptyStateView(glyph: symbol, title: title, message: detail)
    }

    private func gate(_ fileDiff: FileDiff, changed: Int) -> some View {
        EmptyStateView(
            glyph: "doc.text.magnifyingglass",
            title: "\(changed.formatted()) changed lines",
            message: "Highlighting a diff this size takes a moment.",
            actionTitle: "Show anyway",
            action: { Task { await present(fileDiff) } }
        )
    }

    // MARK: Diff

    private func diff(_ document: DiffDocument) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, intrinsicWidth(document))
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, document: document, width: width)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
            // A scroll view with two axes CENTRES content that does not fill it, so a short diff
            // floated in the middle of the pane with a band of empty above it. The anchor is also
            // where the scroller starts, which is the top left either way.
            .defaultScrollAnchor(.topLeading)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// One sheet of text, sized from the widest line, so the whole file scrolls sideways together
    /// instead of every row carrying its own scroller.
    private func intrinsicWidth(_ document: DiffDocument) -> CGFloat {
        let gutter = CodeMetrics.numberWidth + CodeMetrics.gutterPadding
        let code = CGFloat(document.maxColumns) * CodeMetrics.advance
            + CodeMetrics.markerWidth
            + CodeMetrics.textInset
            + CodeMetrics.gutterPadding
        return isSideBySide ? 2 * (gutter + code) : 2 * gutter + code
    }

    @ViewBuilder
    private func rowView(_ row: DiffRow, document: DiffDocument, width: CGFloat) -> some View {
        switch row {
        case let .header(_, text):
            DiffHunkHeaderView(text: text, width: width)

        case let .runExpander(runID, hidden):
            DiffExpanderView(title: "Expand \(Counted.of(hidden, "line"))", width: width) {
                expandedRuns.insert(runID)
                rebuild()
            }

        case let .gapExpander(gapID, hidden):
            DiffExpanderView(
                title: "Expand \(Counted.of(min(hidden, Self.gapStep), "line"))", width: width
            ) {
                revealedGaps[gapID, default: 0] += min(hidden, Self.gapStep)
                rebuild()
            }

        case let .line(line):
            DiffLineView(
                line: line,
                language: document.language,
                carry: document.carries[line.index] ?? LexState(),
                emphasis: document.emphasis[line.index] ?? [],
                numbers: .both,
                width: width,
                isCommented: isCommented(line, numbers: .both),
                onComment: { beginDraft(at: $0) }
            )
            // Every pass over this diff rebuilds every row the stack has already realised, and a
            // long file realises hundreds. Comparing the row's own values first is what keeps a
            // second pass free, and the closure above is why it has to be said: see `DiffLineView`.
            .equatable()

        case let .commentBand(placement):
            ReviewCommentBandView(
                placement: placement,
                width: width,
                editing: editBinding(for: placement.comment.id),
                onBeginEdit: { beginEdit(of: placement.comment) },
                onCommitEdit: { commitEdit(of: placement.comment) },
                onCancelEdit: { cancelEdit(of: placement.comment) },
                onRemove: {
                    let model = model
                    Task { await model.removeReviewComment(id: placement.comment.id) }
                }
            )

        case .commentEditor:
            ReviewCommentEditorView(
                // Read out of `reviewText` rather than off the draft, so a keystroke invalidates
                // this one editor instead of everything that had to ask where the editor is. See
                // `ReviewTextHost`.
                text: Binding(
                    get: { model.reviewText.drafts[file.path] ?? "" },
                    set: { model.reviewText.drafts[file.path] = $0 }
                ),
                width: width,
                onCommit: commitDraft,
                onCancel: cancelDraft
            )

        case let .pair(pair):
            // The two panes split whatever the hairline between them leaves, so they stay the
            // same width as each other on any display.
            HStack(spacing: 0) {
                let half = (width - Metrics.hairline) / 2
                side(pair.left, document: document, numbers: .old, width: half)
                Hairline(axis: .vertical)
                side(pair.right, document: document, numbers: .new, width: half)
            }
        }
    }

    private func side(
        _ line: DiffLine?,
        document: DiffDocument,
        numbers: DiffLineView.Numbers,
        width: CGFloat
    ) -> some View {
        DiffLineView(
            line: line,
            language: document.language,
            carry: line.flatMap { document.carries[$0.index] } ?? LexState(),
            emphasis: line.flatMap { document.emphasis[$0.index] } ?? [],
            numbers: numbers,
            width: width,
            isCommented: isCommented(line, numbers: numbers),
            onComment: { beginDraft(at: $0) }
        )
        // For the reason given at the unified call site above, and twice as much of it: the split
        // layout builds two of these per row.
        .equatable()
    }

    // MARK: - Review comments

    /// The pending comments on this one file, which is all a diff of it can place.
    private var fileComments: [ReviewComment] {
        model.reviewComments.filter { $0.filePath == file.path }
    }

    /// The spots one rendered row answers for, filtered the way `DiffLineView.offeredSpot` is,
    /// so the band always lands under the pane that offered the `+`.
    private func spots(of line: DiffLine, numbers: DiffLineView.Numbers) -> [ReviewSpot] {
        var result: [ReviewSpot] = []
        if numbers != .new, let old = line.oldNumber {
            result.append(ReviewSpot(side: .old, line: old))
        }
        if numbers != .old, let new = line.newNumber {
            result.append(ReviewSpot(side: .new, line: new))
        }
        return result
    }

    private func isCommented(_ line: DiffLine?, numbers: DiffLineView.Numbers) -> Bool {
        guard let line else { return false }
        return spots(of: line, numbers: numbers).contains { commentedSpots.contains($0) }
    }

    /// The anchor is captured here, when the editor opens, not at commit. The diff reloads
    /// underneath an open editor (the six second poll re-keys the load task whenever the file's
    /// counts move), and an anchor captured at commit would describe whatever text wears the
    /// spot's number by then, which is not the line the reviewer pressed `+` on. Worse, a spot
    /// the reloaded hunks no longer print made a commit-time capture fail outright, and the
    /// failure path threw the typed comment away. Captured up front, the evidence is exactly
    /// what was on screen when the comment was begun, and the commit can never lose the text.
    private func beginDraft(at spot: ReviewSpot) {
        guard case let .ready(document) = phase,
              let anchor = ReviewCapture.anchor(
                at: spot, hunks: document.file.hunks, fileLines: fileLines
              )
        else { return }
        // A second press while text is pending moves the editor, and the text moves with it:
        // clearing it here would be the same silent loss the model-held draft exists to prevent.
        model.reviewDrafts[file.path] = ReviewDraft(spot: spot, anchor: anchor)
    }

    /// Cancel and Escape, from the editor the gutter `+` opened.
    ///
    /// **Reported by the owner: either of them threw the sentence away on the press.** There is no
    /// undo anywhere in the app that could bring it back, and Escape is the easier of the two to
    /// hit by accident, because it is also how a menu, a popover and Quick Look are dismissed. So
    /// both ask, and they ask the same thing: `ReviewCommentDiscard` decides whether there is
    /// anything to lose and what the reader is told, so a button and a key cannot come to two
    /// answers about one editor. An empty box, or one holding only whitespace, still closes on the
    /// press: a question with nothing behind it teaches people to click through questions.
    private func cancelDraft() {
        guard let question = ReviewCommentDiscard.needed(
            closing: model.reviewText.drafts[file.path] ?? "", replacing: nil
        ) else {
            discardDraft()
            return
        }
        discarding = PendingDiscard(target: .draft, question: question)
    }

    /// Closing the editor for good: the anchor and the text both go. Reached by an answered
    /// question, by a cancel with nothing to lose, and by a commit that has the body it needs.
    private func discardDraft() {
        model.reviewDrafts[file.path] = nil
        model.reviewText.drafts[file.path] = nil
    }

    /// Return or the Comment button, and nothing else.
    private func commitDraft() {
        guard let draft else { return }
        let body = (model.reviewText.drafts[file.path] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            discardDraft()
            return
        }
        discardDraft()
        let model = model
        let path = file.path
        Task {
            await model.addReviewComment(
                filePath: path, spot: draft.spot, anchor: draft.anchor, body: body
            )
        }
    }

    // MARK: Editing one in place

    /// The text of an open in-place edit, or nil for a band at rest. Through the model for the
    /// same reason the draft is (see `WorkspaceModel.reviewEdits`): this row is destroyed by
    /// scrolling away from it and by walking to another file, and neither is a reason to lose a
    /// rewritten sentence.
    private func editBinding(for id: ReviewCommentID) -> Binding<String>? {
        guard model.reviewEdits.contains(id) else { return nil }
        // Whether the band is open comes off the model, which changes twice per edit; what is in
        // it comes out of `ReviewTextHost`, which changes on every character. Asking one question
        // used to answer both, and the answer to the first was rebuilt on every keystroke.
        return Binding(
            get: { model.reviewText.edits[id] ?? "" },
            set: { model.reviewText.edits[id] = $0 }
        )
    }

    /// Opens the editor on the body as it stands. Reopening one that is already open keeps what
    /// is in it: the pencil is a point away from the text, and a stray click on it must not be
    /// the thing that resets a paragraph somebody has been rewriting.
    private func beginEdit(of comment: ReviewComment) {
        guard !model.reviewEdits.contains(comment.id) else { return }
        model.reviewText.edits[comment.id] = comment.body
        model.reviewEdits.insert(comment.id)
    }

    /// Escape and Cancel, from the editor the pencil opened. It asks first, exactly as the draft's
    /// does.
    ///
    /// **Cancel does not mean the same thing in the two editors, and the question says so.**
    /// Cancelling a comment being written loses the whole note; cancelling a rewrite loses only
    /// the rewrite, because the comment keeps the body it already had and is still going out with
    /// the next message. That is the smaller loss and it is still the one worth asking about: it
    /// is a second look at a note somebody had already decided to leave. `ReviewCommentDiscard`
    /// carries both wordings so the two cannot drift, and it stays quiet when the field says what
    /// the comment already says, or has been emptied, since neither leaves anything to lose.
    private func cancelEdit(of comment: ReviewComment) {
        guard let question = ReviewCommentDiscard.needed(
            closing: model.reviewText.edits[comment.id] ?? "", replacing: comment.body
        ) else {
            closeEdit(of: comment.id)
            return
        }
        discarding = PendingDiscard(target: .edit(comment.id), question: question)
    }

    /// Closing the editor for good, which is also what a save does once the write is on its way.
    private func closeEdit(of id: ReviewCommentID) {
        model.reviewEdits.remove(id)
        model.reviewText.edits[id] = nil
    }

    /// Return and Save. What the three answers mean is `ReviewCommentEdit`'s, and a refusal
    /// leaves the editor open holding what is in it, which is the whole of what "refused" buys:
    /// an emptied field is a mistake far more often than it is a request to delete, and the
    /// remove control is right there for when it is not.
    private func commitEdit(of comment: ReviewComment) {
        guard let typed = model.reviewText.edits[comment.id] else { return }
        switch ReviewCommentEdit.outcome(typed: typed, replacing: comment.body) {
        case .refused:
            return
        case .unchanged:
            closeEdit(of: comment.id)
        case let .save(body):
            closeEdit(of: comment.id)
            let model = model
            Task { await model.editReviewComment(id: comment.id, body: body) }
        }
    }

    /// Bands and the editor, appended directly under the row that answers for their spot.
    private func appendAnnotations(_ rows: inout [DiffRow], spots rowSpots: [ReviewSpot]) {
        for spot in rowSpots {
            for placement in placements where placement.spot == spot {
                rows.append(.commentBand(placement))
            }
            if draftSpot == spot {
                rows.append(.commentEditor(spot))
            }
        }
    }

    /// The comments the diff on screen cannot put under a line, said at the top rather than
    /// dropped: they are still attached and still going with the next message.
    private func appendUnplacedComments(_ rows: inout [DiffRow]) {
        for placement in placements where placement.spot == nil {
            rows.append(.commentBand(placement))
        }
    }

    /// Re-checks the pending comments against the worktree after the changes poll lands.
    ///
    /// When an edit moves the file's diff counts, the whole view reloads: the load task is keyed
    /// on the `ChangedFile` value, and the poll writes a fresh one. This is the case that keying
    /// cannot see, and the one the bands' honesty depends on: an edit that leaves the counts
    /// where they were (rewording a line, one for one) changes nothing this view is keyed on,
    /// and without this re-read the bands would go on vouching for lines the worktree no longer
    /// holds. Only the worktree copy is re-read; the hunks on screen stay as they are, and a
    /// comment the stale hunks can no longer vouch for is reported hidden or outdated by
    /// `ReviewPlacements` rather than pinned to the wrong line. Refreshing the diff text itself
    /// is the reload's job, not this one's. The read is synchronous on purpose: it only runs
    /// while comments or an open editor are pending on this one file, and the load path already
    /// reads the same file the same way.
    private func refreshWorktreeCopy() {
        guard case .ready = phase, !fileComments.isEmpty || draftSpot != nil else { return }
        let fresh = model.contents(of: file.path).map(ReviewCommentAnchor.split)
        guard fresh != fileLines else { return }
        fileLines = fresh
        rebuild()
    }

    /// The between-hunks context lines the reader has revealed, keyed by new-side number, which
    /// `ReviewPlacements` needs because those lines are printed and the hunks do not know it.
    ///
    /// Through `DiffGap`, the same as `appendGap` 120 lines below. The arithmetic used to be
    /// written out in both places, identically, and the two have to agree or a pending review
    /// comment anchors to a line that is not on screen: one decides which lines are drawn and
    /// this one decides which lines a comment may attach to.
    private func revealedContextLines(_ document: DiffDocument) -> [Int: String] {
        guard let fileLines else { return [:] }
        var revealed: [Int: String] = [:]
        let hunks = document.file.hunks
        for index in hunks.indices {
            guard let gap = DiffGap.between(hunks: hunks, at: index) else { continue }
            for number in DiffGap.revealed(revealedGaps[index] ?? 0, in: gap)
            where number >= 1 && number - 1 < fileLines.count {
                revealed[number] = fileLines[number - 1]
            }
        }
        return revealed
    }

    // MARK: Row building

    private func rebuild() {
        guard case let .ready(document) = phase else {
            rows = []
            placements = []
            commentedSpots = []
            return
        }
        // Placed in the same pass that lays the rows out, so a band can never survive the row it
        // was under: whatever moves them (a refresh, a removed comment, a whitespace refold)
        // lands here and both are rebuilt from the same facts.
        placements = ReviewPlacements.place(
            fileComments,
            in: document.file,
            currentLines: fileLines,
            revealedNewLines: revealedContextLines(document)
        )
        var spots = Set(placements.compactMap(\.spot))
        if let draftSpot { spots.insert(draftSpot) }
        commentedSpots = spots
        rows = isSideBySide ? splitRows(document) : unifiedRows(document)

        // The editor follows its line, and a rebuild can take that line off the screen: a reload
        // after the agent edits, or a whitespace refold dropping the expanded run the line sat
        // in. The editor then moves to the top of the diff, next to the unplaced bands, rather
        // than vanishing, because a vanished editor takes the half-typed comment with it and
        // that is the one loss this feature is not allowed.
        if let draftSpot, !rows.contains(where: {
            if case .commentEditor = $0 { return true } else { return false }
        }) {
            rows.insert(.commentEditor(draftSpot), at: 0)
        }
    }

    private func unifiedRows(_ document: DiffDocument) -> [DiffRow] {
        var rows: [DiffRow] = []
        appendUnplacedComments(&rows)

        for (hunkIndex, hunk) in document.file.hunks.enumerated() {
            appendGap(&rows, document: document, hunkIndex: hunkIndex, hunk: hunk, split: false)
            appendHeading(&rows, document: document, hunkIndex: hunkIndex)

            let lines = hunk.lines
            for chunk in Self.chunks(
                count: lines.count,
                isContext: { lines[$0].kind == .context },
                runID: { lines[$0].index },
                expanded: expandedRuns
            ) {
                switch chunk {
                case let .visible(range):
                    for offset in range {
                        rows.append(.line(lines[offset]))
                        appendAnnotations(&rows, spots: spots(of: lines[offset], numbers: .both))
                    }
                case let .hidden(runID, count):
                    rows.append(.runExpander(runID: runID, hidden: count))
                }
            }
        }
        return rows
    }

    private func splitRows(_ document: DiffDocument) -> [DiffRow] {
        var rows: [DiffRow] = []
        appendUnplacedComments(&rows)

        for (hunkIndex, hunk) in document.file.hunks.enumerated() {
            appendGap(&rows, document: document, hunkIndex: hunkIndex, hunk: hunk, split: true)
            appendHeading(&rows, document: document, hunkIndex: hunkIndex)

            // Folding one hunk at a time keeps the boundaries that `sideBySide()` flattens away.
            var single = document.file
            single.hunks = [hunk]
            let pairs = single.sideBySide()

            for chunk in Self.chunks(
                count: pairs.count,
                isContext: { pairs[$0].left?.kind == .context },
                runID: { pairs[$0].left?.index ?? pairs[$0].index },
                expanded: expandedRuns
            ) {
                switch chunk {
                case let .visible(range):
                    for offset in range {
                        rows.append(.pair(pairs[offset]))
                        // Each half answers for its own side, the same split
                        // `DiffLineView.offeredSpot` makes, so a band lands once however the
                        // context line is mirrored across the panes.
                        var rowSpots: [ReviewSpot] = []
                        if let left = pairs[offset].left {
                            rowSpots += spots(of: left, numbers: .old)
                        }
                        if let right = pairs[offset].right {
                            rowSpots += spots(of: right, numbers: .new)
                        }
                        appendAnnotations(&rows, spots: rowSpots)
                    }
                case let .hidden(runID, count):
                    rows.append(.runExpander(runID: runID, hidden: count))
                }
            }
        }
        return rows
    }

    /// The unchanged region git never printed, between the previous hunk and this one.
    ///
    /// Which lines those are is `DiffGap`, in the core, shared with `revealedContextLines` above.
    /// See that property for what the pair used to be.
    private func appendGap(
        _ rows: inout [DiffRow],
        document: DiffDocument,
        hunkIndex: Int,
        hunk: DiffHunk,
        split: Bool
    ) {
        guard let fileLines else { return }

        guard let gap = DiffGap.between(hunks: document.file.hunks, at: hunkIndex) else { return }

        let requested = revealedGaps[hunkIndex] ?? 0
        let hidden = DiffGap.hidden(requested, in: gap)
        if hidden > 0 {
            rows.append(.gapExpander(gapID: hunkIndex, hidden: hidden))
        }
        let revealed = DiffGap.revealed(requested, in: gap)
        guard !revealed.isEmpty else { return }

        let offset = hunk.oldStart - hunk.newStart
        for number in revealed {
            guard number >= 1, number - 1 < fileLines.count else { continue }
            // A negative index cannot collide with a parsed line, so the carry lookup misses and
            // falls back to a clean lexer state, which is the honest answer for a line whose
            // predecessors were never parsed.
            let line = DiffLine(
                kind: .context,
                text: fileLines[number - 1],
                oldNumber: number + offset,
                newNumber: number,
                index: -number - 1
            )
            if split {
                rows.append(.pair(SideBySideRow(left: line, right: line, index: line.index)))
            } else {
                rows.append(.line(line))
            }
            // A revealed line is as commentable as a printed one, so its bands follow it. New
            // side only: the revealed copy comes from the worktree, which has no old side.
            appendAnnotations(&rows, spots: spots(of: line, numbers: .new))
        }
    }

    /// The `@@` band, drawn only where it says something the numbers beside it do not.
    ///
    /// Both the rule and the text are `DiffHunkHeading`, in the core, so the two layouts cannot
    /// end up showing different bands and so the rule has a test. It is asked here rather than in
    /// `appendGap` because a hunk with no gap above it still comes through this line.
    private func appendHeading(
        _ rows: inout [DiffRow],
        document: DiffDocument,
        hunkIndex: Int
    ) {
        guard let text = DiffHunkHeading.text(
            for: document.file.hunks, at: hunkIndex, revealed: revealedGaps[hunkIndex] ?? 0
        ) else { return }
        rows.append(.header(hunk: hunkIndex, text: text))
    }

    // MARK: Collapsing

    private enum Chunk {
        case visible(Range<Int>)
        case hidden(runID: Int, count: Int)
    }

    /// Split a hunk's rows into what to draw and what to hide, working on indices so unified and
    /// side by side can share one implementation.
    private static func chunks(
        count: Int,
        isContext: (Int) -> Bool,
        runID: (Int) -> Int,
        expanded: Set<Int>
    ) -> [Chunk] {
        var chunks: [Chunk] = []
        var pending = 0
        var index = 0

        while index < count {
            guard isContext(index) else {
                index += 1
                continue
            }
            var end = index
            while end < count, isContext(end) { end += 1 }

            let length = end - index
            let id = runID(index)
            if length > collapseThreshold, !expanded.contains(id) {
                chunks.append(.visible(pending..<(index + keptContext)))
                chunks.append(.hidden(runID: id, count: length - keptContext * 2))
                pending = end - keptContext
            }
            index = end
        }

        if pending < count { chunks.append(.visible(pending..<count)) }
        return chunks
    }
}
