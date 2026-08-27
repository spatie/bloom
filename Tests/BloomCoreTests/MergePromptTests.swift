import Foundation
import Testing
@testable import BloomCore

/// Merging is the one destructive, off-machine thing Bloom offers, and it is now done by an agent
/// reading a prompt. So the prompt is the safety mechanism, and a prompt nothing asserts against
/// is a safety mechanism nobody is holding.
@Suite("Merge prompt")
struct MergePromptTests {
    @Test("the default prompt renders every fact the instructions cannot know")
    func rendersFully() {
        let definition = PromptRegistry.definition(for: .mergePullRequest)
        let render = context().render(template: definition.defaultTemplate)

        #expect(render.unknown.isEmpty)
        #expect(render.missing.isEmpty)
        #expect(render.text.contains("#42"))
        #expect(render.text.contains("main"))
        #expect(render.text.contains("feature/glyphs"))
        #expect(render.text.contains("squash merge"))
        #expect(render.text.contains("--squash"))
    }

    /// The flag is derived from the raw value gh is given, so the two can never say different
    /// things about the same method.
    @Test("every method has a phrase and the flag that performs it", arguments: [
        (method: GitHub.MergeMethod.squash, phrase: "squash merge", flag: "--squash"),
        (method: .merge, phrase: "merge commit", flag: "--merge"),
        (method: .rebase, phrase: "rebase merge", flag: "--rebase"),
    ])
    func methodWords(method: GitHub.MergeMethod, phrase: String, flag: String) {
        #expect(method.phrase == phrase)
        #expect(method.flag == flag)
    }

    /// An older gh does not report `headRefName`. A guessed branch name in a sentence that ends in
    /// `git push --delete` is the worst thing this file could produce, so the prompt says there is
    /// no name and tells the agent to leave the server's branch alone.
    @Test("a pull request with no branch name never renders a guess")
    func missingBranchIsSaidRatherThanGuessed() {
        var facts = context()
        facts.branch = ""

        let render = facts.render(template: "{{branch}}")

        #expect(render.text == MergePromptContext.noBranch)
        #expect(render.text.contains("do not guess"))
        #expect(render.text.contains("leave the branch on the server alone"))
    }

    @Test("a pull request with no title still reads as a sentence")
    func missingTitleIsSaid() {
        var facts = context()
        facts.title = ""

        #expect(facts.render(template: "{{title}}").text == MergePromptContext.noTitle)
    }

    private func context() -> MergePromptContext {
        MergePromptContext(
            workspaceName: "Bloom",
            number: 42,
            title: "Better glyphs",
            branch: "feature/glyphs",
            baseBranch: "main",
            method: .squash
        )
    }
}

/// The instructions the agent actually follows. Every assertion here is a thing that, if it were
/// missing, would let an agent do something to somebody's repository that nobody asked for.
///
/// They were a file until they were not: written into `.bloom/scratch/merge-instructions.md` on
/// every press and attached straight back, so what an agent had been told about a command that
/// changes a server lived in a file git will not report. They are in the message now, and the
/// tests that used to be about writing that file are gone with it. What a project adds on top is
/// `ProjectInstructionsTests`.
@Suite("Merge instructions")
struct MergeInstructionsTests {
    /// The rules are shared by every workspace in the repository, so the pull request, the branch
    /// and the method cannot be in them. They arrive in the sentence above them, which the merge
    /// prompt renders and this deliberately does not.
    @Test("the instructions name no pull request, branch or method")
    func namesNothingWorkspaceSpecific() {
        let text = MergeInstructions.canonical

        #expect(!text.contains("gh pr merge 42"))
        #expect(text.contains("<number>"))
        #expect(text.contains("<branch>"))
        #expect(text.contains("the message names"))
    }

    /// The merge and the branch deletion are two commands in one order. gh's `--delete-branch`
    /// would do both, and its local half fails from a worktree, which is the whole reason Bloom
    /// ever wrote the delete out by hand.
    @Test("the merge and the branch deletion are separate steps, in that order")
    func twoStepsNotOne() {
        let text = MergeInstructions.canonical

        #expect(text.contains("gh pr merge <number> <method flag>"))
        #expect(text.contains("git push --delete -- origin refs/heads/<branch>"))
        #expect(text.contains("Not `--delete-branch`"))
        #expect(text.contains("Only once the merge has actually succeeded"))
        // The merge is described before the deletion, because an agent reading top to bottom is
        // reading an order.
        guard let merge = text.range(of: "gh pr merge"),
              let delete = text.range(of: "git push --delete")
        else {
            Issue.record("the two commands are not both in the instructions")
            return
        }
        #expect(merge.lowerBound < delete.lowerBound)
    }

