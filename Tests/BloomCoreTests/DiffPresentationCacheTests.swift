import Foundation
import Testing
@testable import BloomCore

/// What the review pane last drew for a file may only be handed back for a question identical to
/// the one it answered, so every field of the key is asserted by changing it and expecting a miss.
/// The one field the patch cache has and this deliberately has not is the changes generation: see
/// the head of `DiffPresentationCache` for why holding across a poll is the same rule an open pane
/// already follows.
@Suite("Reusing a diff the review pane has already prepared")
struct DiffPresentationCacheTests {
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
        ignoresWhitespace: Bool = false
    ) -> DiffPresentationCache.Key {
        DiffPresentationCache.Key(
            worktree: worktree ?? self.worktree,
            base: base ?? self.base,
            file: changed ?? file(),
            scope: scope,
            ignoresWhitespace: ignoresWhitespace
        )
    }

    private func presentation(maxColumns: Int = 80) -> DiffPresentation {
        let diff = FileDiff(newPath: "Sources/Bloom.swift", hunks: [])
        return DiffPresentation(
            source: diff,
            document: DiffDocument(
                file: diff,
                language: .swift,
                carries: [:],
                emphasis: [:],
                maxColumns: maxColumns
            ),
            lines: ["one", "two"]
        )
    }

    @Test("the same question gets the answer back")
    func sameQuestionHits() {
        var cache = DiffPresentationCache()
        cache.store(presentation(), for: key())
        #expect(cache.presentation(for: key())?.document.maxColumns == 80)
    }

    @Test("nothing is held for a file nobody has opened")
    func emptyMisses() {
        let cache = DiffPresentationCache()
        #expect(cache.presentation(for: key()) == nil)
    }

    @Test("another file, worktree, base, scope or whitespace setting is another question")
    func everyFieldOfTheKeyCounts() {
        var cache = DiffPresentationCache()
        cache.store(presentation(), for: key())

        #expect(cache.presentation(for: key(file: file("Sources/Other.swift"))) == nil)
        #expect(cache.presentation(for: key(file: file(change: .untracked))) == nil)
        #expect(cache.presentation(for: key(worktree: "/tmp/elsewhere")) == nil)
        #expect(cache.presentation(for: key(base: "develop")) == nil)
        #expect(cache.presentation(for: key(scope: .uncommitted)) == nil)
        #expect(cache.presentation(for: key(ignoresWhitespace: true)) == nil)
    }

    /// The changes poll bumps a generation every six seconds whether or not the worktree moved, so
    /// keying on it would make this cache miss exactly the flick it exists for. It holds instead,
    /// and the pane re-reads git behind what it drew.
    @Test("a poll does not throw the presentation away")
    func survivesAPoll() {
        var cache = DiffPresentationCache()
        cache.store(presentation(), for: key())
        #expect(cache.presentation(for: key()) != nil)
    }

    @Test("a stored answer replaces the one it supersedes")
    func replaces() {
        var cache = DiffPresentationCache()
        cache.store(presentation(maxColumns: 80), for: key())
        cache.store(presentation(maxColumns: 120), for: key())
        #expect(cache.count == 1)
        #expect(cache.presentation(for: key())?.document.maxColumns == 120)
    }

    @Test("the least recently stored goes when the cache is full")
    func evictsOldest() {
        var cache = DiffPresentationCache()
        let paths = (0...DiffPresentationCache.capacity).map { "File\($0).swift" }
        for path in paths { cache.store(presentation(), for: key(file: file(path))) }

        #expect(cache.count == DiffPresentationCache.capacity)
        #expect(cache.presentation(for: key(file: file(paths[0]))) == nil)
        #expect(cache.presentation(for: key(file: file(paths[1]))) != nil)
        #expect(cache.presentation(for: key(file: file(paths.last!))) != nil)
    }

    /// A revert and a save both rewrite the file underneath whatever was drawn from it, and both
    /// say so, so the next reader is never shown the lines that have just gone.
    @Test("forgetting a file drops it under every question asked about it")
    func forget() {
        var cache = DiffPresentationCache()
        cache.store(presentation(), for: key())
        cache.store(presentation(), for: key(ignoresWhitespace: true))
        cache.store(presentation(), for: key(file: file("Sources/Other.swift")))

        cache.forget(file: "Sources/Bloom.swift")

        #expect(cache.presentation(for: key()) == nil)
        #expect(cache.presentation(for: key(ignoresWhitespace: true)) == nil)
        #expect(cache.presentation(for: key(file: file("Sources/Other.swift"))) != nil)
        #expect(cache.count == 1)
    }

    /// Eviction has to take the order entry with it, or a forgotten file goes on counting against
    /// the capacity and pushes live entries out.
    @Test("a forgotten file leaves room behind it")
    func forgetFreesCapacity() {
        var cache = DiffPresentationCache()
        let paths = (0..<DiffPresentationCache.capacity).map { "File\($0).swift" }
        for path in paths { cache.store(presentation(), for: key(file: file(path))) }

        cache.forget(file: paths[0])
        cache.store(presentation(), for: key(file: file("Fresh.swift")))

        #expect(cache.count == DiffPresentationCache.capacity)
        #expect(cache.presentation(for: key(file: file(paths[1]))) != nil)
        #expect(cache.presentation(for: key(file: file("Fresh.swift"))) != nil)
    }
}
