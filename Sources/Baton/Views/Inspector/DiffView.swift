import SwiftUI
import BatonCore

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

    /// The patch as git wrote it, kept so the whitespace toggle can refold it without going back
    /// to git for a diff it has already been given.
    @State private var source: FileDiff?
    @State private var mode: FileViewMode = .diff
    @State private var isEditable = false
    @State private var revertProblem: String?
    /// Editing buffers outlive this view, so flipping back to the diff, walking to the next file
    /// or switching workspace cannot discard what the user typed.
    private let session = FileEditSession.shared

    private enum Phase {
        case loading
        case notice(symbol: String, title: String, detail: String)
        case gated(FileDiff, changed: Int)
        case ready(DiffDocument)
    }

    private struct LoadID: Hashable {
        var workspaceID: String
        var file: ChangedFile
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
                FileEditPane(model: model, file: file, session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
        .task(id: LoadID(workspaceID: model.workspace.id, file: file)) { await load() }
        .onChange(of: isSideBySide) { _, _ in rebuild() }
        .onChange(of: ignoresWhitespace) { _, _ in refold() }
        // Only the path, not the whole file: a refresh that changes nothing but the line counts
        // must not throw the user out of the editor they are typing in.
        .onChange(of: file.path) { _, _ in mode = .diff }
        .onChange(of: isEditable) { _, editable in
            if !editable { mode = .diff }
        }
        .alert(
            "Could not revert \(file.filename)",
            isPresented: $revertProblem.isPresent(),
            presenting: revertProblem
        ) { _ in
        } message: { problem in
            Text(problem)
        }
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
        phase = .loading
        rows = []
        expandedRuns = []
        revealedGaps = [:]
        fileLines = nil
        source = nil

        let patch = await model.patch(for: file)
        let path = file.path
        let parsed = await Task.detached(priority: .userInitiated) {
            DiffDocument.parse(patch: patch, path: path)
        }.value

        guard !Task.isCancelled else { return }

        // Whether Edit mode is even offered is a question about the bytes on disk, not about the
        // patch, so it is asked once here and off the main thread.
        let absolute = absolutePath
        let binary = file.isBinary
        isEditable = await Task.detached(priority: .utility) {
            !binary && FileEditor.isEditable(absolute)
        }.value

        guard !Task.isCancelled else { return }

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
        let document = await Task.detached(priority: .userInitiated) {
            DiffDocument.prepare(file: fileDiff, path: path)
        }.value

        guard !Task.isCancelled else { return }

        // The worktree copy is what the between-hunks expanders reveal. A file git deleted, or one
        // that is not text, simply has no expanders.
        fileLines = model.contents(of: path).map { $0.components(separatedBy: "\n") }
        phase = .ready(document)
        rebuild()
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
            title: "\(changed) changed lines",
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

        case let .runExpander(_, runID, hidden):
            DiffExpanderView(title: "Expand \(hidden) lines", width: width) {
                expandedRuns.insert(runID)
                rebuild()
            }

        case let .gapExpander(_, gapID, hidden):
            DiffExpanderView(title: "Expand \(min(hidden, Self.gapStep)) lines", width: width) {
                revealedGaps[gapID, default: 0] += min(hidden, Self.gapStep)
                rebuild()
            }

        case let .line(_, line):
            DiffLineView(
                line: line,
                language: document.language,
                carry: document.carries[line.index] ?? LexState(),
                emphasis: document.emphasis[line.index] ?? [],
                numbers: .both,
                width: width
            )

        case let .pair(_, pair):
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
            width: width
        )
    }

    // MARK: Row building

    private func rebuild() {
        guard case let .ready(document) = phase else {
            rows = []
            return
        }
        rows = isSideBySide ? splitRows(document) : unifiedRows(document)
    }

    private func unifiedRows(_ document: DiffDocument) -> [DiffRow] {
        var builder = RowBuilder()

        for (hunkIndex, hunk) in document.file.hunks.enumerated() {
            appendGap(&builder, document: document, hunkIndex: hunkIndex, hunk: hunk, split: false)
            builder.append { .header(id: $0, text: Self.headerText(hunk)) }

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
                        builder.append { .line(id: $0, line: lines[offset]) }
                    }
                case let .hidden(runID, count):
                    builder.append { .runExpander(id: $0, runID: runID, hidden: count) }
                }
            }
        }
        return builder.rows
    }

    private func splitRows(_ document: DiffDocument) -> [DiffRow] {
        var builder = RowBuilder()

        for (hunkIndex, hunk) in document.file.hunks.enumerated() {
            appendGap(&builder, document: document, hunkIndex: hunkIndex, hunk: hunk, split: true)
            builder.append { .header(id: $0, text: Self.headerText(hunk)) }

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
                        builder.append { .pair(id: $0, row: pairs[offset]) }
                    }
                case let .hidden(runID, count):
                    builder.append { .runExpander(id: $0, runID: runID, hidden: count) }
                }
            }
        }
        return builder.rows
    }

    /// The unchanged region git never printed, between the previous hunk and this one.
    private func appendGap(
        _ builder: inout RowBuilder,
        document: DiffDocument,
        hunkIndex: Int,
        hunk: DiffHunk,
        split: Bool
    ) {
        guard let fileLines else { return }

        let hunks = document.file.hunks
        let previousEnd: Int = hunkIndex == 0
            ? 1
            : hunks[hunkIndex - 1].newStart + hunks[hunkIndex - 1].newCount
        let gap = hunk.newStart - previousEnd
        guard gap > 0 else { return }

        let revealed = min(revealedGaps[hunkIndex] ?? 0, gap)
        let hidden = gap - revealed
        if hidden > 0 {
            builder.append { .gapExpander(id: $0, gapID: hunkIndex, hidden: hidden) }
        }
        guard revealed > 0 else { return }

        // Lines are revealed upward from the hunk, the way a reader walks back out of a change.
        let offset = hunk.oldStart - hunk.newStart
        for number in (hunk.newStart - revealed)..<hunk.newStart {
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
                builder.append { .pair(id: $0, row: SideBySideRow(left: line, right: line)) }
            } else {
                builder.append { .line(id: $0, line: line) }
            }
        }
    }

    private static func headerText(_ hunk: DiffHunk) -> String {
        let trimmed = hunk.header.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
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
