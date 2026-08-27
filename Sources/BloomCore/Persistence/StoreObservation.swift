import Foundation
import Synchronization
import os

/// A table in the store, named by the table it is derived from.
///
/// The raw value is the SQLite table name because that is where the domain comes from: the update
/// hook hands over the table a row change landed in, and this enum is how that string becomes
/// something a subscriber can switch on. A writer therefore cannot forget to say what it changed,
/// and cannot say something that is not true, which is the whole reason emission lives under
/// `Store` rather than beside each of its methods.
///
/// Table level and not row level on purpose. A row level event would have to be written by hand
/// next to the write that caused it, which is exactly the thing that drifts: the write moves, the
/// event stays. A single untyped bell was the other option and was worse, because it would force
/// a full reload on every appended message during a streaming turn.
public enum StoreDomain: String, Sendable, Hashable, CaseIterable {
    case repos
    case workspaces
    case sessions
    case messages
    case terminalTabs = "terminal_tabs"
    case settings
    case drafts
    case reviewComments = "review_comments"
    case permissionGrants = "permission_grants"
    case permissionAsks = "permission_asks"
    case agentQuotas = "agent_quotas"
    case quickPrompts = "quick_prompt"
}

/// Who hears about a committed write, and how they are stopped from drowning in them.
///
/// One hub per database file, shared by every connection this process has open on it, because the
/// update hook is per connection and Bloom opens the same file twice: the app's `Store` and
/// `IntentDatabase`'s, so a Shortcut reading while the window is up is two connections and one
/// database. Without the hub a workspace created through one of them would be invisible to a
/// subscriber on the other.
///
/// **Two rules for anything that handles a change, and they are not style preferences.**
///
/// 1. **A handler reads and publishes. It does not write.** A write ticks the hub, which wakes the
///    handler, which writes, which ticks the hub. Nothing would overflow: the wake-ups are
///    buffered and the consumer is its own task. It would instead livelock at whatever duty cycle
///    the handler's work happens to run at, which presents as an app that is warm and busy and
///    does nothing, and it would be introduced by a change that looks entirely reasonable.
///    `AppModel.reload` is safe because it only reads.
/// 2. **A write that genuinely must happen in response to a change compares and skips inside the
///    actor.** `Store.updateDiffStat` is the pattern: it reads the row, returns without writing
///    when the numbers already match, and so cannot feed itself. An identical-value `UPDATE` still
///    fires the update hook, so "the value did not change" is not a defence SQLite offers.
///
/// The counter below is the cheap insurance for the day somebody does it anyway.
///
/// **In-process only, and deliberately.** The hook sees the writes made on its own connection; the
/// hub extends that to every connection in this process, and no further. Bloom and Bloom Dev are
/// separate processes on separate databases, so nothing today is missed. If two processes ever
/// shared one file, each would see only its own writes. The honest fix at that point is to poll
/// `PRAGMA data_version`, which changes whenever another connection commits, and feed the result
/// into this same hub. No subscriber would change. It is not built now because nothing needs it.
public final class StoreChangeHub: Sendable {
    private struct Subscriber {
        let interest: Set<StoreDomain>
        var pending: Set<StoreDomain>
        let wake: AsyncStream<Void>.Continuation
    }

    private struct State {
        var subscribers: [Int: Subscriber] = [:]
        var nextID = 0
        var windowStart: ContinuousClock.Instant?
        var windowCount = 0
    }

    private let state = Mutex(State())

