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

    /// More chips than this and the footer stops being a footer.
    private static let visibleFileLimit = 6

    @State private var files: [TurnFile] = []
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inset to the column the footer's own contents start on, rather than to the pane.
            // A rule that stops six points short of the text under it looks like a mistake, and
            // this one closes a turn, so it has to read as drawn on purpose.
            //
            // The vertical air is the same rung on both sides, because this rule belongs to
            // neither: it separates a reply from the reply's own footer, and a rule that sits
            // nearer one side reads as a heading for that side. Six of its own above and six
            // below; the paragraph above it already carries the prose row's own six point inset,
            // and the footer row below adds its six, so both gaps are drawn at twelve. Measured
            // off a window capture: ten and six before, twelve and twelve now.
            Hairline()
                .padding(.horizontal, TranscriptLayout.inset)
                .padding(.vertical, TranscriptLayout.inset)

            // A turn's cost and duration are the numbers a user goes looking for, so they sit a
            // rung above the counts and timings that decorate a single row.
            HStack(spacing: TranscriptLayout.block) {
                Image(systemName: succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(Typo.caption)
                    .imageScale(.medium)
                    .foregroundStyle(succeeded ? Palette.positive : Palette.negative)
                    .accessibilityLabel(succeeded ? "Finished" : "Failed")

                Text(TurnDuration.format(durationMS))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .monospacedDigit()
                    .fixedSize()

                if let cost = result?.usage.costUSD, cost > 0 {
                    // Locale pinned to en_US, not merely the currency code, because the two are
                    // separate decisions and only one of them was being made. Narrow presentation
                    // fixes the symbol and leaves the separators alone, so on a Belgian region
                    // this printed a dollar and a European comma together: $1.02 came out as
                    // "1,020 $", and a session that cost $119 read as "119,000 $". The number is
                    // dollars from the provider and it is shown as dollars are written.
                    Text(cost, format: .currency(code: "USD")
                        .locale(Locale(identifier: "en_US"))
                        .presentation(.narrow)
                        .precision(.fractionLength(3)))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .monospacedDigit()
                        .fixedSize()
                }

                // How many chips there is room for, rather than a fixed count. The chips are the
                // only thing in this row that can be dropped, and the alternative was every one of
                // them being squeezed to an empty rounded rectangle while the duration, the cost
                // and the two buttons kept their width.
                ViewThatFits(in: .horizontal) {
                    fileChips(limit: Self.visibleFileLimit)
                    fileChips(limit: 3)
                    fileChips(limit: 1)
                    countChip
                    Color.clear.frame(width: 0, height: 0)
                }

                Spacer(minLength: TranscriptLayout.tight)

                Button(action: copyAnswer) {
                    Label("Copy this answer", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(Typo.caption)
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help(copied ? "Copied" : "Copy this answer")

                Menu {
                    Button("Copy answer", action: copyAnswer)
                    Button("Copy files touched", action: copyFiles)
                    Button("Copy raw event", action: copyRawEvent)
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

    private func copyAnswer() {
        copy(summaryText)
    }

    private func copyFiles() {
        copy(files.map(\.path).joined(separator: "\n"))
    }

    private func copyRawEvent() {
        copy(String(decoding: row.payload, as: UTF8.self))
    }

    private func copy(_ text: String) {
        Clipboard.copy(text)
        copied = true
        // Cancelled and restarted, so a second copy inside the window does not have the first
        // one's timer clear the label out from under it a moment later.
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: Clipboard.flashDuration)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
