import SwiftUI
import AppKit
import BloomCore

/// The line that closes a turn: how long it took, what it changed, and the handles to do something
/// with it.
struct TurnFooterView: View {
    var rows: [TranscriptRow]
    var row: TranscriptRow
    /// What the file chips show their paths relative to. See `TurnFile.display(in:)`.
    var worktree: String
    /// What the session is set to, so a turn whose calls were declined can name the setting that
    /// declined them. See `TurnEnding.note`.
    var permissionMode: PermissionMode = .acceptEdits
    /// Whether this is the turn somebody stopped.
    ///
    /// Handed down rather than worked out here, because it is a fact about the session and the
    /// whole row list, and a footer can only see one turn. `TranscriptModel.stoppedTurnSeq` is
    /// where it is decided, over `StoppedTurn`.
    var wasStopped = false
    /// A run of retries this turn waited out before it got through, or nothing.
    ///
    /// The live waiting row is gone by the time this is drawn, and it must not simply have
    /// vanished: a footer saying three minutes with nothing in the transcript to account for them
    /// is the same unexplained silence in the past tense. One sentence, in the caption ink, with
    /// no advice in it, because it is a note about something that is over.
    ///
    /// A turn that failed carries none of this. See `TranscriptModel.abandonRetryRun`.
    var recovered: RetryRun?

    /// More chips than this and the footer stops being a footer.
    private static let visibleFileLimit = 6

    @State private var files: [TurnFile] = []