    /// A publish rate no honest workload reaches, over a window short enough to still be running
    /// when somebody looks. A streaming turn appending messages as fast as an agent can produce
    /// them is a few tens of commits a second; two hundred a second sustained for five seconds is
    /// a handler writing back into the store it is listening to.
    private static let runawayWindow = Duration.seconds(5)
    private static let runawayCount = 1_000

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.spatie.bloom",
        category: "store"
    )

    /// The hub for a database file, made once and shared by every connection on it.
    ///
    /// Keyed on the path with symlinks resolved, because `/var` is `/private/var` on this machine
    /// and a test writing under `NSTemporaryDirectory()` gets handed one spelling and `Store` the
    /// other. Two hubs on one file is the bug this exists to avoid, so the key has to be the file
    /// rather than the string somebody typed.
    ///
    /// `:memory:` is not a file. Two in-memory databases are two databases with no relationship at
    /// all, so each gets a hub of its own.
    ///
    /// The registry holds its hubs weakly. A hub is kept alive by the connections using it and by
    /// anything iterating it, and a process that opens hundreds of throwaway databases (the test
    /// suite does exactly that) should not accumulate one entry per file for the whole run.
    static func shared(forPath path: String) -> StoreChangeHub {
        guard path != ":memory:" else { return StoreChangeHub() }
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return registry.withLock { registry in
            if let existing = registry[key]?.hub { return existing }
            let hub = StoreChangeHub()
            registry[key] = WeakHub(hub: hub)
            // Cheap enough to do inline, and it keeps the dictionary the size of the databases
            // actually open rather than the size of every database ever opened.
            registry = registry.filter { $0.value.hub != nil }
            return hub
        }
    }

    private struct WeakHub {
        weak var hub: StoreChangeHub?
    }

    private static let registry = Mutex<[String: WeakHub]>([:])

    /// Everything one commit touched, delivered to whoever asked for any of it.
    ///
    /// Called after the write has committed and never from inside the hook, so a transaction that
    /// rolls back (`Store.appendNext` retries on a sequence collision, sixteen times) cannot
    /// announce a row that does not exist.
    func publish(_ domains: Set<StoreDomain>) {
        guard !domains.isEmpty else { return }
        var runaway: Int?
        let waking = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            runaway = countTowardsRunaway(&state)
            var waking: [AsyncStream<Void>.Continuation] = []
            for (id, subscriber) in state.subscribers {
                let relevant = domains.intersection(subscriber.interest)
                guard !relevant.isEmpty else { continue }
                // This is the whole of the coalescing, and it is structural rather than timed.
                // A subscriber still working through its last batch has a non-empty pending set,
                // so it is not woken again; everything that happened meanwhile is waiting for it
                // as one batch when it comes back. No debounce interval to pick and get wrong.
                let wasIdle = state.subscribers[id]?.pending.isEmpty ?? false
                state.subscribers[id]?.pending.formUnion(relevant)
                if wasIdle, let continuation = state.subscribers[id]?.wake {
                    waking.append(continuation)
                }
            }
            return waking
        }
        // Outside the lock. `yield` runs the stream's own machinery, and a writer must never be
        // held up by it: the set is bounded by the number of domains, so nothing here can grow.
        for continuation in waking { continuation.yield() }
        if let runaway {
            Self.log.error(
                """
                \(runaway, privacy: .public) store commits in the last \
                \(Self.runawayWindow.components.seconds, privacy: .public) seconds. Something \
                handling a change is very likely writing back into the store it is listening to. \
                See the two rules on StoreChangeHub.
                """
            )
        }
    }

    /// Counts publishes, and answers with the count for a window that ran away.
    ///
    /// This is the cheap insurance for the day one of the two rules above is broken. A livelock
    /// there does not crash and does not overflow anything: it presents as an app that is warm,
    /// busy and idle at the same time, which is a miserable thing to find by reading code. Five
    /// lines here name it in Console instead.
    private func countTowardsRunaway(_ state: inout State) -> Int? {
        let now = ContinuousClock.now
        guard let started = state.windowStart else {
            state.windowStart = now
            state.windowCount = 1
            return nil
        }
        state.windowCount += 1
        guard now - started >= Self.runawayWindow else { return nil }
        let count = state.windowCount
        state.windowStart = now
        state.windowCount = 0
        return count > Self.runawayCount ? count : nil
    }

    fileprivate func subscribe(to interest: Set<StoreDomain>) -> (id: Int, wakes: AsyncStream<Void>) {
        // One buffered wake-up is all a subscriber can use. The payload is the pending set, so a
        // second wake-up carries nothing the first does not already deliver.
        let (wakes, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        let id = state.withLock { state -> Int in
            state.nextID += 1
            state.subscribers[state.nextID] = Subscriber(
                interest: interest, pending: [], wake: continuation
            )
            return state.nextID
        }
        // Weak, because the hub holds the continuation that holds this closure. Fires when the
        // iterating task is cancelled and when the iterator is simply dropped, which is what makes
        // teardown something the caller does not have to remember.
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        return (id, wakes)
    }

    fileprivate func drain(_ id: Int) -> Set<StoreDomain> {
        state.withLock { state in
            guard let pending = state.subscribers[id]?.pending else { return [] }
            state.subscribers[id]?.pending = []
            return pending
        }
    }

    /// How many subscriptions are registered right now.
    ///
    /// For the tests, and specifically for the one that asserts a cancelled task takes its
    /// subscription with it. Teardown that happens by itself is the kind of thing that quietly
    /// stops happening, and a leaked subscriber is a leak nothing else would ever show.
    var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    private func unsubscribe(_ id: Int) {
        _ = state.withLock { $0.subscribers.removeValue(forKey: id) }
    }
}

/// The domains a subscriber cares about, one batch at a time.
///
/// Iterating this is the whole subscription: it registers on the first `next`, and it tears itself
/// down when the task iterating it is cancelled or when the iterator goes away.
///
/// A batch is what has changed since the last one was taken, never a queue of individual writes,
/// so a slow consumer falls behind by content rather than by count. Read the rules on
/// `StoreChangeHub` before writing a handler: they read and publish, they do not write.
public struct StoreChanges: AsyncSequence, Sendable {
    public typealias Element = Set<StoreDomain>

    private let hub: StoreChangeHub
    private let interest: Set<StoreDomain>

    init(hub: StoreChangeHub, interest: Set<StoreDomain>) {
        self.hub = hub
        self.interest = interest
    }

    public func makeAsyncIterator() -> Iterator {
        let subscription = hub.subscribe(to: interest)
        return Iterator(hub: hub, id: subscription.id, wakes: subscription.wakes.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let hub: StoreChangeHub
        private let id: Int
        private var wakes: AsyncStream<Void>.Iterator

        init(hub: StoreChangeHub, id: Int, wakes: AsyncStream<Void>.Iterator) {
            self.hub = hub
            self.id = id
            self.wakes = wakes
        }

        public mutating func next() async -> Set<StoreDomain>? {
            // A wake-up whose batch has already been taken is possible: the publisher yields after
            // dropping the lock, so a drain can land in between. Nothing is lost by looping, and
            // handing back an empty set would make every caller check for one.
            while await wakes.next() != nil {
                let batch = hub.drain(id)
                if !batch.isEmpty { return batch }
            }
            return nil
        }
    }
}
