import Foundation
import BatonCore

/// Walks one turn backwards, collecting what it wrote.
///
/// The files come from the turn's own Edit and Write calls rather than from git, because git only
/// knows the sum of every turn and the footer has to answer "what did that answer just do".
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
