import Foundation
import Synchronization

/// Stop captures the family at the instant it is pressed, before an actor hop or a replacement
/// turn can change which children belong to that intent.
final class CodexChildTurns: Sendable {
    private let state = Mutex<[String: String]>([:])
    func replace(_ turns: [String: String]) { state.withLock { $0 = turns } }
    var snapshot: [String: String] { state.withLock { $0 } }
}

public enum CodexFamilyStop {
    /// A wedged child cannot prevent the parent being interrupted. Every child request receives
    /// its own remaining deadline, and the number of simultaneous requests is bounded.
    public static func interrupt(
        _ turns: [String: String],
        budget: Duration = .seconds(10),
        concurrency: Int = 8,
        send: @escaping @Sendable (String, String, Duration) async -> Void
    ) async {
        let deadline = ContinuousClock.now.advanced(by: budget)
        await withTaskGroup(of: Void.self) { group in
            var pending = turns.makeIterator()
            func add(_ child: (key: String, value: String)) {
                group.addTask {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero, !Task.isCancelled else { return }
                    await send(child.key, child.value, min(.seconds(3), remaining))
                }
            }
            for _ in 0..<max(1, concurrency) {
                if let child = pending.next() { add(child) }
            }
            while await group.next() != nil {
                guard ContinuousClock.now < deadline, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let child = pending.next() { add(child) }
            }
        }
    }
}
