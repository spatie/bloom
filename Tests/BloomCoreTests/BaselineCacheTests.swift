import Foundation
import Testing
@testable import BloomCore

/// What `Git.baseline` is allowed to remember.
///
/// The suite exists because the cache trades correctness risk for energy: a merge base that is
/// remembered one moment too long is the squash-merge bug in `BaselineTests` all over again, with
/// every merged file shown as this workspace's work. So the two things worth pinning are that the
/// key changes whenever any ref moves, and that an answer is only ever handed back for a key that
/// matched exactly. The third is the coalescing: two callers arriving together resolve once, and
/// a caller whose refs have moved does not join the flight it invalidated.
@Suite("The remembered base of a workspace diff")
struct BaselineCacheTests {
    private let head = "1111111111111111111111111111111111111111"
    private let local = "2222222222222222222222222222222222222222"
    private let remote = "3333333333333333333333333333333333333333"

    // MARK: - The key

    @Test("the three refs go to rev-parse in a fixed order")
    func asks() {
        #expect(BaselineFingerprint.arguments(base: "main", remote: "origin") == [
            "rev-parse", "--revs-only", "HEAD", "main", "refs/remotes/origin/main",
        ])
    }

    @Test("a ref that moves changes the key")
    func moves() {
        let before = BaselineFingerprint.make("\(head)\n\(local)\n\(remote)\n")
        let after = BaselineFingerprint.make("\(head)\n\(local)\n\(head)\n")

        #expect(before != nil)
        #expect(before != after)
    }

    /// The reason `--revs-only` is used rather than `--verify`: it drops what it cannot resolve
    /// and still exits zero, so a repository that grows an `origin/main` answers differently from
    /// one that has never had it without anybody having to work out which line was which.
    @Test("a ref that appears changes the key")
    func appears() {
        let withoutRemote = BaselineFingerprint.make("\(head)\n\(local)\n")
        let withRemote = BaselineFingerprint.make("\(head)\n\(local)\n\(remote)\n")

        #expect(withoutRemote != withRemote)
    }

    @Test("trailing whitespace is not a different graph")
    func whitespace() {
        #expect(
            BaselineFingerprint.make("\(head)\n\(local)\n")
                == BaselineFingerprint.make("  \(head)  \n\(local)\n\n")
        )
    }

    /// A worktree that has been removed answers nothing at all, and two of those must not share
    /// an entry: the second would be handed the first one's merge base.
    @Test("an answer with nothing in it is no key")
    func empty() {
        #expect(BaselineFingerprint.make("") == nil)
        #expect(BaselineFingerprint.make("\n  \n") == nil)
    }

    // MARK: - The store

    @Test("an answer comes back only for the key it was stored under")
    func hitAndMiss() async {
        let cache = BaselineCache()
        await cache.remember(worktree: "/w", base: "main", fingerprint: "a", baseline: local)

        #expect(await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") == local)
        #expect(await cache.baseline(worktree: "/w", base: "main", fingerprint: "b") == nil)
        #expect(await cache.baseline(worktree: "/w", base: "trunk", fingerprint: "a") == nil)
        #expect(await cache.baseline(worktree: "/other", base: "main", fingerprint: "a") == nil)
    }

    @Test("a moved ref replaces the entry rather than adding one")
    func replaces() async {
        let cache = BaselineCache()
        await cache.remember(worktree: "/w", base: "main", fingerprint: "a", baseline: local)
        await cache.remember(worktree: "/w", base: "main", fingerprint: "b", baseline: remote)

        #expect(await cache.count == 1)
        #expect(await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") == nil)
        #expect(await cache.baseline(worktree: "/w", base: "main", fingerprint: "b") == remote)
    }

    // MARK: - One resolve at a time

    /// Two callers arriving together used to be two misses and two merge-base resolves, which is
    /// three extra git processes on the workspace switch. `changedFiles` and `branchCommits` are
    /// exactly that pair now that they run together.
    @Test("callers arriving together resolve once")
    func joinsOneFlight() async throws {
        let cache = BaselineCache()
        let gate = Gate()

        async let first = cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
            await gate.arrive()
            return self.local
        }
        // Held inside its resolve, so the flight is registered and cannot have finished.
        await gate.waitForArrivals(1)

        async let second = cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
            await gate.arrive()
            return self.remote
        }
        await gate.open()

        let firstAnswer = try await first
        let secondAnswer = try await second
        #expect(firstAnswer == local)
        #expect(secondAnswer == local)
        #expect(await gate.calls == 1)
    }

    /// The flight is keyed on the fingerprint as well as the worktree, because a resolve that
    /// started before a ref moved is answering about a graph that no longer exists. Joining it
    /// would be the squash-merge bug arriving through the back door.
    @Test("a ref that moves mid-flight does not join the flight it invalidated", .timeLimit(.minutes(1)))
    func doesNotJoinAStaleFlight() async throws {
        let cache = BaselineCache()
        let gate = Gate()

        async let before = cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
            await gate.arrive()
            return self.local
        }
        async let after = cache.baseline(worktree: "/w", base: "main", fingerprint: "b") {
            await gate.arrive()
            return self.remote
        }
        // Both resolves have to run, or the second is being handed the first one's answer.
        await gate.waitForArrivals(2)
        await gate.open()

        let beforeAnswer = try await before
        let afterAnswer = try await after
        #expect(beforeAnswer == local)
        #expect(afterAnswer == remote)
        #expect(await gate.calls == 2)
    }

    @Test("an answer already remembered is not resolved again")
    func hitSkipsTheResolve() async throws {
        let cache = BaselineCache()
        let gate = Gate()
        await gate.open()
        await cache.remember(worktree: "/w", base: "main", fingerprint: "a", baseline: local)

        let answer = try await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
            await gate.arrive()
            return self.remote
        }

        #expect(answer == local)
        #expect(await gate.calls == 0)
    }

    @Test("what a flight resolved is remembered for the next caller")
    func remembersWhatItResolved() async throws {
        let cache = BaselineCache()
        let gate = Gate()
        await gate.open()

        _ = try await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
            await gate.arrive()
            return self.local
        }
        let again = try await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
            await gate.arrive()
            return self.remote
        }

        #expect(again == local)
        #expect(await gate.calls == 1)
    }

    /// An entry left behind is a worktree that can never be asked about again, and nothing would
    /// report it: the app would simply stop noticing that one workspace's diff had changed.
    @Test("a finished flight leaves nothing behind")
    func clearsTheFlight() async throws {
        let cache = BaselineCache()
        let gate = Gate()
        await gate.open()

        _ = try await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
            await gate.arrive()
            return self.local
        }

        #expect(await cache.flights == 0)
    }

    @Test("a resolve that throws is not remembered and leaves nothing behind")
    func doesNotRememberAFailure() async throws {
        let cache = BaselineCache()
        let gate = Gate()
        await gate.open()

        await #expect(throws: Boom.self) {
            _ = try await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
                await gate.arrive()
                throw Boom()
            }
        }

        #expect(await cache.flights == 0)
        #expect(await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") == nil)

        let answer = try await cache.baseline(worktree: "/w", base: "main", fingerprint: "a") {
            await gate.arrive()
            return self.local
        }
        #expect(answer == local)
        #expect(await gate.calls == 2)
    }

    private struct Boom: Error {}

    /// A resolve that can be held open, so a second caller can be let in while the first is still
    /// running. Counting alone would not do it: a caller that arrives after the first has finished
    /// is a cache hit, which looks exactly like a caller that joined.
    private actor Gate {
        private(set) var calls = 0
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var watchers: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []

        /// One run of the resolve: counted, then held until `open`.
        func arrive() async {
            calls += 1
            let reached = calls
            watchers.removeAll { watcher in
                guard reached >= watcher.needed else { return false }
                watcher.continuation.resume()
                return true
            }
            guard !isOpen else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                held.append(continuation)
            }
        }

        func waitForArrivals(_ needed: Int) async {
            guard calls < needed else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                watchers.append((needed: needed, continuation: continuation))
            }
        }

        func open() {
            isOpen = true
            let waiting = held
            held = []
            for continuation in waiting { continuation.resume() }
        }
    }

    // MARK: - The bound

    /// Keyed on a path, and paths are created and archived all day. Unbounded would be a leak
    /// with a slow fuse rather than a bug anybody would notice.
    @Test("the table stays bounded")
    func bounded() async {
        let cache = BaselineCache()
        for index in 0..<(BaselineCache.limit + 20) {
            await cache.remember(
                worktree: "/w\(index)", base: "main", fingerprint: "f", baseline: local
            )
        }

        #expect(await cache.count == BaselineCache.limit)
        // The newest survives, which is the one a poll is about to ask for again.
        let newest = BaselineCache.limit + 19
        #expect(await cache.baseline(worktree: "/w\(newest)", base: "main", fingerprint: "f") == local)
    }
}
