import Foundation
import Testing
@testable import BloomCore

/// What `Git.baseline` is allowed to remember.
///
/// The suite exists because the cache trades correctness risk for energy: a merge base that is
/// remembered one moment too long is the squash-merge bug in `BaselineTests` all over again, with
/// every merged file shown as this workspace's work. So the two things worth pinning are that the
/// key changes whenever any ref moves, and that an answer is only ever handed back for a key that
/// matched exactly.
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
