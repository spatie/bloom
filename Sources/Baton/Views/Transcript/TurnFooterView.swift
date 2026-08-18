import SwiftUI
import AppKit
import BatonCore

/// The line that closes a turn: how long it took, what it changed, and the handles to do something
/// with it.
struct TurnFooterView: View {
    var rows: [TranscriptRow]
    var row: TranscriptRow

    /// More chips than this and the footer stops being a footer.
    private static let visibleFileLimit = 6

    @State private var files: [TurnFile] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inset to the column the footer's own contents start on, rather than to the pane.
            // A rule that stops six points short of the text under it looks like a mistake, and
            // this one closes a turn, so it has to read as drawn on purpose.
            Hairline()
                .padding(.horizontal, TranscriptLayout.inset)

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
                    // Narrow presentation, so a footer in a non-US locale reads "$0.177" rather
                    // than "0,177 US$" and stays the width of a footer.
                    Text(cost, format: .currency(code: "USD")
                        .presentation(.narrow)
                        .precision(.fractionLength(3)))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .monospacedDigit()
                        .fixedSize()
                }

                ForEach(files.prefix(Self.visibleFileLimit)) { file in
                    TurnFileChip(file: file)
                }

                if files.count > Self.visibleFileLimit {
                    Chip(text: "+\(files.count - Self.visibleFileLimit) more")
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
