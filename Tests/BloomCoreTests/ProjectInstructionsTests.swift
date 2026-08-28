import Foundation
import Testing
@testable import BloomCore

/// What a project adds to the two turns Bloom composes about landing a branch, and what a turn
/// looks like when it adds nothing.
///
/// The empty case is the one most presses take, so it is asserted first and hardest: a turn that
/// names a file nobody wrote sends an agent to read nothing, and that used to be every merge in
/// every repository, because Bloom wrote its own instructions to disk in order to attach them
/// back.
@Suite("Project instructions", .tags(.git), .scratchDirectory)
struct ProjectInstructionsTests {
    // MARK: - Nothing to say

    @Test("a project with nothing to add gets a turn with nothing attached", arguments: ProjectInstructions.Subject.allCases)
    func silentByDefault(subject: ProjectInstructions.Subject) throws {
        let worktree = try emptyWorktree()

        let extra = ProjectInstructions.resolve(subject, in: worktree, stated: nil)
        let turn = ProjectInstructions.turn("Do the thing.", for: subject, adding: extra)

        #expect(extra == .nothing)
        #expect(!turn.contains("This project has its own instructions"))
        #expect(!turn.contains(WorktreeScratch.generated), "a turn names no file nobody wrote")
        #expect(!turn.contains(ProjectInstructions.projectPath(for: subject)))
        // Nothing was written either. The whole point of taking Bloom's own words out of a file is
        // that a press that has nothing to attach touches the disk not at all.
        #expect(!FileManager.default.fileExists(
            atPath: (worktree as NSString).appendingPathComponent(WorktreeScratch.generated)
        ))
    }

    /// An empty file, or one somebody emptied and left behind, is a project that has said nothing.
    /// A file like that used to be attached anyway, because the check was a stat.
    @Test("a file with nothing in it is nothing to say", arguments: ["", "   ", "\n\n  \n"])
    func emptyFileSaysNothing(contents: String) throws {
        let worktree = try emptyWorktree()
        try write(contents, to: ProjectInstructions.projectPath(for: .merge), in: worktree)

        #expect(ProjectInstructions.resolve(.merge, in: worktree, stated: nil) == .nothing)
    }

    /// And an empty one does not shadow the field either, which is the half of the same rule that
    /// a stat could not have expressed at all.
    @Test("an empty file does not outrank a settings value")
    func emptyFileDoesNotWin() throws {
        let worktree = try emptyWorktree()
        try write("\n", to: ProjectInstructions.projectPath(for: .merge), in: worktree)

        #expect(ProjectInstructions.resolve(.merge, in: worktree, stated: "Squash.")
            == .file(ProjectInstructions.scratchPath(for: .merge)))
    }

    // MARK: - The two sources

    @Test("the project's file is named in the turn, and nothing is written to say so")
    func fileIsNamed() throws {
        let worktree = try emptyWorktree()
        let path = ProjectInstructions.projectPath(for: .merge)
        try write("We merge on Fridays only.\n", to: path, in: worktree)

        let extra = ProjectInstructions.resolve(.merge, in: worktree, stated: nil)
        let turn = ProjectInstructions.turn("Merge #42.", for: .merge, adding: extra)

        #expect(extra == .file(path))
        #expect(turn.contains("`\(path)`"))
        #expect(turn.contains("where they disagree with anything above, they win"))
        // Untouched, and unwritten. A file that belongs to the project is one this app reads.
        #expect(read(path, in: worktree) == "We merge on Fridays only.\n")
        #expect(!FileManager.default.fileExists(
            atPath: (worktree as NSString)
                .appendingPathComponent(ProjectInstructions.scratchPath(for: .merge))
        ))
    }

    @Test("a settings value is spilled into the shielded folder and named from there")
    func settingsAreSpilled() throws {
        let worktree = try emptyWorktree()
        let scratch = ProjectInstructions.scratchPath(for: .fixConflicts)

        let extra = ProjectInstructions.resolve(
            .fixConflicts, in: worktree, stated: "Regenerate the lock file."
        )

        #expect(extra == .file(scratch))
        #expect(WorktreeScratch.isShielded(scratch))
        #expect(read(scratch, in: worktree) == "Regenerate the lock file.\n")
    }

    /// The whole reason the spilled copy is rewritten rather than kept. Bloom's own instructions
    /// were a constant, so the file could be left alone once it existed; this one is whatever the
    /// settings said a moment ago, and a stale copy is an agent following an instruction the
    /// project has already changed.
    @Test("a settings value that changed replaces the copy from last time")
    func spilledCopyIsNotStale() throws {
        let worktree = try emptyWorktree()
        let scratch = ProjectInstructions.scratchPath(for: .merge)

        _ = ProjectInstructions.resolve(.merge, in: worktree, stated: "Squash.")
        _ = ProjectInstructions.resolve(.merge, in: worktree, stated: "Rebase.")

        #expect(read(scratch, in: worktree) == "Rebase.\n")
    }

    /// The same bug `PullRequestInstructionsTests.surviveAddEverything` exists for, asserted
    /// against the real git binary. Bloom's own file went out in a user's pull request once, and
    /// the turn that carries this one still tells the agent to commit what it finds.
    @Test("an agent told to commit everything cannot commit the spilled copy")
    func surviveAddEverything() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        #expect(ProjectInstructions.resolve(.merge, in: repo.path, stated: "Squash.")
            == .file(ProjectInstructions.scratchPath(for: .merge)))

        try await Shell.check("git", ["add", "-A"], cwd: repo.path)
        let staged = try await Shell.check(
            "git", ["diff", "--cached", "--name-only"], cwd: repo.path
        )
        #expect(staged.trimmed.isEmpty, "git staged \(staged.trimmed)")
    }

    /// The owner's instinct, written down: the copy the branch carries is reviewable in the same
    /// diff as the work it governs, so it beats a value typed into a window.
    @Test("the project's file beats the settings field")
    func fileWins() throws {
        let worktree = try emptyWorktree()
        let path = ProjectInstructions.projectPath(for: .merge)
        try write("From the file.\n", to: path, in: worktree)

        let extra = ProjectInstructions.resolve(.merge, in: worktree, stated: "From the settings.")

        #expect(extra == .file(path))
        #expect(!FileManager.default.fileExists(
            atPath: (worktree as NSString)
                .appendingPathComponent(ProjectInstructions.scratchPath(for: .merge))
        ))
    }

    /// A read-only checkout is a reason to say it differently, not a reason to drop what the
    /// project asked for. Bloom's own steps arrive either way now, because they are in the words.
    @Test("a worktree that cannot be written to still carries the project's words")
    func inlineWhenNothingCanBeWritten() {
        let extra = ProjectInstructions.resolve(
            .merge, in: "/dev/null/nowhere", stated: "We merge on Fridays only."
        )
        let turn = ProjectInstructions.turn("Merge #42.", for: .merge, adding: extra)

        #expect(extra == .inline("We merge on Fridays only."))
        #expect(turn.contains("We merge on Fridays only."))
        #expect(turn.contains(MergeInstructions.canonical))
    }

    // MARK: - The turn

    /// The rules are in the message rather than in a file the reader has to go and open, which is
    /// the whole of what changed here.
    @Test("the merge turn carries Bloom's rules whatever the project says")
    func mergeAlwaysCarriesTheRules() throws {
        let worktree = try emptyWorktree()

        let turn = ProjectInstructions.turn(
            "Merge #42.", for: .merge,
            adding: ProjectInstructions.resolve(.merge, in: worktree, stated: nil)
        )

        #expect(turn.hasPrefix("Merge #42.\n\n"))
        #expect(turn.contains(MergeInstructions.canonical))
    }

    @Test("the transcript can separate fixed merge rules from the visible request")
    func mergeRulesHaveACompactPresentation() throws {
        let worktree = try emptyWorktree()
        let turn = ProjectInstructions.turn(
            "Merge #42.", for: .merge,
            adding: ProjectInstructions.resolve(.merge, in: worktree, stated: nil)
        )

        let presented = try #require(MergeTurn.split(turn))

        #expect(presented.message == "Merge #42.")
        #expect(presented.instructions == MergeInstructions.canonical)
    }

    @Test("ordinary user text is never mistaken for a merge request")
    func ordinaryTextDoesNotBecomeMergeContext() {
        #expect(MergeTurn.split("Please merge these two arrays.") == nil)
    }

    /// The asymmetry between the two, asserted rather than left to be rediscovered. Everything the
    /// conflict turn asks for is in its template, where somebody may reword it; the merge rules
    /// are not, because a reworded template must not be able to delete the paragraph about
    /// `--admin`.
    @Test("resolving a conflict adds no rules of Bloom's own")
    func conflictsAddNothingOfBloomsOwn() {
        #expect(ProjectInstructions.canonical(for: .fixConflicts) == nil)
        #expect(ProjectInstructions.turn("Fix #42.", for: .fixConflicts, adding: .nothing)
            == "Fix #42.")
    }

    /// Both subjects go through one call, and the sentence has to name the right one: an agent
    /// resolving a conflict told to follow "the instructions for merging" is being pointed at the
    /// other button.
    @Test("each subject asks for its own file, in its own words")
    func subjectsAreNotConfused() {
        let merge = ProjectInstructions.sentence(for: .merge, adding: .file("a.md")) ?? ""
        let conflicts = ProjectInstructions.sentence(
            for: .fixConflicts, adding: .file("b.md")
        ) ?? ""

        #expect(merge.contains("instructions for merging"))
        #expect(conflicts.contains("instructions for resolving merge conflicts"))
        #expect(ProjectInstructions.projectPath(for: .merge) == ".bloom/merge-instructions.md")
        #expect(ProjectInstructions.projectPath(for: .fixConflicts)
            == ".bloom/conflict-instructions.md")
    }

    @Test("the settings window is told about a file that outranks its field")
    func filesAreReportedToTheWindow() throws {
        let worktree = try emptyWorktree()
        try write("Squash.\n", to: ProjectInstructions.projectPath(for: .merge), in: worktree)

        let found = ProjectInstructions.files(in: worktree)

        #expect(found == [.merge: ProjectInstructions.projectPath(for: .merge)])
    }

    // MARK: - Support

    private func emptyWorktree() throws -> String {
        let path = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ contents: String, to relative: String, in worktree: String) throws {
        let full = (worktree as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try contents.write(toFile: full, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String, in worktree: String) -> String? {
        try? String(
            contentsOfFile: (worktree as NSString).appendingPathComponent(relative), encoding: .utf8
        )
    }
}
