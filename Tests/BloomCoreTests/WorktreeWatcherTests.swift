import Foundation
import Synchronization
import Testing
@testable import BloomCore

/// What the file system watcher says changed, and what it refuses to say.
///
/// The attribution is the part with a bug in it: a worktree nested inside another checkout, and
/// two worktrees whose names share a prefix, are both real shapes in `~/bloom/workspaces` and both
/// answer wrongly under a plain `hasPrefix`.
@Suite("Worktree watcher")
struct WorktreeWatcherTests {
    // MARK: Attribution

    @Test("a file inside a worktree is reported as that worktree")
    func attributesAFileToItsWorktree() {
        let changed = WorktreeWatcher.roots(
            of: ["/a/beta/Sources/App/View.swift"], in: WorktreeWatcher.ordered(["/a/beta"])
        )
        #expect(changed == ["/a/beta"])
    }

    @Test("the worktree's own directory is reported as itself")
    func attributesTheRootItself() {
        let changed = WorktreeWatcher.roots(of: ["/a/beta"], in: WorktreeWatcher.ordered(["/a/beta"]))
        #expect(changed == ["/a/beta"])
    }

    @Test("a worktree whose name is a prefix of another is not confused with it")
    func doesNotConfuseAPrefix() {
        let roots = WorktreeWatcher.ordered(["/a/beta", "/a/beta-two"])
        #expect(WorktreeWatcher.roots(of: ["/a/beta-two/x.txt"], in: roots) == ["/a/beta-two"])
        #expect(WorktreeWatcher.roots(of: ["/a/beta/x.txt"], in: roots) == ["/a/beta"])
    }

    @Test("a worktree nested inside another checkout is reported as itself")
    func attributesTheNestedWorktree() {
        let roots = WorktreeWatcher.ordered(["/a/repo", "/a/repo/nested"])
        #expect(WorktreeWatcher.roots(of: ["/a/repo/nested/x.txt"], in: roots) == ["/a/repo/nested"])
    }

    @Test("a path in no watched worktree is reported as nothing")
    func dropsWhatItDoesNotWatch() {
        #expect(WorktreeWatcher.roots(of: ["/somewhere/else"], in: ["/a/beta"]).isEmpty)
    }

    @Test("a storm of writes in one worktree is one answer")
    func coalescesABatch() {
        let paths = (0..<200).map { "/a/beta/file-\($0)" }
        #expect(WorktreeWatcher.roots(of: paths, in: ["/a/beta"]) == ["/a/beta"])
    }

    @Test("trailing separators do not make two roots out of one")
    func standardisesTrailingSeparators() {
        let roots = WorktreeWatcher.ordered(["/a/beta/", "/a/beta"])
        #expect(roots == ["/a/beta"])
        #expect(WorktreeWatcher.roots(of: ["/a/beta/x"], in: roots) == ["/a/beta"])
    }

    // MARK: Against the real file system

    @Test("a write inside a watched directory wakes the watcher", .timeLimit(.minutes(1)))
    func reportsARealWrite() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloom-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Deliberately the spelling with the symlink still in it: `NSTemporaryDirectory` says
        // `/var/folders/...` and FSEvents answers about `/private/var/folders/...`, so watching
        // this path at all is the test of `WorktreeWatcher.resolve`. What comes back has to be
        // the spelling that went in, because that is what the caller has a workspace for.
        let watchedPath = root.path

        let reported = Mutex<Set<String>>([])
        let watcher = WorktreeWatcher { changed in
            reported.withLock { $0.formUnion(changed) }
        }
        defer { watcher.stop() }
        watcher.watch(roots: [watchedPath])

        // FSEvents subscribes asynchronously, so a write made in the same instant as the start can
        // land before the subscription does. This is the one wait in the test and it is why the
        // whole thing has a time limit rather than a sleep long enough to be sure.
        try await Task.sleep(for: .milliseconds(300))
        try Data("hello".utf8).write(to: root.appendingPathComponent("file.txt"))

        var waited = Duration.zero
        while reported.withLock({ $0.isEmpty }), waited < .seconds(20) {
            try await Task.sleep(for: .milliseconds(100))
            waited += .milliseconds(100)
        }
        #expect(reported.withLock { $0 } == [watchedPath])
    }

    @Test("watching nothing tears the stream down without complaint")
    func stopsCleanly() {
        let watcher = WorktreeWatcher { _ in }
        watcher.watch(roots: ["/tmp"])
        watcher.watch(roots: [])
        watcher.stop()
    }
}
