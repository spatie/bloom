import SwiftUI
import AppKit
import BloomCore

/// The line that closes a turn: how long it took, what it changed, and the handles to do something
/// with it.
struct TurnFooterView: View {
    var row: TranscriptRow
    /// What the file chips show their paths relative to. See `TurnFile.display(in:)`.
    var worktree: String
    /// What the session is set to, so a turn whose calls were declined can name the setting that
    /// declined them. See `TurnEnding.note`.
    var permissionMode: PermissionMode = .acceptEdits
    /// Which CLI ran the turn, for the same sentence: the modes are named in the backend's own
    /// words, so naming one needs to know whose words to use. See `PermissionVocabulary`.
    var agentKind: AgentKind = .claudeCode
    /// Whether this is the turn somebody stopped.
    ///
    /// Handed down rather than worked out here, because it is a fact about the session and the
    /// whole row list, and a footer can only see one turn. `TranscriptModel.stoppedTurnSeq` is
    /// where it is decided, over `StoppedTurn`.
    var wasStopped = false
    /// What the agent left running in the background, named, or nothing.
    ///
    /// Only ever handed to the footer that closes the transcript. A turn that ends while a
    /// backgrounded command is still going is not the agent being finished, and "Completed" on its
    /// own, under a tab that is still breathing, is what made that look like a stuck turn. See
    /// `BackgroundWork`.
    var stillRunning: BackgroundWork.Note?
    /// Whether this is the last thing in the transcript. Only that turn can be continued after a
    /// limit resets: one with anything below it has already been answered.
    var closesTranscript = false
    var transcript: TranscriptModel?
    /// False when the disclosure after the prompt carries the duration.
    var showsDuration = true
    /// The duration of the visible segment when a running turn was steered by another message.
    var durationMS: Int?

    /// More chips than this and the footer stops being a footer.
    private static let visibleFileLimit = 6

    @State private var files: [TurnFile] = []
    @State private var snapshotFailure: String?

    private var checkpoint: TurnCheckpoint? {
        transcript?.history.checkpoints.first { $0.endSeq == row.seq && $0.after != nil }
    }

