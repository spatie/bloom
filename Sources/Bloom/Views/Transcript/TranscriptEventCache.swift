import Foundation
import BloomCore

/// Prevents stable transcript rows from recursively decoding JSON on every streamed token.
///
/// The payload bytes are part of the key alongside the row ID because an updated store row may
/// retain its identity. Exact byte equality prevents a cached event from surviving that change.
@MainActor
enum TranscriptEventCache {
    /// **Bounded by bytes, not by rows.** `countLimit` was 256, and a real transcript is longer
    /// than that: the workspace this was measured against holds 1,306 messages, so one scroll from
    /// the bottom to the top evicted every row and decoded all of them again on the way back.
    ///
    /// `ScrollProbe` put a number on it: `AgentEvent.decode` and `JSONValue.parse` together took
    /// about six per cent of the main thread while nothing was happening but scrolling.
    ///
    /// **Be clear about what this did not fix.** Frame times either side of the change are the
    /// same to within noise: 16.7% of frames late before, 17.0% after, p95 24ms and 23ms, p99 35ms
    /// and 33ms, over four sweeps of a 1,306 message transcript. The decoding was real waste and
    /// is worth not doing, but the judder is somewhere else. Forty per cent of the main thread is
    /// inside `LazySubviewPlacements.placeSubviews` and `StackPlacement.measureBackwards`, and the
    /// scroll view's content height falls from 18,374 points to 10,167 over a single pass, which
    /// is SwiftUI replacing estimated row heights with measured ones and re-placing everything
    /// above. Anybody coming here to make scrolling smoother should start there and not with this.
    ///
    /// Zero means no limit on the count, which is what `totalCostLimit` is already for. The bytes
    /// are the thing worth bounding: a `Write` call carries the whole file the agent wrote, and one
    /// such row can outweigh a thousand ordinary ones. Eight megabytes holds a long transcript of
    /// ordinary rows and still evicts when several enormous ones arrive, which is the shape the
    /// cost limit was chosen for in the first place.
    private static let limit = 0
    private static let costLimit = 8 * 1_024 * 1_024

    private static let events: NSCache<TranscriptPayloadKey, TranscriptEventBox> = {
        let cache = NSCache<TranscriptPayloadKey, TranscriptEventBox>()
        cache.countLimit = limit
        cache.totalCostLimit = costLimit
        return cache
    }()

    private static let jsonValues: NSCache<TranscriptPayloadKey, TranscriptJSONBox> = {
        let cache = NSCache<TranscriptPayloadKey, TranscriptJSONBox>()
        cache.countLimit = limit
        cache.totalCostLimit = costLimit
        return cache
    }()

    static func event(rowID: Int64, payload: Data) -> AgentEvent? {
        let key = TranscriptPayloadKey(rowID: rowID, payload: payload)
        if let cached = events.object(forKey: key) { return cached.value }

        let value = AgentEvent.decode(line: String(decoding: payload, as: UTF8.self))
        events.setObject(TranscriptEventBox(value), forKey: key, cost: payload.count)
        return value
    }

    static func json(rowID: Int64, payload: Data) -> JSONValue? {
        let key = TranscriptPayloadKey(rowID: rowID, payload: payload)
        if let cached = jsonValues.object(forKey: key) { return cached.value }

        let value = JSONValue.parse(payload)
        jsonValues.setObject(TranscriptJSONBox(value), forKey: key, cost: payload.count)
        return value
    }
}

/// `NSCache` predates generics over value types, so the key and the two payloads it stores have to
/// be classes. They are implementation details of the cache and live with it.
final class TranscriptPayloadKey: NSObject {
    let rowID: Int64
    let payload: Data
    private let cachedHash: Int

    /// **The hash is of the row id and the payload's length, not of the payload.**
    ///
    /// It used to SipHash every byte, and a key is built on every LOOKUP rather than only on a
    /// miss, so asking whether a row's decode was cached cost a pass over the whole row. On the
    /// scroll path that is the expensive thing in the app: a `Write` call carries the entire file
    /// the agent wrote and a tool result carries whatever was read, so scrolling past one turn
    /// hashed hundreds of kilobytes to answer a question the cache then answered instantly.
    ///
    /// `isEqual` below stopped comparing the bytes for exactly this reason and wrote down why. The
    /// hash is the other half of the same argument and was left behind: what identifies a stored
    /// row is its id, whose payload is written once and never rewritten.
    /// `TranscriptPresentationCache` states the conclusion plainly, keys on the row id alone, and
    /// has done since it was written.
    ///
    /// The length stays in both, as the cheap half of the guard the byte comparison used to be. A
    /// row that somehow IS rewritten into something of a different size still misses.
    init(rowID: Int64, payload: Data) {
        self.rowID = rowID
        self.payload = payload
        var hasher = Hasher()
        hasher.combine(rowID)
        hasher.combine(payload.count)
        cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    /// The lengths rather than the bytes, and the hash above is what makes that safe.
    ///
    /// Two keys reach this having already agreed on a SipHash of the whole payload and on the row
    /// id. `Data.==` then memcmp'd the payload again, in full, on every cache hit: 1.6MB across
    /// 189 rows in a real session, on the main thread, on every pass that decodes a row. That is
    /// the same measurement `TranscriptRowView.==` records for the comparison it refuses to make,
    /// and the same answer: what identifies a stored row is its id, and its payload is written once
    /// and never rewritten. The length is kept as the cheap half of the guard the byte comparison
    /// was, for a row that somehow is rewritten into something of a different size.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TranscriptPayloadKey else { return false }
        return cachedHash == other.cachedHash
            && rowID == other.rowID
            && payload.count == other.payload.count
    }
}

final class TranscriptEventBox {
    let value: AgentEvent?

    init(_ value: AgentEvent?) { self.value = value }
}

final class TranscriptJSONBox {
    let value: JSONValue?

    init(_ value: JSONValue?) { self.value = value }
}
