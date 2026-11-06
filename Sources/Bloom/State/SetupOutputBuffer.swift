import Synchronization

/// A thread-safe hand-off for streamed output.
///
/// The producer is a subprocess reader on some background thread and the consumer is the main
/// actor. Batching between them is what keeps a chatty script from swamping the UI.
///
/// A `Mutex` rather than a lock next to an unprotected array: the buffer is then unreachable
/// except through the lock, so the type is `Sendable` on the compiler's terms rather than on a
/// promise, and `drain` cannot accidentally read outside it.
final class SetupOutputBuffer: Sendable {
    private let pending = Mutex<[String]>([])

    func append(_ line: String) {
        pending.withLock { $0.append(line) }
    }

    func drain() -> [String] {
        pending.withLock { lines in
            defer { lines.removeAll(keepingCapacity: true) }
            return lines
        }
    }
}
