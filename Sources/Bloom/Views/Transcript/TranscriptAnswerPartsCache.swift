import Foundation
import BloomCore

/// A long answer's parts, cut once per stored row. See `TranscriptAnswerParts`.
///
/// Keyed by the row id alone, as `TranscriptPresentationCache` is: a stored answer is written once.
/// `nonisolated(unsafe)` for `TranscriptEventCache`'s reason: `NSCache` locks, and a box holds a `let`.
enum TranscriptAnswerPartsCache {
    nonisolated(unsafe) private static let values: NSCache<NSNumber, TranscriptAnswerPartsBox> = {
        let cache = NSCache<NSNumber, TranscriptAnswerPartsBox>()
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    /// The answer's text in parts, or the text alone when it is not worth cutting.
    static func parts(rowID: Int64, text: String) -> [String] {
        guard text.utf8.count > TranscriptAnswerParts.threshold else { return [text] }
        let key = NSNumber(value: rowID)
        if let cached = values.object(forKey: key) { return cached.parts }
        let parts = TranscriptAnswerParts.split(text)
        values.setObject(TranscriptAnswerPartsBox(parts), forKey: key, cost: text.utf8.count)
        return parts
    }

    /// The parts a stored answer is drawn in, or nil for a row drawn whole.
    static func parts(of row: TranscriptRow) -> [String]? {
        guard row.kind == .assistantText, row.payload.count > TranscriptAnswerParts.threshold,
              case .assistantText(let block)? = TranscriptEventCache.event(rowID: row.id, payload: row.payload)
        else { return nil }
        let parts = parts(rowID: row.id, text: block.text)
        return parts.count > 1 ? parts : nil
    }
}

final class TranscriptAnswerPartsBox: NSObject {
    let parts: [String]

    init(_ parts: [String]) { self.parts = parts }
}
