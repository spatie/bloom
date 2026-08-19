import Foundation
import Testing
@testable import BloomCore

/// The rule that decides which ignored paths a confirmation is allowed to frighten somebody with.
///
/// It exists because the archive confirmation once read "981 ignored files that differ from the
/// main checkout: .bloom/attachments/.gitignore, .bloom/attachments/9JVKW4/IMG_4395.jpeg, .env,
/// node_modules/@inertiajs/core/dist/index.js, ... and 976 more". Every one of those lines is
/// true and only one of them is a loss.
@Suite("Reproducible paths", .tags(.git, .destructive), .scratchDirectory)
struct IgnoredPathsTests {
    @Test(
        "a package manager's or build tool's output is not somebody's work",
        arguments: [
            "node_modules/@inertiajs/core/dist/index.js",
            "node_modules/",
            "apps/web/node_modules/react/index.js",
            "vendor/laravel/framework/src/Illuminate/Support/Str.php",
            "dist/app.js",
            "public/build/assets/app-CmoDjKlM.js",
            ".next/cache/webpack/client.pack",
            "target/debug/bloom",
            "__pycache__/module.cpython-312.pyc",
            "src/module.pyc",
            ".DS_Store",
            "docs/.DS_Store",
            "coverage/lcov.info",
        ]
    )
    func reproducible(path: String) {
        #expect(ReproduciblePaths.canBeRebuilt(path))
    }

    /// Bloom creates `.bloom/attachments` itself, to hold the files somebody dragged onto a
    /// prompt. Listing it as work at risk is the app warning the user about the app.
    @Test(
        "Bloom's own directory is never reported",
        arguments: [".bloom/", ".bloom/attachments/.gitignore", ".bloom/attachments/9JVKW4/IMG_4395.jpeg"]
    )
    func bloomsOwn(path: String) {
        #expect(ReproduciblePaths.canBeRebuilt(path))
    }

    /// The case the whole check was written for, plus the ones next to it. Nothing rebuilds any
    /// of these from something that is in git.
    @Test(
        "a file somebody wrote by hand is a loss",
        arguments: [
            ".env",
            ".env.local",
            "config/local.php",
            "storage/logs/",
            "storage/app/private/invoice.pdf",
            "notes.md",
            "scratch/plan.txt",
            ".vscode/launch.json",
            ".idea/workspace.xml",
        ]
    )
    func notReproducible(path: String) {
        #expect(ReproduciblePaths.canBeRebuilt(path) == false)
    }

    // MARK: - The report itself

    private func makeWorkspace() async throws -> (TempRepo, Repo, WorkspaceManager, Workspace) {
        let repo = try await TempRepo()
        try repo.write(".gitignore", "node_modules/\n.env\n.bloom/\nstorage/logs/\n")
        try await repo.commit("ignore the disposable things")
        let manager = WorkspaceManager(store: try makeTestStore("ignored"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Do the thing")
        return (repo, registered, manager, workspace)
    }

    @Test("an edited .env is still reported, and node_modules beside it is not")
    func envSurvivesTheNoise() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try repo.write(".env", "APP_KEY=from-the-main-checkout\n")
        try repo.write("node_modules/react/index.js", "module.exports = 19\n")

        let worktree = TempRepo(existing: workspace.path)
        // The file Bloom copies into every worktree, edited by the agent. This is the loss the
        // check exists for and it must survive every attempt to make the check quieter.
        try worktree.write(".env", "APP_KEY=the-agent-worked-this-out\nQUEUE=redis\n")
        // Three hundred lines of noise in the original bug, all of it rebuilt by one install.
        try worktree.write("node_modules/react/index.js", "module.exports = 18\n")
        try worktree.write("node_modules/@inertiajs/core/dist/index.js", "export default {}\n")
        // Bloom's own directory, created by Bloom, reported to the user by Bloom.
        try worktree.write(".bloom/attachments/9JVKW4/IMG_4395.jpeg", "not really a jpeg\n")

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)

        #expect(report.modifiedIgnoredFiles == [".env"])
        #expect(report.isSafeToDiscard == false, "an edited .env is work that exists nowhere else")

        let sentence = report.losses(deletingBranch: false).joined(separator: "\n")
        #expect(sentence.contains(".env"))
        #expect(sentence.contains("node_modules") == false)
        #expect(sentence.contains(".bloom") == false)
    }

    /// The performance half of the same change, said as a fact rather than as a timing. A wholly
    /// ignored directory is one record from `git ls-files --directory`, so nothing walks it and
    /// nothing reads the files inside it.
    @Test("an ignored directory that exists only in the worktree is named once")
    func ignoredDirectoryIsOneLine() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        for index in 0..<40 {
            try worktree.write("storage/logs/laravel-\(index).log", "line \(index)\n")
        }

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.modifiedIgnoredFiles == ["storage/"])
        #expect(report.losses(deletingBranch: false).contains { $0.contains("1 ignored folder") })
    }

    @Test("an ignored file copied in and left alone is not a loss")
    func untouchedCopyIsNotALoss() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try repo.write(".env", "APP_KEY=from-the-main-checkout\n")
        let worktree = TempRepo(existing: workspace.path)
        try worktree.write(".env", "APP_KEY=from-the-main-checkout\n")

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.modifiedIgnoredFiles.isEmpty)
    }

    /// Same length, different bytes. The comparison starts at the file size because that answers
    /// most of them without a read, and a rule that stopped there would call this pair equal.
    @Test("two files of the same size are still compared byte for byte")
    func sameSizeDifferentBytes() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try repo.write(".env", "APP_KEY=aaaaaaaa\n")
        let worktree = TempRepo(existing: workspace.path)
        try worktree.write(".env", "APP_KEY=bbbbbbbb\n")

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.modifiedIgnoredFiles == [".env"])
    }
}