    /// A refusal from GitHub is an answer. The one failure mode that would be worse than not
    /// merging at all is an agent that reads a refusal as an obstacle and disables the rule that
    /// produced it.
    @Test("a refusal is an answer, and nothing may be forced to get round it")
    func refusalIsAnAnswer() {
        let text = MergeInstructions.canonical

        #expect(text.contains("If GitHub refuses the merge, stop."))
        #expect(text.contains("do not force it"))
        #expect(text.contains("branch protection"))
        #expect(text.contains("Not `--admin`"))
        #expect(text.contains("Not `--auto`"))
    }

    /// Bloom is an app built on worktrees, and the copy on this machine is the thing a reader is
    /// most afraid of losing.
    @Test("nothing on this machine is touched")
    func nothingLocalIsTouched() {
        let text = MergeInstructions.canonical

        #expect(text.contains("Change nothing on this machine."))
        #expect(text.contains("Do not commit and do not push."))
    }

    /// A constant rather than the prompt's `defaultTemplate`, so that somebody rewording the
    /// sentence that names the pull request cannot delete the paragraph forbidding `--admin` by
    /// accident. The template carries the facts and this carries the rules, and neither may drift
    /// into being the other.
    @Test("the editable template holds none of the rules")
    func theTemplateHoldsNoRules() {
        let template = PromptRegistry.definition(for: .mergePullRequest).defaultTemplate

        #expect(!template.contains("--admin"))
        #expect(!template.contains("git push --delete"))
        #expect(!MergeInstructions.canonical.contains("{{"))
    }
}

/// Merging stayed as permissive as it was, and this suite is where that decision is written down
/// rather than left to be rediscovered.
///
/// `canMerge` is true with failing checks, with no review, and with work still on this disk. It
/// was permissive because the reader is the only party who can say whether an untracked
/// `notes.md` belongs to this pull request, and it stays permissive for a stronger reason now:
/// GitHub is the authority on whether a merge may happen, the agent asks GitHub, and GitHub says
/// no in words the reader can act on. A button that refused first would be Bloom guessing an
/// answer that the next thirty seconds produces for real.
///
/// What is still refused is refused because there is nothing to ask GitHub about: a merged pull
/// request, a closed one, a conflicting one and a draft.
@Suite("Merge gating")
struct MergeGatingTests {
    @Test("a state GitHub might still merge keeps the button live", arguments: [
        "FAILING", "PENDING", "NONE",
    ])
    func permissiveWhereGitHubDecides(checks: String) throws {
        #expect(try pullRequest(state: "OPEN", checks: checks).status.canMerge)
    }

    @Test("work on this disk does not disable the button")
    func localWorkDoesNotBlock() throws {
        let status = try pullRequest(state: "OPEN", checks: "NONE")
            .status(local: LocalWork(modifiedFiles: 3))

        #expect(status.canMerge)
        #expect(status.blockedReason == nil)
    }

    @Test("a state with nothing left to ask GitHub is refused, with a reason", arguments: [
        "MERGED", "CLOSED",
    ])
    func refusesWhatIsFinished(state: String) throws {
        let status = try pullRequest(state: state, checks: "NONE").status

        #expect(!status.canMerge)
        #expect(status.blockedReason != nil)
    }

    private func pullRequest(state: String, checks: String) throws -> PullRequest {
        let run: String
        switch checks {
        case "FAILING":
            run = #"[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]"#
        case "PENDING":
            run = #"[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS","isRequired":true}]"#
        default:
            run = "[]"
        }
        let json = """
        {"number":42,"title":"Better glyphs","url":"https://github.com/a/b/pull/42",\
        "state":"\(state)","isDraft":false,"headRefName":"feature/glyphs",\
        "statusCheckRollup":\(run)}
        """
        return try GitHub.decodePullRequest(from: Data(json.utf8))
    }
}
