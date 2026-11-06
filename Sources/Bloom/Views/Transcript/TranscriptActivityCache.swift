import BloomCore
import Foundation

/// A fold can redraw while its last call runs. Keep the typed reading of older calls by row ID.
enum TranscriptActivityCache {
    private static let limit = 8_192
    nonisolated(unsafe) private static let actions: NSCache<NSNumber, ActionBox> = {
        let cache = NSCache<NSNumber, ActionBox>()
        cache.countLimit = limit
        return cache
    }()

    static func prime(rowID: Int64, use: AgentToolUse) {
        let key = NSNumber(value: rowID)
        guard actions.object(forKey: key) == nil else { return }
        actions.setObject(ActionBox(TranscriptActivitySummary.Action.of(use)), forKey: key)
    }

    static func label(for work: TranscriptFold.Work, in rows: [TranscriptRow]) -> String? {
        let calls: [TranscriptActivitySummary.Call] = work.rows.compactMap { item in
            let row = rows[item.index]
            guard row.kind == .toolUse else { return nil }
            let key = NSNumber(value: row.id)
            let action: TranscriptActivitySummary.Action
            if let cached = actions.object(forKey: key) {
                action = cached.value
            } else {
                guard case .toolUse(let use)? = TranscriptEventCache.event(
                    rowID: row.id, payload: row.payload
                ) else { return nil }
                action = TranscriptActivitySummary.Action.of(use)
                actions.setObject(ActionBox(action), forKey: key)
            }
            return TranscriptActivitySummary.Call(action: action, isRunning: row.resultPayload == nil)
        }
        return TranscriptActivitySummary.label(calls)
    }
}

private final class ActionBox {
    let value: TranscriptActivitySummary.Action

    init(_ value: TranscriptActivitySummary.Action) { self.value = value }
}
