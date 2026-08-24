import Foundation
import Testing
@testable import BloomCore

/// A patch may only be handed back for a question identical to the one it answered, so every
/// field of the key is asserted by changing it and expecting a miss. A cache that answers a
/// question it was not asked is worse than no cache: it draws one file's diff under another
/// file's name.
@Suite("Reusing a patch git has already produced")
struct PatchCacheTests {
    private let worktree = "/tmp/work"
    private let base = "main"

    private func file(
        _ path: String = "Sources/Bloom.swift",
        change: ChangedFile.Change = .modified
    ) -> ChangedFile {
        ChangedFile(path: path, change: change, additions: 1, deletions: 1)
    }

    private func key(
        file changed: ChangedFile? = nil,
        worktree: String? = nil,
        base: String? = nil,
        scope: DiffScope = .all,
        generation: Int = 1
    ) -> PatchCache.Key {
        PatchCache.Key(
            worktree: worktree ?? self.worktree,
            base: base ?? self.base,
            file: changed ?? file(),
            scope: scope,
            generation: generation
        )
    }

    @Test("the same question gets the answer back")
    func sameQuestionHits() {
        var cache = PatchCache()
        cache.store("@@ -1 +1 @@", for: key())
        #expect(cache.patch(for: key()) == "@@ -1 +1 @@")
    }

    @Test("nothing is answered before it is asked")
    func emptyMisses() {
        let cache = PatchCache()
        #expect(cache.patch(for: key()) == nil)
    }

    @Test("every part of the question is part of the key")
    func everyFieldSeparatesTheAnswer() {
        var cache = PatchCache()
        cache.store("held", for: key())

        #expect(cache.patch(for: key(worktree: "/tmp/other")) == nil)
        #expect(cache.patch(for: key(base: "develop")) == nil)
        #expect(cache.patch(for: key(file: file("Sources/Other.swift"))) == nil)
        #expect(cache.patch(for: key(file: file(change: .untracked))) == nil)
        #expect(cache.patch(for: key(scope: .uncommitted)) == nil)
        #expect(cache.patch(for: key(generation: 2)) == nil)
    }

    /// Two scopes that name two different commits are two different questions, which is the one
    /// case an enum with an associated value could get wrong.
    @Test("two commits are two scopes")
    func sinceCommitsSeparate() {
        var cache = PatchCache()
        let first = BranchCommit(sha: "a", subject: "one", author: "x", date: .distantPast)
        let second = BranchCommit(sha: "b", subject: "two", author: "x", date: .distantPast)
        cache.store("held", for: key(scope: .since(first)))

        #expect(cache.patch(for: key(scope: .since(first))) == "held")
        #expect(cache.patch(for: key(scope: .since(second))) == nil)
    }

    /// A landed refresh means git has looked at the worktree again, so everything measured before
    /// it is a claim about a worktree nobody has checked. It goes rather than sitting in the map
    /// under a generation nothing will ask for again.
    @Test("a new generation sweeps the old one out")
    func newGenerationSweeps() {
        var cache = PatchCache()
        cache.store("old", for: key(file: file("a.swift"), generation: 1))
        cache.store("old", for: key(file: file("b.swift"), generation: 1))
        #expect(cache.count == 2)

        cache.store("new", for: key(file: file("a.swift"), generation: 2))
        #expect(cache.count == 1)
        #expect(cache.patch(for: key(file: file("a.swift"), generation: 1)) == nil)
        #expect(cache.patch(for: key(file: file("b.swift"), generation: 1)) == nil)
        #expect(cache.patch(for: key(file: file("a.swift"), generation: 2)) == "new")
    }

    @Test("a reader moving through a large review inside one generation is bounded")
    func capacityBounds() {
        var cache = PatchCache()
        for index in 0..<(PatchCache.capacity + 5) {
            cache.store("patch \(index)", for: key(file: file("file\(index).swift")))
        }
        #expect(cache.count == PatchCache.capacity)
        #expect(cache.patch(for: key(file: file("file0.swift"))) == nil)
        #expect(cache.patch(for: key(file: file("file16.swift"))) == "patch 16")
    }

    /// Storing the same key again must not grow the eviction order, or a file looked at twelve
    /// times would push out eleven other files that are still current.
    @Test("looking at one file twice is one entry")
    func repeatedStoreIsOneEntry() {
        var cache = PatchCache()
        for _ in 0..<20 { cache.store("held", for: key()) }
        #expect(cache.count == 1)
        #expect(cache.patch(for: key()) == "held")
    }
}
