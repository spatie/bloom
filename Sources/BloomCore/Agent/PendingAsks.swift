import Foundation
import Synchronization

/// The permission questions one run is blocked on, reachable without actor isolation.
///
/// Both runners keep one of these beside their actor, because the two moments it is read are the
/// two moments the actor is least available: Stop and app termination have to deny every open
/// question synchronously, and a stored grant being looked up must not race a person answering.
/// `take` is the claim that settles that race: whoever takes the ask out of the pile answers it,
/// and the loser does nothing, so the CLI can never receive two answers to one request id.
///
/// One type for both backends, deliberately. `SessionRunner`'s head argues that runner surface is
/// not shared, and it is right about the protocol; this is bookkeeping, not protocol, and it was
/// two identical classes under two identical comments, which is the same reasoning that moved the
/// grant loop into `PermissionGrant.all`.
///
/// `Mutex` rather than `NSLock` plus `@unchecked Sendable`, for the reason given on `EventFanout`
/// in `SessionRunner`. The lock is only ever held across an array access.
final class PendingAsks: Sendable {
    private let asks = Mutex<[PermissionAsk]>([])

    var all: [PermissionAsk] { asks.withLock { $0 } }

    var isEmpty: Bool { asks.withLock(\.isEmpty) }

    func add(_ ask: PermissionAsk) {
        asks.withLock { asks in
            // The request id is the identity. A replayed line is the same question, not a second.
            guard !asks.contains(where: { $0.requestID == ask.requestID }) else { return }
            asks.append(ask)
        }
    }

    /// Claim one, so two answers racing the same question cannot both reach the pipe.
    func take(_ requestID: String) -> PermissionAsk? {
        asks.withLock { asks -> PermissionAsk? in
            guard let index = asks.firstIndex(where: { $0.requestID == requestID }) else { return nil }
            return asks.remove(at: index)
        }
    }

    func contains(_ requestID: String) -> Bool {
        asks.withLock { asks in asks.contains { $0.requestID == requestID } }
    }

    func remove(_ requestID: String) {
        asks.withLock { $0.removeAll { $0.requestID == requestID } }
    }

    /// Take the lot, in one step, so nothing can be answered twice on the way out.
    func drain() -> [PermissionAsk] {
        asks.withLock { asks in
            let all = asks
            asks = []
            return all
        }
    }
}