    var body: some View {
        // Read once for the pass, and handed down.
        //
        // Every one of these is derived from the turn's result payload, which is one of the larger
        // ones in the file, and the decode in front of it went through `TranscriptEventCache`
        // precisely because the footer asks for it more than once. It asked about ten times: the
        // glyph, its tint, the accessible label, the duration, the menu's three items, the note
        // under the row and the failure block under that. Cached or not, a
        // decode is a dictionary lookup and an enum match per ask, and `outcome` and `appearance`
        // were rebuilt on top of each one.
        let result = result
        let outcome = TurnEnding.of(
            wasStopped: wasStopped,
            succeeded: result?.succeeded != false,
            denials: result?.permissionDenials ?? 0
        )
        return VStack(alignment: .leading, spacing: 0) {
            // A turn's duration is the number a user goes looking for, so it sits a rung above
            // the counts and timings that decorate a single row.
            if showsDuration || outcome != .finished || !files.isEmpty {
                HStack(spacing: TranscriptLayout.block) {
                    if outcome != .finished {
                        let appearance = Self.appearance(of: outcome)
                        Image(systemName: appearance.glyph)
                            .font(Typo.caption)
                            .imageScale(.medium)
                            .foregroundStyle(appearance.tint)
                            .accessibilityLabel(outcome.label)
                            .help(outcome.label)
                    }

                    if showsDuration || outcome != .finished {
                        Text(
                            showsDuration
                                ? Self.durationLabel(
                                    outcome: outcome,
                                    milliseconds: durationMS ?? row.durationMS ?? result?.durationMS ?? 0
                                )
                                : outcome.label
                        )
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .monospacedDigit()
                            .fixedSize()
                    }

                    // More chips than fit step down to three, one, then a count rather than
                    // squeezing every path into an empty rounded rectangle.
                    ViewThatFits(in: .horizontal) {
                        fileChips(limit: Self.visibleFileLimit)
                        fileChips(limit: files.count > 3 ? 3 : 1)
                        fileChips(limit: 1)
                        countChip
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, TranscriptLayout.inset)
                .padding(.top, Metrics.gutter)
                .padding(.bottom, Metrics.spacingSmall)
            }

            // Under the row rather than in it, and only when there is something to say. This is
            // the one place in a turn that can name what went undone and what would undo it, and
            // it is where somebody looks after a button appeared to do nothing.
            if let notice = outcome.note(permissionMode: permissionMode, agentKind: agentKind) {
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
                    if closesTranscript, let transcript, transcript.offersLimitResume(after: result) {
                        LimitResumeControl(watch: transcript.limitResumeWatch) {
                            transcript.continueAfterLimitResets(hitAt: row.createdAt)
                        }
                        .padding(.top, TranscriptLayout.tight)
                    }
                }
                .font(Typo.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
                .padding(.horizontal, TranscriptLayout.inset)
                .padding(.bottom, TranscriptLayout.inset)
            }

            if let snapshotFailure {
                Text("Saved file summary unavailable")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .help(snapshotFailure)
                    .padding(.horizontal, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.inset)
            }

            // A plate of its own because this is live state after the answer has ended. The extra
            // air above it keeps it out of the answer's paragraph rhythm, and the loud line is the
            // task's own name, which is the one thing somebody reads this plate for.
            if let stillRunning {
                HStack(alignment: .top, spacing: TranscriptLayout.glyphGap) {
                    ActivityDot(isActive: true, tint: Palette.warning)
                        .frame(width: TranscriptLayout.glyphWidth, height: TranscriptLayout.glyphWidth)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                        Text(stillRunning.title)
                            .font(Typo.captionEmphasis)
                            .foregroundStyle(Palette.textSecondary)

                        // The note owns when the work began; this clock only redraws the readout,
                        // and it is drawn here rather than carried in the note so that a
                        // `tool_progress` tick a second does not rebuild the table. See
                        // `BackgroundWork.Note.since`.
                        if stillRunning.isTimed {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                detailLine(stillRunning.detail(at: context.date))
                            }
                            .transaction { $0.animation = nil }
                        } else {
                            // Several tasks, whose clocks differ, so there is nothing ticking to
                            // draw and nothing for a timeline to redraw.
                            detailLine(stillRunning.detail(at: .now))
                        }
                    }
                }
                .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
                .padding(Metrics.inset)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                        .fill(Palette.surfaceSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: Metrics.outline)
                )
                .padding(.horizontal, TranscriptLayout.inset)
                .padding(.top, Metrics.gutter + TranscriptLayout.block)
                .padding(.bottom, TranscriptLayout.inset)
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: "\(row.seq):\(checkpoint?.after?.id.rawValue ?? "legacy")") { await scanFiles() }
    }

    /// The quiet second line of the running plate, whether or not a clock is redrawing it.
    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func durationLabel(outcome: TurnEnding, milliseconds: Int) -> String {
        let duration = TurnDuration.wholeSeconds(milliseconds)
        return switch outcome {
        case .finished, .denied: "Completed in \(duration)"
        case .failed: "Failed after \(duration)"
        case .stopped: "Stopped after \(duration)"
        }
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
        snapshotFailure = nil
        if let transcript, let checkpoint, let snapshotID = checkpoint.after?.id {
            if let known = TurnScanCache.files(snapshotID: snapshotID) {
                files = known
                return
            }
            do {
                let changed = try await transcript.history.files(checkpoint, cwd: worktree)
                guard !Task.isCancelled else { return }
                files = changed.map { TurnFile(path: $0.path, additions: $0.additions, deletions: $0.deletions) }
                TurnScanCache.remember(files, snapshotID: snapshotID)
            } catch {
                guard !Task.isCancelled else { return }
                files = []
                snapshotFailure = "Could not load the saved file summary: \(error)"
            }
            return
        }
        if let known = TurnScanCache.files(rowID: row.id) {
            files = known
            return
        }
        guard let rows = transcript?.rows else { return }
        let scanned = await Task.detached(priority: .utility) { [rows, seq = row.seq] in
            TurnScan.files(rows: rows, endingAt: seq)
        }.value
        guard !Task.isCancelled else { return }
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

}
