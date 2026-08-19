import Testing
import Foundation
@testable import BloomCore

@Suite("Git", .tags(.git), .scratchDirectory)
struct GitTests {
    @Test("recognises a repository and finds its top level")
    func recognisesRepository() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        #expect(await Git.isRepository(repo.path))
        #expect(await Git.isRepository(NSTemporaryDirectory()) == false)

        try repo.write("nested/deep/file.txt", "x")
        let top = try await Git.topLevel(of: repo.path + "/nested/deep")
        // macOS hands out /var paths that resolve through a symlink to /private/var.
        #expect(top.hasSuffix(URL(fileURLWithPath: repo.path).lastPathComponent))
    }

    @Test("reports the default and current branch")
    func reportsBranches() async throws {
        let repo = try await TempRepo(defaultBranch: "trunk")
        defer { repo.cleanUp() }

        #expect(try await Git.currentBranch(of: repo.path) == "trunk")
        // No origin and no main, so it falls back to whatever is checked out.
        #expect(try await Git.defaultBranch(of: repo.path) == "trunk")
        #expect(try await Git.branches(of: repo.path) == ["trunk"])
        #expect(await Git.branchExists("trunk", in: repo.path))
        #expect(await Git.branchExists("nope", in: repo.path) == false)
    }

    @Test("prefers main when it exists")
    func prefersMain() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-q", "-b", "side"], cwd: repo.path)
        #expect(try await Git.defaultBranch(of: repo.path) == "main")
    }

    @Test("creates, lists and removes a worktree")
    func managesWorktrees() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let worktree = TestScratch.unique("bloom-wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "feature-x", base: "main")

        #expect(FileManager.default.fileExists(atPath: worktree + "/README.md"))
        #expect(try await Git.currentBranch(of: worktree) == "feature-x")

        let entries = try await Git.worktrees(of: repo.path)
        #expect(entries.count == 2)
        #expect(entries.contains { $0.branch == "feature-x" })

        try await Git.removeWorktree(repo: repo.path, path: worktree)
        #expect(FileManager.default.fileExists(atPath: worktree) == false)
        #expect(try await Git.worktrees(of: repo.path).count == 1)
    }

    @Test("checks out an existing branch rather than recreating it")
    func reusesExistingBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["branch", "already-here"], cwd: repo.path)

        let worktree = TestScratch.unique("bloom-wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "already-here", base: "main")

        #expect(try await Git.currentBranch(of: worktree) == "already-here")
        // Nothing was recreated, so the branch list is unchanged.
        #expect(try await Git.branches(of: repo.path) == ["already-here", "main"])
    }

    @Test("reports changed files including uncommitted and untracked work")
    func reportsChangedFiles() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let worktree = TestScratch.unique("bloom-wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "work", base: "main")

        let workspace = TempRepo(existing: worktree)
        try workspace.write("committed.txt", "one\ntwo\n")
        try await Shell.check("git", ["add", "-A"], cwd: worktree)
        try await Shell.check("git", ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "add"], cwd: worktree)

        try workspace.write("README.md", "hello\nchanged\n")
        try workspace.write("untracked.txt", "brand new\n")

        let files = try await Git.changedFiles(worktree: worktree, base: "main")
        let paths = Set(files.map(\.path))
        // The observed set is printed on failure. Two tests here once flaked under parallel load
        // and it turned out to be subprocess output being dropped, not test noise, so a bare
        // `contains` failure that says nothing about what git returned is worth avoiding.
        let observed = paths.sorted().joined(separator: ", ")
        #expect(paths == ["committed.txt", "README.md", "untracked.txt"], "got: \(observed)")

        let untracked = try #require(files.first { $0.path == "untracked.txt" })
        #expect(untracked.change == .untracked)

        // The per-file numbers are knowable, so pin them rather than "additions > 0".
        #expect(files.first { $0.path == "committed.txt" }?.additions == 2)
        #expect(files.first { $0.path == "README.md" }?.additions == 1)

        let stat = try await Git.diffStat(worktree: worktree, base: "main")
        #expect(stat.files == 3)
        #expect(stat.deletions == 0)
        // The total is deliberately not asserted here: untracked files are miscounted, which
        // `countsUntrackedLinesLikeGit` below pins on its own.
    }

    @Test("counts an untracked file's lines the way git counts them")
    func countsUntrackedLinesLikeGit() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let worktree = TestScratch.unique("bloom-wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "counting", base: "main")

        let workspace = TempRepo(existing: worktree)
        try workspace.write("trailing.txt", "one\ntwo\nthree\n")
        try workspace.write("no-trailing.txt", "only line")

        let files = try await Git.changedFiles(worktree: worktree, base: "main")
        let trailing = try #require(files.first { $0.path == "trailing.txt" })
        let noTrailing = try #require(files.first { $0.path == "no-trailing.txt" })

        // A file that does not end in a newline is already counted correctly, which is what
        // narrows the bug below down to the trailing newline.
        #expect(noTrailing.additions == 1)

        // git counts a trailing newline as terminating the last line, not starting an
        // empty one. Bloom used to count the empty piece, so every untracked file in the
        // UI read one addition too many.
        #expect(trailing.additions == 3)
    }

    @Test("produces a patch for a tracked and for an untracked file")
    func producesPatches() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let worktree = TestScratch.unique("bloom-wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "patch-work", base: "main")

        let workspace = TempRepo(existing: worktree)
        try workspace.write("README.md", "hello\nextra line\n")
        try workspace.write("new.txt", "fresh\n")

        let files = try await Git.changedFiles(worktree: worktree, base: "main")

        let readme = try #require(files.first { $0.path == "README.md" })
        let readmePatch = try await Git.patch(worktree: worktree, base: "main", file: readme)
        #expect(readmePatch.contains("+extra line"))

        let new = try #require(files.first { $0.path == "new.txt" })
        let newPatch = try await Git.patch(worktree: worktree, base: "main", file: new)
        #expect(newPatch.contains("+fresh"))
    }

    // MARK: - Naming

    @Test("turns a prompt into a readable branch slug", arguments: [
        (
            "Refuse unresolvable custom field option ulids instead of silently clearing",
            "refuse-unresolvable-custom-field-option"
        ),
        ("Please can you fix the 404 health check error", "fix-404-health-check-error"),
        // Only the first non-blank line is read.
        ("Fix it.\nSecond line is ignored", "fix"),
        ("Fix the thing. It is broken.", "fix-thing-broken"),
        // Nothing usable still has to produce a legal branch name.
        ("   ", "workspace"),
        ("!!! ???", "workspace"),
    ])
    func buildsSlugs(prompt: String, expected: String) {
        #expect(Git.slug(from: prompt) == expected)
    }

    @Test("caps a slug so git and the filesystem both stay happy")
    func capsSlugLength() {
        #expect(Git.slug(from: String(repeating: "verylongword ", count: 20)).count <= 60)
    }

    @Test("turns a prompt into a workspace title")
    func buildsTitles() {
        #expect(Git.title(from: "fix the failing timestamp") == "Fix the failing timestamp")
        #expect(Git.title(from: "") == "New workspace")
        let long = Git.title(from: String(repeating: "word ", count: 40))
        #expect(long.count <= 72)
        #expect(long.hasSuffix(" ") == false)
    }

    @Test("keeps the file a prompt names, so sibling workspaces stay distinguishable")
    func slugKeepsTheDistinguishingFile() {
        let invoice = Git.slug(from: "Add a class-level docblock to app/Domain/Invoice.php saying what it represents")
        let contact = Git.slug(from: "Add a class-level docblock to app/Domain/Contact.php saying what it represents")
        #expect(invoice != contact)
        #expect(invoice.hasSuffix("invoice"))
        #expect(contact.hasSuffix("contact"))

        // A short prompt already keeps the filename through the ordinary word budget, so the
        // token is not appended a second time.
        #expect(Git.slug(from: "Update Ticket.php") == "update-ticket-php")
        #expect(Git.slug(from: "Refactor invoice handling in Invoice.php") == "refactor-invoice-handling-invoice-php")
    }

    @Test("only treats a real path as the distinguishing token", arguments: [
        // A sentence that merely ends in a full stop is not a filename.
        ("Fix the login.", String?.none),
        ("no paths here at all", String?.none),
        ("see tests/Feature/LoginTest.php", "logintest"),
    ])
    func readsDistinguishingTokens(prompt: String, expected: String?) {
        #expect(Git.distinguishingToken(from: prompt) == expected)
    }

    @Test("produces branch names git will accept", arguments: [
        "Fix ~the~ thing^ with: weird? chars*",
        "Update [Invoice].php and {Contact}.php",
        "...leading dots and trailing dots...",
        "a/b/c refs/heads/@{now}",
        "  ",
        "🎉 emoji only 🎉",
        String(repeating: "long ", count: 60),
    ])
    func slugsAreValidRefs(prompt: String) async throws {
        let slug = Git.slug(from: prompt)
        let result = try await Shell.run("git", ["check-ref-format", "--branch", slug])
        #expect(result.ok, "git rejected the branch name \(slug) from prompt \(prompt)")
    }

    @Test("suffixes a branch name until it is free")
    func makesBranchesUnique() {
        #expect(Git.uniqueBranch("fix-thing", taken: []) == "fix-thing")
        #expect(Git.uniqueBranch("fix-thing", taken: ["fix-thing"]) == "fix-thing-2")
        #expect(Git.uniqueBranch("fix-thing", taken: ["fix-thing", "fix-thing-2"]) == "fix-thing-3")
    }
}

@Suite("Counting lines")
struct CountLinesTests {
    @Test(
        "a trailing newline terminates the last line rather than starting an empty one",
        arguments: [
            ("", 0),
            ("a", 1),
            ("a\n", 1),
            ("a\nb", 2),
            ("a\nb\n", 2),
            ("\n", 1),
            ("\n\n", 2),
            ("a\n\nb\n", 3),
        ]
    )
    func countLines(text: String, expected: Int) {
        #expect(Git.countLines(text) == expected)
    }
}
