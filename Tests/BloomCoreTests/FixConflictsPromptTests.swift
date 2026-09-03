import Foundation
import Testing
@testable import BloomCore

/// The strip used to draw Merge over a branch GitHub had already refused to merge, so the press
/// could only ever produce a refusal read back out of `gh`. These are the two halves of the answer
/// to that: the state says which button belongs there, and the prompt says what the press asks for.
@Suite("Fix merge conflicts")
struct FixConflictsPromptTests {
    /// The decision that belongs in the core rather than in the view. A conflicted pull request is
    /// the one open state whose remedy is neither merging nor pushing.
    @Test("a conflicted pull request offers the fix rather than the merge")
    func conflictsOfferTheFix() {
        let status = conflicted().status

        #expect(status.remedy == .fixConflicts)
        #expect(status.text == "Merge conflicts")
        // The button changes; what the menu beside it is allowed to do does not. GitHub has said
        // this branch does not apply to its base, so merging stays blocked and stays explained.
        #expect(!status.canMerge)
        #expect(status.blockedReason != nil)
    }

    /// gh reports the same fact through two fields with different vocabularies, depending on which
    /// version is installed, and the button has to follow both.
    @Test("both of gh's words for a conflict reach the same button", arguments: [
        "CONFLICTING", "DIRTY", "conflicting",
    ])
    func bothVocabularies(mergeable: String) {
        #expect(conflicted(mergeable: mergeable).status.remedy == .fixConflicts)
    }

    /// Uncommitted work does not take this state's headline and must not take its button either.
    /// Resolving a conflict is going to make more local work rather than less, so a strip pointing
    /// at Commit and push here would be pointing at the second step.
    @Test("local work does not move the conflicting state off the fix")
    func localWorkDoesNotWin() {
        let status = conflicted().status(local: LocalWork(modifiedFiles: 3, unpushedCommits: 1))

        #expect(status.remedy == .fixConflicts)
        #expect(status.text == "Merge conflicts")
    }

    /// Everything the state reports on its own keeps the button it had. A widened remedy that
    /// leaked into a healthy pull request would put a wrench where Merge belongs.
    @Test("nothing else in the strip gains the fix", arguments: [
        "MERGEABLE", "UNKNOWN", "",
    ])
    func onlyConflictsGetIt(mergeable: String) {
        #expect(conflicted(mergeable: mergeable).status.remedy == .merge)
    }

    @Test("the default prompt renders every fact it names")
    func rendersFully() {
        let definition = PromptRegistry.definition(for: .fixConflicts)
        let render = context().render(template: definition.defaultTemplate)

        #expect(render.unknown.isEmpty)
        #expect(render.missing.isEmpty)
        #expect(render.text.contains("#42"))
        #expect(render.text.contains("main"))
        #expect(render.text.contains("feature/glyphs"))
    }

    /// What this turn may and may not do, asserted rather than trusted, and asserted in the half
    /// that carries it now.
    ///
    /// The push is the point: a conflict resolved in a worktree nobody has pushed is still a
    /// conflict to GitHub, and the button is called Fix merge conflicts. The merge is still the
    /// reader's, and that limit stays in the message rather than only in the file, because a
    /// transcript read months later has to be able to say what the turn was not allowed to do
    /// without opening a file the worktree may have taken with it.
    @Test("the message pushes the resolution and merges nothing")
    func pushesButDoesNotMerge() {
        let text = PromptRegistry.definition(for: .fixConflicts).defaultTemplate

        #expect(text.contains("push {{branch}}"))
        #expect(text.contains("Do not merge the pull request"))
        #expect(!text.contains("gh pr merge"))
    }

    /// The message is the record of what was asked, so it has to be readable on its own: which
    /// pull request, which two branches, and what happens to them. Everything past that is the
    /// file's, and the wall of text this replaced is what happens when it is not.
    @Test("the message says what was asked without the steps that say how")
    func messageIsTheRecordAndNotTheProcedure() {
        let render = context().render(
            template: PromptRegistry.definition(for: .fixConflicts).defaultTemplate
        )

        #expect(render.text.contains("#42"))
        #expect(render.text.contains("feature/glyphs"))
        #expect(render.text.contains("main"))
        // The mechanics moved out, and this is what says they did rather than were dropped.
        #expect(!render.text.contains("--force-with-lease"))
        #expect(ConflictInstructions.defaultMarkdown.contains("--force-with-lease"))
        #expect(render.text.count < 500)
    }

