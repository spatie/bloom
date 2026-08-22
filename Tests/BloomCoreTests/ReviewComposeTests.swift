import Testing
import Foundation
@testable import BloomCore

/// The whole compose path against a real worktree, hermetically: a workspace is cut, the
/// worktree edited, two comments anchored, and the turn composed and read back. This is the
/// live test's setup with the paid half taken off, and it is what caught the anchor capture
/// trapping on the last line of a file.
@Suite("Review compose against a worktree", .tags(.subprocess), .scratchDirectory)
struct ReviewComposeTests {
    @Test("the live review setup composes without crashing")
    func setup() async throws {
        let repo = try await TempRepo()
        try repo.write("greeter.py", "def greet(name):\n    print(\"Hi\")\n")
        try repo.write("farewell.py", "def farewell(name):\n    print(\"Bye\")\n")
        try await repo.commit("base")
        defer { repo.cleanUp() }

        let store = try makeTestStore("livereviewprobe")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Review check")

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("greeter.py", "def greet(name):\n    print(\"Hello \" + name)\n")
        try worktree.write("farewell.py", "def farewell(name):\n    print(\"Goodby, \" + name)\n")

        let comments = [
            ReviewComment(
                workspaceID: workspace.id,
                filePath: "greeter.py",
                anchor: ReviewCommentAnchor.make(
                    line: 2, in: ReviewCommentAnchor.split(worktree.read("greeter.py") ?? "")
                ),
                body: "Use an f-string here instead of string concatenation."
            ),
            ReviewComment(
                workspaceID: workspace.id,
                filePath: "farewell.py",
                anchor: ReviewCommentAnchor.make(
                    line: 2, in: ReviewCommentAnchor.split(worktree.read("farewell.py") ?? "")
                ),
                body: "There is a typo in this string: Goodby should be Goodbye. Fix only the typo."
            ),
        ]

        let composed = ReviewTurn.compose(
            message: "Please address both review comments.",
            comments: comments,
            worktreePath: workspace.path,
            template: PromptRegistry.definition(for: .review).defaultTemplate
        )
        #expect(ReviewTurn.split(composed)?.chips.count == 2)
    }
}
