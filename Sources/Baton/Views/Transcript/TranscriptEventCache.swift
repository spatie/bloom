import Foundation
import BatonCore

/// Prevents stable transcript rows from recursively decoding JSON on every streamed token.
///
/// The payload bytes are part of the key alongside the row ID because an updated store row may
/// retain its identity. Exact byte equality prevents a cached event from surviving that change.
@MainActor
enum TranscriptEventCache {
    private static let limit = 256
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

    init(rowID: Int64, payload: Data) {
        self.rowID = rowID
        self.payload = payload
        var hasher = Hasher()
        hasher.combine(rowID)
        hasher.combine(payload)
        cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TranscriptPayloadKey else { return false }
        return cachedHash == other.cachedHash
            && rowID == other.rowID
            && payload == other.payload
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
