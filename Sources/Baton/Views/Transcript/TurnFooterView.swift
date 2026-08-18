import SwiftUI
import AppKit
import BatonCore

/// The line that closes a turn: how long it took, what it changed, and the handles to do something
/// with it.
///
/// The files come from the turn's own Edit and Write calls rather than from git, because git only
/// knows the sum of every turn and this has to answer "what did that answer just do".
struct TurnFooterView: View {
    var rows: [TranscriptRow]
    var row: TranscriptRow

    /// More chips than this and the footer stops being a footer.
    private static let visibleFileLimit = 6

    @State private var files: [TurnFile] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            HStack(spacing: TranscriptLayout.block) {
                Image(systemName: succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(Typo.micro)
                    .imageScale(.medium)
                    .foregroundStyle(succeeded ? Palette.positive : Palette.negative)

                Text(TurnDuration.format(durationMS))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textSecondary)
                    .monospacedDigit()

                if let cost = result?.usage.costUSD, cost > 0 {
                    Text(String(format: "$%.3f", cost))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .monospacedDigit()
                }

                fileChips

                Spacer(minLength: TranscriptLayout.tight)

                Button {
                    copy(summaryText)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(Typo.micro)
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help("Copy this answer")

                Menu {
                    Button("Copy answer") { copy(summaryText) }
                    Button("Copy files touched") { copy(files.map(\.path).joined(separator: "\n")) }
                    Button("Copy raw event") { copy(String(decoding: row.payload, as: UTF8.self)) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Typo.micro)
                        .imageScale(.medium)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More for this turn")
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, TranscriptLayout.inset)
            .padding(.vertical, TranscriptLayout.inset)
        }
        .task(id: row.seq) {
            // Off the main actor: a long turn means decoding every tool call in it, and that must
            // not land on the frame that scrolled the footer into view.
            let scanned = await Task.detached(priority: .utility) { [rows, seq = row.seq] in
                TurnScan.files(rows: rows, endingAt: seq)
            }.value
            files = scanned
        }
    }

    @ViewBuilder
    private var fileChips: some View {
        ForEach(files.prefix(Self.visibleFileLimit)) { file in
            HStack(spacing: TranscriptLayout.tight * 2) {
                Text(file.name)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                DiffStatLabel(additions: file.additions, deletions: file.deletions, compact: true)
            }
            .padding(.horizontal, TranscriptLayout.inset - 1)
            .padding(.vertical, TranscriptLayout.tight)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
            .help(file.path)
        }

        if files.count > Self.visibleFileLimit {
            Chip(text: "+\(files.count - Self.visibleFileLimit) more")
        }
    }

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

/// A file a turn touched, with the line counts taken from the tool calls themselves.
struct TurnFile: Identifiable, Hashable, Sendable {
    var path: String
    var additions: Int
    var deletions: Int

    var id: String { path }
    var name: String { ToolPresenter.basename(path) }
}

/// Walks one turn backwards, collecting what it wrote.
enum TurnScan {
    /// A turn with more rows than this is pathological, and the footer is not worth the scan.
    private static let scanLimit = 400

    static func files(rows: [TranscriptRow], endingAt seq: Int) -> [TurnFile] {
        guard let end = position(of: seq, in: rows) else { return [] }

        var totals: [String: TurnFile] = [:]
        var order: [String] = []
        var index = end - 1
        var scanned = 0

        while index >= 0, scanned < scanLimit {
            let row = rows[index]
            // A result row is the end of the previous turn, so this one starts just after it.
            if row.kind == .result { break }
            if row.kind == .toolUse {
                absorb(row, into: &totals, order: &order)
            }
            index -= 1
            scanned += 1
        }

        return order.reversed().compactMap { totals[$0] }
    }

    private static func absorb(_ row: TranscriptRow, into totals: inout [String: TurnFile], order: inout [String]) {
        guard case .toolUse(let use)? = AgentEvent.decode(line: String(decoding: row.payload, as: UTF8.self)) else {
            return
        }

        var added = 0
        var removed = 0
        let path: String

        switch use.name {
        case "Write":
            path = use.input["file_path"]?.stringValue ?? ""
            added = ToolPresenter.lineCount(use.input["content"]?.stringValue ?? "")

        case "Edit":
            path = use.input["file_path"]?.stringValue ?? ""
            added = ToolPresenter.lineCount(use.input["new_string"]?.stringValue ?? "")
            removed = ToolPresenter.lineCount(use.input["old_string"]?.stringValue ?? "")

        case "MultiEdit":
            path = use.input["file_path"]?.stringValue ?? ""
            for edit in use.input["edits"]?.arrayValue ?? [] {
                added += ToolPresenter.lineCount(edit["new_string"]?.stringValue ?? "")
                removed += ToolPresenter.lineCount(edit["old_string"]?.stringValue ?? "")
            }

        case "NotebookEdit":
            path = use.input["notebook_path"]?.stringValue ?? ""
            added = ToolPresenter.lineCount(use.input["new_source"]?.stringValue ?? "")

        default:
            return
        }

        guard !path.isEmpty else { return }

        if var existing = totals[path] {
            existing.additions += added
            existing.deletions += removed
            totals[path] = existing
        } else {
            totals[path] = TurnFile(path: path, additions: added, deletions: removed)
            order.append(path)
        }
    }

    /// Rows are stored in sequence order, so finding the turn boundary is a binary search rather
    /// than a walk over every row in the session.
    private static func position(of seq: Int, in rows: [TranscriptRow]) -> Int? {
        var low = 0
        var high = rows.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if rows[middle].seq == seq { return middle }
            if rows[middle].seq < seq { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}

/// Turn durations read the way Conductor writes them: "1m, 52.6s" while the tenths still mean
/// something, "31m, 43s" once they do not.
enum TurnDuration {
    static func format(_ milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }

        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return minutes < 10
            ? String(format: "%dm, %.1fs", minutes, remainder)
            : String(format: "%dm, %.0fs", minutes, remainder)
    }

    /// The compact form a single row uses, where there is room for four characters at most.
    static func short(_ milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 { return String(format: "%.1fs", Double(milliseconds) / 1000) }
        return "\(milliseconds / 60_000)m"
    }
}
