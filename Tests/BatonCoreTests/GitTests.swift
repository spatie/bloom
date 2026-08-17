import Testing
import Foundation
@testable import BatonCore

/// A throwaway git repository on disk. These tests run real git, because the whole point of
/// Git.swift is that it drives the real thing correctly.
struct TempRepo {
    let path: String

    init(defaultBranch: String = "main") async throws {
        path = NSTemporaryDirectory() + "baton-git-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q", "-b", defaultBranch], cwd: path)
        try await Shell.check("git", ["config", "user.email", "test@baton.local"], cwd: path)
        try await Shell.check("git", ["config", "user.name", "Baton Test"], cwd: path)
        try await Shell.check("git", ["config", "commit.gpgsign", "false"], cwd: path)
        try write("README.md", "hello\n")
        try await commit("initial")
    }

    func write(_ relative: String, _ contents: String) throws {
        let full = (path as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try contents.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOfFile: (path as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(relative))
    }

    func commit(_ message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: path)
        try await Shell.check("git", ["commit", "-q", "-m", message], cwd: path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

@Suite("Git")
struct GitTests {
    @Test("recognises a repository and finds its top level")
    func recognisesRepository() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        #expect(await Git.isRepository(repo.path))
        #expect(await !Git.isRepository(NSTemporaryDirectory()))

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
        #expect(await !Git.branchExists("nope", in: repo.path))
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

        let worktree = NSTemporaryDirectory() + "baton-wt-\(UUID().uuidString)"
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "feature-x", base: "main")

        #expect(FileManager.default.fileExists(atPath: worktree + "/README.md"))
        #expect(try await Git.currentBranch(of: worktree) == "feature-x")

        let entries = try await Git.worktrees(of: repo.path)
        #expect(entries.count == 2)
        #expect(entries.contains { $0.branch == "feature-x" })

        try await Git.removeWorktree(repo: repo.path, path: worktree)
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(try await Git.worktrees(of: repo.path).count == 1)
    }

    @Test("checks out an existing branch rather than recreating it")
    func reusesExistingBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["branch", "already-here"], cwd: repo.path)

        let worktree = NSTemporaryDirectory() + "baton-wt-\(UUID().uuidString)"
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "already-here", base: "main")
        defer { Task { try? await Git.removeWorktree(repo: repo.path, path: worktree) } }

        #expect(try await Git.currentBranch(of: worktree) == "already-here")
    }

    @Test("reports changed files including uncommitted and untracked work")
    func reportsChangedFiles() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let worktree = NSTemporaryDirectory() + "baton-wt-\(UUID().uuidString)"
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "work", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let workspace = TempRepo(existing: worktree)
        try workspace.write("committed.txt", "one\ntwo\n")
        try await Shell.check("git", ["add", "-A"], cwd: worktree)
        try await Shell.check("git", ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "add"], cwd: worktree)

        try workspace.write("README.md", "hello\nchanged\n")
        try workspace.write("untracked.txt", "brand new\n")

        let files = try await Git.changedFiles(worktree: worktree, base: "main")
        let paths = Set(files.map(\.path))
        // The observed set is printed on failure. This has flaked once under heavy parallel
        // load, and a bare `contains` failure says nothing about what git actually returned.
        let observed = paths.sorted().joined(separator: ", ")
        #expect(paths.contains("committed.txt"), "got: \(observed)")
        #expect(paths.contains("README.md"), "got: \(observed)")
        #expect(paths.contains("untracked.txt"), "got: \(observed)")

        let untracked = try #require(files.first { $0.path == "untracked.txt" })
        #expect(untracked.change == .untracked)

        let stat = try await Git.diffStat(worktree: worktree, base: "main")
        #expect(stat.files == 3)
        #expect(stat.additions > 0)
    }

    @Test("produces a patch for a tracked and for an untracked file")
    func producesPatches() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let worktree = NSTemporaryDirectory() + "baton-wt-\(UUID().uuidString)"
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "patch-work", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

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

    @Test("turns a prompt into a readable branch slug")
    func buildsSlugs() {
        #expect(Git.slug(from: "Refuse unresolvable custom field option ulids instead of silently clearing")
            == "refuse-unresolvable-custom-field-option")
        #expect(Git.slug(from: "Please can you fix the 404 health check error")
            == "fix-404-health-check-error")
        #expect(Git.slug(from: "Fix it.\nSecond line is ignored") == "fix")
        #expect(Git.slug(from: "Fix the thing. It is broken.") == "fix-thing-broken")
        #expect(Git.slug(from: "   ") == "workspace")
        #expect(Git.slug(from: "!!! ???") == "workspace")
        #expect(Git.slug(from: String(repeating: "verylongword ", count: 20)).count <= 60)
    }

    @Test("turns a prompt into a workspace title")
    func buildsTitles() {
        #expect(Git.title(from: "fix the failing timestamp") == "Fix the failing timestamp")
        #expect(Git.title(from: "") == "New workspace")
        let long = Git.title(from: String(repeating: "word ", count: 40))
        #expect(long.count <= 72)
        #expect(!long.hasSuffix(" "))
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
        // A sentence that merely ends in a full stop is not a filename.
        #expect(Git.distinguishingToken(from: "Fix the login.") == nil)
        #expect(Git.distinguishingToken(from: "no paths here at all") == nil)
        #expect(Git.distinguishingToken(from: "see tests/Feature/LoginTest.php") == "logintest")
    }

    @Test("produces branch names git will accept")
    func slugsAreValidRefs() async throws {
        let prompts = [
            "Fix ~the~ thing^ with: weird? chars*",
            "Update [Invoice].php and {Contact}.php",
            "...leading dots and trailing dots...",
            "a/b/c refs/heads/@{now}",
            "  ",
            "🎉 emoji only 🎉",
            String(repeating: "long ", count: 60),
        ]
        for prompt in prompts {
            let slug = Git.slug(from: prompt)
            let result = try await Shell.run("git", ["check-ref-format", "--branch", slug])
            #expect(result.ok, "git rejected the branch name \(slug) from prompt \(prompt)")
        }
    }

    @Test("suffixes a branch name until it is free")
    func makesBranchesUnique() {
        #expect(Git.uniqueBranch("fix-thing", taken: []) == "fix-thing")
        #expect(Git.uniqueBranch("fix-thing", taken: ["fix-thing"]) == "fix-thing-2")
        #expect(Git.uniqueBranch("fix-thing", taken: ["fix-thing", "fix-thing-2"]) == "fix-thing-3")
    }
}

extension TempRepo {
    /// Wraps a directory that is already a worktree, so the write helpers can be reused.
    init(existing path: String) {
        self.path = path
    }
}
