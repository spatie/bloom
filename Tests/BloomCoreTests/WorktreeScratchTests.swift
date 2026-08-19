import Foundation
import Testing
@testable import BloomCore

/// The one rule about everything Bloom writes into somebody else's checkout: git must not see it.
///
/// This suite exists because it was broken. `.bloom/attachments` was shielded and
/// `.bloom/pr-instructions.md`, written beside it by the same app for the same reason, was not.
/// It went out in a user's pull request and was merged. So the assertion is made against the real
/// git binary, for every folder on the list rather than only the one that was found, and it is
/// made by doing what an agent told to commit everything actually does.
@Suite("Worktree scratch", .tags(.git), .scratchDirectory)
struct WorktreeScratchTests {
    @Test("a path inside a scratch folder is shielded and one beside it is not")
    func recognisesItsOwn() {
        #expect(WorktreeScratch.isShielded(".bloom/attachments"))
        #expect(WorktreeScratch.isShielded(".bloom/attachments/9JVKW4/IMG_4395.jpeg"))
        #expect(WorktreeScratch.isShielded(".bloom/scratch/pr-instructions.md"))

        #expect(WorktreeScratch.isShielded(".bloom") == false)
        #expect(WorktreeScratch.isShielded(".bloom/settings.toml") == false)
        #expect(WorktreeScratch.isShielded(".bloom/setup.sh") == false)
        #expect(WorktreeScratch.isShielded(".bloom/pr-instructions.md") == false)
        // A prefix match on the string alone would call this one shielded.
        #expect(WorktreeScratch.isShielded(".bloom/attachments-of-mine.md") == false)
    }

    /// `git add -A` is what an agent reaches for when it is told to commit whatever is
    /// uncommitted, which is what Bloom's own pull request instructions tell it to do.
    @Test("an agent told to commit everything cannot commit a scratch folder",
          arguments: WorktreeScratch.folders)
    func nothingInAScratchFolderCanBeStaged(folder: String) async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        WorktreeScratch.shield(folder, in: repo.path)
        try repo.write("\(folder)/whatever.txt", "Bloom wrote this and nobody asked for it.\n")
        try repo.write("\(folder)/nested/deeper.bin", "not a file anybody reviews\n")

        try await Shell.check("git", ["add", "-A"], cwd: repo.path)
        let staged = try await Shell.check(
            "git", ["diff", "--cached", "--name-only"], cwd: repo.path
        )
        #expect(staged.trimmed.isEmpty, "git staged \(staged.trimmed)")

        let status = try await Shell.check("git", ["status", "--porcelain"], cwd: repo.path)
        #expect(status.trimmed.isEmpty, "git reported \(status.trimmed)")
    }

    /// The list is what the assertion above walks, so a folder that is not on it is a folder
    /// nothing checks. Anything Bloom writes into a worktree belongs under one of these.
    @Test("every folder on the list is Bloom's own corner of the repository")
    func foldersAreAllUnderBloom() {
        #expect(WorktreeScratch.folders.isEmpty == false)
        for folder in WorktreeScratch.folders {
            #expect(folder.hasPrefix(".bloom/"), "\(folder) is outside .bloom")
            #expect(WorktreeScratch.isShielded(folder))
        }
    }

    /// A scratch folder adds nothing to the user's repository, `.bloom/.gitignore` included.
    /// That file is one the team commits, and Bloom writing it as a side effect of its own
    /// scratch would put a file in somebody's pull request that they never asked for.
    ///
    /// It is still laid down the first time somebody writes a setting, which is the deliberate
    /// act it belongs to, and it has to be laid down even though `.bloom` already exists by then.
    @Test("a scratch folder adds nothing to the repository, and settings still get their rules")
    func addsNothingButStillPreparesTheFolderLater() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        WorktreeScratch.shield(WorktreeScratch.generated, in: repo.path)
        try repo.write("\(WorktreeScratch.generated)/pr-instructions.md", "Bloom's own\n")

        #expect(repo.exists(".bloom/.gitignore") == false)
        let untouched = try await Shell.check("git", ["status", "--porcelain"], cwd: repo.path)
        #expect(untouched.trimmed.isEmpty, "git reported \(untouched.trimmed)")

        SettingsWriter.prepareFolder(
            for: (repo.path as NSString).appendingPathComponent(".bloom/settings.toml"),
            repo: repo.path
        )
        try repo.write(".bloom/settings.local.toml", "token = \"do not commit me\"\n")
        try repo.write(".bloom/setup.local.sh", "#!/bin/zsh\necho mine\n")

        try await Shell.check("git", ["add", "-A"], cwd: repo.path)
        let staged = try await Shell.check(
            "git", ["diff", "--cached", "--name-only"], cwd: repo.path
        ).lines
        #expect(staged == [".bloom/.gitignore"])
    }

    /// The ignore file is written once. A user who edited it keeps their edit, and calling this
    /// on every write costs nothing.
    @Test("an existing ignore file is never rewritten")
    func neverRewritesTheIgnoreFile() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        try repo.write("\(WorktreeScratch.generated)/.gitignore", "*\n!keep.txt\n")
        WorktreeScratch.shield(WorktreeScratch.generated, in: repo.path)

        #expect(repo.read("\(WorktreeScratch.generated)/.gitignore") == "*\n!keep.txt\n")
    }
}
