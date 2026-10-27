import BloomCore
import Foundation

/// Where a completed turn puts its copy control, kept across transcript body passes.
///
/// Finding it walks backwards through the turn and decodes its final prose. A transcript body is
/// rebuilt for every streamed delta, while a stored result and every row before it are immutable,
/// so repeating that work would put old turns back on the live typing path. The result row ID is a
/// complete key for the reason `TranscriptEventCache` gives for the payloads it holds.
@MainActor
enum TurnAnswerPlacementCache {
    private static let values: NSCache<NSNumber, TurnAnswerPlacementBox> = {
        let cache = NSCache<NSNumber, TurnAnswerPlacementBox>()
        cache.countLimit = 512
        return cache
    }()

    static func placement(
        rowID: Int64, build: () -> TurnAnswer.Placement?
    ) -> TurnAnswer.Placement? {
        let key = NSNumber(value: rowID)
        if let known = values.object(forKey: key) { return known.value }
        guard let value = build() else { return nil }
        values.setObject(TurnAnswerPlacementBox(value), forKey: key)
        return value
    }
}

private final class TurnAnswerPlacementBox {
    let value: TurnAnswer.Placement

    init(_ value: TurnAnswer.Placement) { self.value = value }
}
