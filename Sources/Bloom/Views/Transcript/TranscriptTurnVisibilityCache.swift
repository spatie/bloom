import BloomCore
import Foundation

/// Static row decisions used when a completed turn folds its interim work. A transcript body can
/// redraw many times while the live tail streams, so the payload sniff happens once per stored row.
enum TranscriptTurnVisibilityCache {
    nonisolated(unsafe) private static let values: NSCache<NSNumber, VisibilityBox> = {
        let cache = NSCache<NSNumber, VisibilityBox>()
        cache.countLimit = 8_192
        return cache
    }()

    static func keepsVisible(_ row: TranscriptRow) -> Bool {
        if row.kind == .error { return true }
        if row.kind == .permissionAsk && row.permissionDecision == nil { return true }

        let key = NSNumber(value: row.id)
        if let cached = values.object(forKey: key) { return cached.value }
        let fact = row.foldFact()
        let value = fact.drawsNothing || fact.featured
        values.setObject(VisibilityBox(value), forKey: key)
        return value
    }
}

private final class VisibilityBox {
    let value: Bool

    init(_ value: Bool) { self.value = value }
}