    /// A workspace whose branch was never recorded still has a button to press, and a sentence
    /// that stops after "on " reads to an agent as an instruction that was cut off.
    @Test("a workspace with no branch name never renders a guess")
    func missingBranchIsSaidRatherThanGuessed() {
        var facts = context()
        facts.branch = ""

        let render = facts.render(template: "{{branch}}")

        #expect(render.text == FixConflictsPromptContext.noBranch)
        #expect(render.text.contains("this worktree is already on"))
    }

    private func conflicted(mergeable: String = "CONFLICTING") -> PullRequest {
        PullRequest(
            number: 42, title: "Draw the glyphs", url: "https://example/42", state: "OPEN",
            isDraft: false, mergeable: mergeable, checks: .passing,
            checksSummary: "12 of 12 checks passed", reviewDecision: nil, branch: "feature/glyphs"
        )
    }

    private func context() -> FixConflictsPromptContext {
        FixConflictsPromptContext(
            workspaceName: "Glyphs",
            number: 42,
            branch: "feature/glyphs",
            baseBranch: "main"
        )
    }
}

/// Bloom's own steps for resolving a conflict, and the file they go in.
///
/// The turn changed shape rather than wording: what used to be eight paragraphs in the chat is two
/// sentences and a path now, so everything that can go wrong with it is about the file. It has to
/// be there when the sentence names it, git has to stay blind to it, it must not land on the path
/// the project's own spilled settings already use, and a worktree that cannot be written to still
/// has to get the steps.
@Suite("Conflict instructions", .tags(.git), .scratchDirectory)
struct ConflictInstructionsTests {
    @Test("the steps go into the shielded scratch folder and the sentence names them")
    func writesIntoTheScratchFolder() throws {
        let worktree = try emptyWorktree()

        let turn = ConflictInstructions.asking("Resolve #42.", in: worktree)

        #expect(WorktreeScratch.isShielded(ConflictInstructions.scratchPath))
        #expect(read(ConflictInstructions.scratchPath, in: worktree)
            == ConflictInstructions.defaultMarkdown)
        #expect(turn == """
        Resolve #42.