    var body: some View {
        // Read once for the pass, and handed down.
        //
        // Every one of these is derived from the turn's result payload, which is one of the larger
        // ones in the file, and the decode in front of it went through `TranscriptEventCache`
        // precisely because the footer asks for it more than once. It asked about ten times: the
        // glyph, its tint, the accessible label, the duration, the copy button's text, the menu's
        // three items, the note under the row and the failure block under that. Cached or not, a
        // decode is a dictionary lookup and an enum match per ask, and `outcome` and `appearance`
        // were rebuilt on top of each one.
        let result = result
        let outcome = TurnEnding.of(
            wasStopped: wasStopped,
            succeeded: result?.succeeded != false,
            denials: result?.permissionDenials ?? 0
        )
        let appearance = Self.appearance(of: outcome)
        let summaryText = result?.summary ?? ""

        return VStack(alignment: .leading, spacing: 0) {
            // Inset to the column the footer's own contents start on, rather than to the pane.
            // A rule that stops six points short of the text under it looks like a mistake, and
            // this one closes a turn, so it has to read as drawn on purpose.
            //
            // Nearer the line under it than the answer above it, and that is the whole point.
            // The rule and the facts beneath it are one object, the thing that ends a turn, and
            // drawn with equal air on both sides it read as a divider parked between two turns
            // with a time floating next to it. Six of its own above and two below: the answer
            // carries its own eight point rung, so fourteen points sit over the rule and eight
            // under it, where before it was fourteen and twelve.
            Hairline()
                .padding(.horizontal, TranscriptLayout.inset)
                .padding(.top, TranscriptLayout.inset)
                .padding(.bottom, TranscriptLayout.tight)

            // A turn's duration is the number a user goes looking for, so it sits a rung above
            // the counts and timings that decorate a single row.
            HStack(spacing: TranscriptLayout.block) {
                Image(systemName: appearance.glyph)
                    .font(Typo.caption)
                    .imageScale(.medium)
                    .foregroundStyle(appearance.tint)
                    .accessibilityLabel(outcome.label)
                    // Four ways a turn can end, collapsed into one 13 point mark, and this row is
                    // the only place any of them is said. VoiceOver could read it and a pointer
                    // could not; the `Menu` eight lines below already carries a tooltip.
                    .help(outcome.label)

                Text(TurnDuration.format(row.durationMS ?? result?.durationMS ?? 0))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .monospacedDigit()
                    .fixedSize()

                // `ec8400d` removed: what a turn cost is no longer printed here, and there is
                // nowhere else in the window it appears. Three decimal places of a dollar is not
                // a number anybody acts on between one turn and the next, and it was the third
                // thing on a line that exists to say the turn ended and how long it took. The
                // figure is still parsed and still stored per session, so a readout that answers
                // a question somebody actually has can be built off it later.

                // How many chips there is room for, rather than a fixed count. The chips are the
                // only thing in this row that can be dropped, and the alternative was every one of
                // them being squeezed to an empty rounded rectangle while the duration and the
                // two buttons kept their width.
                //
                // The second rung is where the ladder narrows rather than a fixed three, because
                // `ViewThatFits` builds and measures every candidate it is offered until one fits.
                // A turn that touched two or three files was offering the identical row of all of
                // them twice before it got anywhere: two full sets of chips built and measured to
                // draw one, on a turn shape that is most turns.
                //
                // Not a condition around the candidate, which is the obvious form and is wrong: an
                // absent branch is an empty view, an empty view always fits, and the footer would
                // draw nothing where it used to fall through to the count. The rung below is still
                // offered when the two agree, and a candidate that has already failed fails again,
                // so what is drawn is what was drawn before in every case.
                ViewThatFits(in: .horizontal) {
                    fileChips(limit: Self.visibleFileLimit)
                    fileChips(limit: files.count > 3 ? 3 : 1)
                    fileChips(limit: 1)
                    countChip
                    Color.clear.frame(width: 0, height: 0)
                }

                Spacer(minLength: TranscriptLayout.tight)

                CopyButton(text: summaryText, title: "Copy this answer")

                // The menu's three do not flash the tick beside them. It is one button saying
                // one thing, and it said "Copy this answer" while the raw event was what had
                // just gone on the pasteboard.
                Menu {
                    Button("Copy answer") { Clipboard.copy(summaryText) }
                    Button("Copy files touched") { Clipboard.copy(filesText) }
                    Button("Copy raw event") { Clipboard.copy(rawEventText) }
                } label: {
                    Label("More for this turn", systemImage: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .labelStyle(.iconOnly)
                .font(Typo.caption)
                .imageScale(.medium)
                .fixedSize()
                .help("More for this turn")
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, TranscriptLayout.inset)
            .padding(.vertical, TranscriptLayout.inset)

            // Under the row rather than in it, and only when there is something to say. This is
            // the one place in a turn that can name what went undone and what would undo it, and
            // it is where somebody looks after a button appeared to do nothing.
            if let notice = outcome.note(permissionMode: permissionMode) {
                Text(notice)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.inset)
            }

            // A turn that failed used to draw a red mark, a duration and nothing at all, with the
            // CLI's own explanation parked behind the copy menu. See `TurnFailure`.
            if outcome == .failed, let result, let failure = TurnFailure.of(result) {
                VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
                    if let lead = failure.lead {
                        Text(lead)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    // Marked as theirs. It is written in another app's register, and it is the one
                    // piece of this block Bloom did not write.
                    if let words = failure.clisOwnWords {
                        Text("The agent said: \(words)")
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .font(Typo.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
                .padding(.horizontal, TranscriptLayout.inset)
                .padding(.bottom, TranscriptLayout.inset)
            }

            // Tertiary rather than secondary, and under everything else: it explains a duration
            // somebody may go looking for, and it is not news the moment the turn lands.
            if let recovered {
                Text(recovered.recoveredSentence)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.inset)
            }
        }
        .task(id: row.seq) { await scanFiles() }
    }

    // MARK: Turn facts

    /// Read through the same cache the rows use, once per pass, in `body`. This used to say three
    /// times, which was a count of the asks rather than a decision about them, and by the time the
    /// failure block and the copy menu had been added it was about ten. The payload is one of the
    /// larger ones in the file, and a cached decode is still a lookup and an enum match per ask.
    ///
    /// What was built on top of each of those asks is where the rest of the cost was. Four endings
    /// and their drawing were three computed properties reading each other, so every read of the
    /// last one decoded the first. `body` now takes the result once, works out the ending once,
    /// and hands both down.
    ///
    /// A turn that failed shows what the CLI said for itself, and only when it really failed. Not
    /// for a turn somebody stopped: the CLI reports its own SIGTERM as an error, and `TurnEnding`
    /// already refuses to call that a failure. Quoting the CLI's account of a button press would
    /// put the same mistake back one line lower.
    ///
    /// The denials `TurnEnding` is handed are the calls the CLI declined during the turn, reported
    /// on the `result` line, which is otherwise a plain success: a turn in which every shell call
    /// was denied ends with `is_error` false and `subtype` "success", so without them the footer
    /// put a green tick under an agent that had been stopped at every door.
    private var result: AgentResult? {
        guard case .result(let value)? = TranscriptEventCache.event(rowID: row.id, payload: row.payload) else {
            return nil
        }
        return value
    }

    /// The drawing of an ending. A stop is not a failure and must not borrow the failure's red: it
    /// is the one ending nothing went wrong in, so it is drawn in the ink an ordinary caption uses,
    /// with the Stop button's own symbol in the ring the other three endings use.
    private static func appearance(of outcome: TurnEnding) -> (glyph: String, tint: Color) {
        switch outcome {
        case .finished: ("checkmark.circle", Palette.positive)
        case .denied: ("hand.raised.circle", Palette.warning)
        case .failed: ("exclamationmark.circle", Palette.negative)
        case .stopped: ("stop.circle", Palette.textSecondary)
        }
    }

    // MARK: Actions

    /// Off the main actor: a long turn means decoding every tool call in it, and that must not land
    /// on the frame that scrolled the footer into view.
    ///
    /// And only once per turn. This hangs off a `.task`, which runs on every realisation of the
    /// row, and a `LazyVStack` re-realises a footer every time it is scrolled past: each of those
    /// was a walk back over up to four hundred rows, decoding every one of them. See
    /// `TurnScanCache` for why the answer can be kept.
    private func scanFiles() async {
        if let known = TurnScanCache.files(rowID: row.id) {
            files = known
            return
        }
        let scanned = await Task.detached(priority: .utility) { [rows, seq = row.seq] in
            TurnScan.files(rows: rows, endingAt: seq)
        }.value
        TurnScanCache.remember(scanned, rowID: row.id)
        files = scanned
    }

    /// The first `limit` files as chips, with what is left named rather than dropped.
    @ViewBuilder
    private func fileChips(limit: Int) -> some View {
        HStack(spacing: TranscriptLayout.block) {
            ForEach(files.prefix(limit)) { file in
                TurnFileChip(file: file, worktree: worktree)
            }
            if files.count > limit {
                Chip(text: "+\(files.count - limit) more")
            }
        }
        .fixedSize()
    }

    /// The last thing before nothing: how many files the turn touched, without naming any of them.
    @ViewBuilder
    private var countChip: some View {
        if !files.isEmpty {
            Chip(text: files.count == 1 ? "1 file" : "\(files.count) files")
                .fixedSize()
        }
    }

    private var filesText: String { files.map(\.path).joined(separator: "\n") }

    private var rawEventText: String { String(decoding: row.payload, as: UTF8.self) }
}
