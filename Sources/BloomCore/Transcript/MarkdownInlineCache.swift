import Synchronization

/// Exact inline source is independent of the surrounding document. Keeping its immutable parse
/// avoids rescanning completed lines on every streaming prefix. Both source bytes and entry count
/// are capped; a single very long line is parsed without being retained.
final class MarkdownInlineCache: Sendable {
    private struct State {
        var values: [[UInt8]: [MarkdownInline]] = [:]
        var order: [[UInt8]] = []
        var bytes = 0
    }

    private let state = Mutex(State())
    private let maximumEntries: Int
    private let maximumBytes: Int

    init(maximumEntries: Int = 512, maximumBytes: Int = 512 * 1_024) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    func value(for source: String, build: () -> [MarkdownInline]) -> [MarkdownInline] {
        // String equality normalises Unicode. Code examples must retain the exact source bytes.
        let key = Array(source.utf8)
        if let cached = state.withLock({ $0.values[key] }) { return cached }
        // Parsing can recursively parse emphasis and links through this same cache. It must
        // happen outside the lock, and duplicate work from concurrent misses is harmless.
        let result = build()
        let bytes = key.count
        guard maximumEntries > 0, bytes <= maximumBytes else { return result }
        state.withLock { storage in
            guard storage.values[key] == nil else { return }
            while !storage.order.isEmpty,
                  storage.order.count >= maximumEntries || storage.bytes + bytes > maximumBytes {
                let oldest = storage.order.removeFirst()
                storage.values[oldest] = nil
                storage.bytes -= oldest.count
            }
            storage.values[key] = result
            storage.order.append(key)
            storage.bytes += bytes
        }
        return result
    }
}
