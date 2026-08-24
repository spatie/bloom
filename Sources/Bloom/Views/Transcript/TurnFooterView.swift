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

    /// More chips than this and the footer stops being a footer.
    private static let visibleFileLimit = 6

    @State private var files: [TurnFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                Text(TurnDuration.format(durationMS))
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
                ViewThatFits(in: .horizontal) {
                    fileChips(limit: Self.visibleFileLimit)
                    fileChips(limit: 3)
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
        }
        .task(id: row.seq) { await scanFiles() }
    }

    // MARK: Turn facts

    /// Read through the same cache the rows use. The footer asks for the result three times in one
    /// pass, and a result payload is one of the larger ones in the file.
    private var result: AgentResult? {
        guard case .result(let value)? = TranscriptEventCache.event(rowID: row.id, payload: row.payload) else {
            return nil
        }
        return value
    }

    private var succeeded: Bool { result?.succeeded != false }

    /// How many calls the CLI declined during the turn. Reported on the `result` line, which is
    /// otherwise a plain success: a turn in which every shell call was denied ends with
    /// `is_error` false and `subtype` "success", so without this the footer put a green tick under
    /// an agent that had been stopped at every door.
    private var denials: Int { result?.permissionDenials ?? 0 }

    /// Which of the four endings this was, and the sentence it carries. See `TurnEnding`.
    private var outcome: TurnEnding {
        TurnEnding.of(wasStopped: wasStopped, succeeded: succeeded, denials: denials)
    }

    /// The drawing of it. A stop is not a failure and must not borrow the failure's red: it is the
    /// one ending nothing went wrong in, so it is drawn in the ink an ordinary caption uses, with
    /// the Stop button's own symbol in the ring the other three endings use.
    private var appearance: (glyph: String, tint: Color) {
        switch outcome {
        case .finished: ("checkmark.circle", Palette.positive)
        case .denied: ("hand.raised.circle", Palette.warning)
        case .failed: ("exclamationmark.circle", Palette.negative)
        case .stopped: ("stop.circle", Palette.textSecondary)
        }
    }

    private var durationMS: Int { row.durationMS ?? result?.durationMS ?? 0 }

    private var summaryText: String { result?.summary ?? "" }

    // MARK: Actions

    /// Off the main actor: a long turn means decoding every tool call in it, and that must not land
    /// on the frame that scrolled the footer into view.
    private func scanFiles() async {
        let scanned = await Task.detached(priority: .utility) { [rows, seq = row.seq] in
            TurnScan.files(rows: rows, endingAt: seq)
        }.value
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
