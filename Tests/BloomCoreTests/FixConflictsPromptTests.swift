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

    /// What this turn may and may not do, asserted rather than trusted.
    ///
    /// The push is the point: a conflict resolved in a worktree nobody has pushed is still a
    /// conflict to GitHub, and the button is called Fix merge conflicts. The merge is still the
    /// reader's, and a rewritten history needs the lease, or a push lands on top of somebody.
    @Test("the default prompt pushes the resolution and merges nothing")
    func pushesButDoesNotMerge() {
        let text = PromptRegistry.definition(for: .fixConflicts).defaultTemplate

        #expect(text.contains("Then push it."))
        #expect(text.contains("--force-with-lease"))
        #expect(text.contains("Do not merge the pull request"))
        #expect(!text.contains("gh pr merge"))
    }

    /// The half of the instruction that keeps a bad resolution off the server. An agent that is
    /// guessing has to stop, and the sentence that tells it so has to survive an edit of the rest.
    @Test("the default prompt tells an agent that is unsure not to push")
    func uncertaintyStops() {
        let text = PromptRegistry.definition(for: .fixConflicts).defaultTemplate

        #expect(text.contains("Do not push if you are not sure."))
    }

    /// The direction of the merge is the one thing in this prompt that must not be guessed, so
    /// both branches are named and the sentence says which way round they go.
    @Test("the default prompt brings the base in rather than the other way round")
    func namesTheDirection() {
        let render = context().render(
            template: PromptRegistry.definition(for: .fixConflicts).defaultTemplate
        )

        #expect(render.text.contains("It goes into this branch and never the other way round."))
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
