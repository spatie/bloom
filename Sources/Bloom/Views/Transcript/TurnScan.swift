import Foundation
import BloomCore

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

        // Codex writes a patch rather than a call per file: one `fileChange` item can touch
        // several, and each change carries a real unified diff, so what comes out of here is
        // measured rather than estimated from the strings a tool was handed.
        if case .fileChange(let change)? = CodexTranslation.item(in: use.input) {
            for update in change.changes {
                merge(path: update.path, added: update.addedLines, removed: update.removedLines,
                      into: &totals, order: &order)
            }
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

        merge(path: path, added: added, removed: removed, into: &totals, order: &order)
    }

    private static func merge(
        path: String,
        added: Int,
        removed: Int,
        into totals: inout [String: TurnFile],
        order: inout [String]
    ) {
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

/// What a turn wrote, kept for as long as the footer that asked is likely to come back.
///
/// The scan is a walk backwards over up to four hundred rows, decoding the payload of every tool
/// call among them, and it hangs off a `.task` on the footer. A `LazyVStack` realises a row when it
/// approaches the viewport and drops it when it leaves, so scrolling through a long session re-ran
/// the whole scan for every footer that went past, each time to arrive at the answer it arrived at
/// last time.
///
/// **Keyed on the result row's own id, and that is safe for the reason `TranscriptEventCache` gives
/// for the payloads it holds.** A turn's rows are the stored messages between the previous result
/// row and this one; they are written once as they arrive and never rewritten, and a result row is
/// the last of them, so a turn that has one has stopped changing. Nothing that arrives afterwards
/// belongs to it.
///
/// `@MainActor` because that is where a footer asks and where the answer is assigned. The scan
/// itself still runs off the actor.
@MainActor
enum TurnScanCache {
    /// Roughly the footers a long scroll passes through, and a turn's file list is a handful of
    /// paths and two integers each.
    private static let limit = 512

    private static let values: NSCache<NSNumber, TurnFilesBox> = {
        let cache = NSCache<NSNumber, TurnFilesBox>()
        cache.countLimit = limit
        return cache
    }()

    static func files(rowID: Int64) -> [TurnFile]? {
        values.object(forKey: NSNumber(value: rowID))?.value
    }

    static func remember(_ files: [TurnFile], rowID: Int64) {
        values.setObject(TurnFilesBox(files), forKey: NSNumber(value: rowID))
    }
}

/// `NSCache` cannot hold a value type. See `TranscriptEventCache`, which keeps its boxes beside it
/// for the same reason.
private final class TurnFilesBox {
    let value: [TurnFile]

    init(_ value: [TurnFile]) { self.value = value }
}