        Follow the instructions in `\(ConflictInstructions.scratchPath)`.
        """)
        // And it reads back as one attachment, in the same form as a file somebody dropped into
        // the composer, so the transcript draws a chip for it without being told anything.
        #expect(AttachmentDraft.parse(turn).paths == [ConflictInstructions.scratchPath])
    }

    /// The path this file must not have, asserted because the collision would be silent.
    /// `ProjectInstructions` already writes `.bloom/scratch/conflict-instructions.md` for the
    /// project's settings field spilled out as a file, and one press composes both: two writers on
    /// one path would have each overwrite the other and point both sentences at whichever won.
    @Test("Bloom's file and the project's spilled settings are two different files")
    func doesNotCollideWithTheSpilledSettings() throws {
        let worktree = try emptyWorktree()

        let turn = ProjectInstructions.turn(
            ConflictInstructions.asking("Resolve #42.", in: worktree),
            for: .fixConflicts,
            adding: ProjectInstructions.resolve(
                .fixConflicts, in: worktree, stated: "Regenerate the lock file."
            )
        )

        let spilled = ProjectInstructions.scratchPath(for: .fixConflicts)
        #expect(ConflictInstructions.scratchPath != spilled)
        #expect(read(ConflictInstructions.scratchPath, in: worktree)
            == ConflictInstructions.defaultMarkdown)
        #expect(read(spilled, in: worktree) == "Regenerate the lock file.\n")
        // Both are named, in the order the agent reads them, and the project's is the one that
        // wins where the two disagree.
        #expect(AttachmentDraft.parse(turn).paths == [ConflictInstructions.scratchPath, spilled])
        #expect(turn.contains("where they disagree with anything above, they win"))
    }

    /// The bug the shield exists for, asserted against the real git binary, because the turn that
    /// carries this file is the one that tells the agent to commit the resolution, and an agent
    /// doing that reaches for `git add -A`.
    @Test("an agent told to commit the resolution cannot commit Bloom's file")
    func surviveAddEverything() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        _ = ConflictInstructions.asking("Resolve #42.", in: repo.path)

        try await Shell.check("git", ["add", "-A"], cwd: repo.path)
        let staged = try await Shell.check(
            "git", ["diff", "--cached", "--name-only"], cwd: repo.path
        )
        #expect(staged.trimmed.isEmpty, "git staged \(staged.trimmed)")

        let status = try await Shell.check("git", ["status", "--porcelain"], cwd: repo.path)
        #expect(status.trimmed.isEmpty, "git reported \(status.trimmed)")
    }

    /// Rewritten rather than kept, which is the rule `ProjectInstructions.spill` follows and the
    /// opposite of the one `PullRequestInstructions` follows. That one may keep its copy because
    /// its copy is a constant; this one is written from whatever the caller handed in, and a kept
    /// copy would be an agent following a wording that had already changed.
    @Test("a second press replaces the copy the first one left")
    func isNeverStale() throws {
        let worktree = try emptyWorktree()

        _ = ConflictInstructions.asking("Resolve #42.", in: worktree, contents: "First.")
        _ = ConflictInstructions.asking("Resolve #42.", in: worktree, contents: "Second.")

        #expect(read(ConflictInstructions.scratchPath, in: worktree) == "Second.")
    }

    /// A read-only checkout is a reason to say it differently, not a reason for the button to stop
    /// working. The message is a wall of text again in that case, which is the right trade: the
    /// steps reaching the agent matters more than the bubble being short.
    @Test("a worktree that cannot be written to still carries the steps")
    func fallsBackToTheMessage() {
        let turn = ConflictInstructions.asking("Resolve #42.", in: "/dev/null/nowhere")

        #expect(turn.hasPrefix("Resolve #42.\n\n"))
        #expect(turn.contains(ConflictInstructions.defaultMarkdown))
        #expect(!turn.contains(ConflictInstructions.scratchPath))
        #expect(ConflictInstructions.ensure(in: "/dev/null/nowhere") == nil)
    }

    /// The steps are the same in every workspace, so a branch name in them would be wrong for all
    /// but one, and a `{{token}}` left in them would reach the agent unrendered.
    @Test("the steps name no branch and no pull request")
    func nameNoFacts() {
        let text = ConflictInstructions.defaultMarkdown

        #expect(!text.contains(PromptTemplate.open))
        #expect(!text.contains("#42"))
        #expect(text.contains("the base branch"))
    }

    /// The three lines no shorter version of this file may lose, because each of them is a way
    /// this turn can make somebody's day worse.
    @Test("the steps keep the direction, the lease and the stop")
    func keepsWhatMatters() {
        let text = ConflictInstructions.defaultMarkdown

        #expect(text.contains("It goes into this branch and never the other way round."))
        #expect(text.contains("--force-with-lease"))
        #expect(text.contains("Do not push if you are not sure."))
        #expect(text.contains("Do not merge the pull request"))
    }

    /// A file git will not report is a file nobody finds by accident, and this one is overwritten
    /// on every press, so it has to say where an edit that lasts goes instead.
    @Test("the steps say which file a project writes instead of editing this one")
    func pointsAtTheProjectsOwnFile() {
        #expect(ConflictInstructions.defaultMarkdown
            .contains(ProjectInstructions.projectPath(for: .fixConflicts)))
    }

    // MARK: - Support

    private func emptyWorktree() throws -> String {
        let path = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func read(_ relative: String, in worktree: String) -> String? {
        try? String(
            contentsOfFile: (worktree as NSString).appendingPathComponent(relative), encoding: .utf8
        )
    }
}
