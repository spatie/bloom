import Testing
import Foundation
@testable import BloomCore

@Suite("Carrying an archived conversation on")
struct CarryOnGateTests {
    /// An archived workspace whose pull request merged and whose branch was deleted on both
    /// sides, which is the state this whole feature exists for.
    private func facts(
        branch: String = "dark-mode-toggle",
        base: String = "main",
        defaultBranch: String = "main",
        branches: [String] = ["main", "develop"],
        source: RestoreSource? = .gone,
        thread: String? = "28e661ae-649a-4fa4-97c8-86fd66d72cc3",
        kind: AgentKind = .claudeCode
    ) -> CarryOnFacts {
        CarryOnFacts(
            branch: branch,
            baseBranch: base,
            defaultBranch: defaultBranch,
            branches: branches,
            restoreSource: source,
            agentSessionID: thread,
            agentKind: kind
        )
    }

    @Test("a merged workspace whose branch is gone is carried on, on the next branch along")
    func offered() {
        let plan = CarryOnGate.decide(facts()).plan
        #expect(plan?.branch == "dark-mode-toggle-2")
        #expect(plan?.baseBranch == "main")
        #expect(plan?.agentSessionID == "28e661ae-649a-4fa4-97c8-86fd66d72cc3")
    }

    @Test("nothing is offered while the branch is still being looked for")
    func stillLooking() {
        // Not a refusal the user ever reads: it is what keeps a disabled Restore on screen for
        // the second the fetch takes, rather than flickering a second button into the row.
        #expect(CarryOnGate.decide(facts(source: nil)).refusal == .stillLooking)
    }

    @Test("a workspace that can be restored is not offered a lossier way back")
    func restorable() {
        #expect(CarryOnGate.decide(facts(source: .localBranch)).refusal == .canBeRestored)
        #expect(
            CarryOnGate.decide(facts(source: .remoteBranch(ref: "refs/remotes/origin/x")))
                .refusal == .canBeRestored
        )
    }

    @Test("a chat no agent ever ran in has no thread to resume")
    func neverRan() {
        #expect(CarryOnGate.decide(facts(thread: nil)).refusal == .neverRan)
        #expect(CarryOnGate.decide(facts(thread: "")).refusal == .neverRan)
        #expect(CarryOnGate.decide(facts(thread: "   ")).refusal == .neverRan)
    }

    @Test("a backend Bloom has no runner for cannot pick a thread up")
    func backend() {
        #expect(
            CarryOnGate.decide(facts(kind: .cursor)).refusal == .backendCannotResume(.cursor)
        )
        #expect(CarryOnGate.decide(facts(kind: .codex)).plan?.agentKind == .codex)
    }

    @Test("the plan carries the chat's own backend, so the thread goes back to the CLI that has it")
    func backendTravels() {
        #expect(CarryOnGate.decide(facts(kind: .claudeCode)).plan?.agentKind == .claudeCode)
    }

    @Test("a base branch that has itself been deleted since falls back to the project's default")
    func staleBase() {
        // The archive's base was a long-lived branch somebody has since removed. Cutting from a
        // ref that is not there fails in git; the create window already has this rule for a
        // picker whose selection did not survive a branch listing, and this is the same stale
        // selection arriving from a row instead.
        let plan = CarryOnGate.decide(
            facts(base: "release-3", defaultBranch: "main", branches: ["main", "develop"])
        ).plan
        #expect(plan?.baseBranch == "main")
    }

    @Test("a base branch that is still there is used, default branch or not")
    func liveBase() {
        let plan = CarryOnGate.decide(
            facts(base: "develop", defaultBranch: "main", branches: ["main", "develop"])
        ).plan
        #expect(plan?.baseBranch == "develop")
    }

    @Test("the archived branch's own name is not reused, free though it is")
    func neverTheOldName() {
        // Nothing holds it: that is what Restore being unavailable means. Taking it anyway would
        // make a workspace that is indistinguishable from the archived one rather than one that
        // says it is carrying it on, and would put a merged pull request's branch name back on
        // the server at the first push.
        let plan = CarryOnGate.decide(facts(branches: ["main"])).plan
        #expect(plan?.branch == "dark-mode-toggle-2")
    }

    @Test("the new branch avoids every branch the repository already has")
    func avoidsTakenBranches() {
        let plan = CarryOnGate.decide(
            facts(branches: ["main", "dark-mode-toggle-2", "dark-mode-toggle-3"])
        ).plan
        #expect(plan?.branch == "dark-mode-toggle-4")
    }

    @Test("a branch prefix comes along, because the whole name is carried rather than rebuilt")
    func keepsPrefix() {
        let plan = CarryOnGate.decide(facts(branch: "freek/dark-mode-toggle")).plan
        #expect(plan?.branch == "freek/dark-mode-toggle-2")
    }

    @Test("a name git would not accept is refused rather than handed to git")
    func invalidName() {
        #expect(CarryOnGate.decide(facts(branch: "has a space")).refusal == .noValidName)
    }

    @Test("the refusals are ordered so the reader's actual state is the one that decides")
    func order() {
        // Every one of these is wrong at once. Not knowing where the branch is comes first,
        // because a screen that has not finished looking must not report that no agent ever ran.
        #expect(
            CarryOnGate.decide(facts(source: nil, thread: nil, kind: .cursor)).refusal
                == .stillLooking
        )
        // Then the restore, because Restore is the better offer and this one would be a second
        // answer beside it.
        #expect(
            CarryOnGate.decide(facts(source: .localBranch, thread: nil)).refusal == .canBeRestored
        )
    }
}

@Suite("The turn that hands an archive over")
struct ArchivedCarryOnTests {
    private let handover = ArchivedCarryOn(
        name: "Dark mode toggle",
        project: "Bloom",
        previousBranch: "freek/dark-mode-toggle",
        previousPath: "/Users/freek/bloom-workspaces/bloom/dark-mode-toggle",
        branch: "freek/dark-mode-toggle-2",
        baseBranch: "main"
    )

    @Test("every variable the registry offers is filled in")
    func everyVariable() {
        let values = handover.promptValues()
        let declared = PromptRegistry.definition(for: .carryOnArchived).variables.map(\.name)
        // A variable in the registry with no value behind it renders as its own token, so the
        // agent is handed `{{previous_path}}` in place of a path. Pinning the two lists together
        // is what stops that.
        #expect(Set(declared) == Set(values.keys))
    }

    @Test("the default template names the archive, the branch it lost and the branch it is on now")
    func rendersTheDefault() {
        let render = handover.render(
            template: PromptRegistry.definition(for: .carryOnArchived).defaultTemplate
        )
        #expect(render.text.contains("Dark mode toggle"))
        #expect(render.text.contains("freek/dark-mode-toggle-2"))
        #expect(render.text.contains("/Users/freek/bloom-workspaces/bloom/dark-mode-toggle"))
        #expect(render.text.contains("main"))
        #expect(render.text.contains("Bloom"))
        // Nothing was left unsubstituted.
        #expect(!render.text.contains("{{"))
    }

    @Test("the banner sentence says what is on offer without promising the workspace comes back")
    func standingSentence() {
        let sentence = ArchivedCarryOn.standing(project: "Bloom", baseBranch: "main")
        #expect(sentence.contains("main"))
        #expect(sentence.contains("Bloom"))
        // The one thing it must say, because a reader who thinks the archive is being reopened
        // has been misled about what they are pressing.
        #expect(sentence.contains("This archive is left exactly as it is."))
    }

    @Test("the plan and the archived row are enough to build it")
    func fromAPlan() {
        let workspace = Workspace(
            repoID: RepoID("repo"),
            name: "Dark mode toggle",
            branch: "freek/dark-mode-toggle",
            path: "/Users/freek/bloom-workspaces/bloom/dark-mode-toggle",
            baseBranch: "main"
        )
        let built = ArchivedCarryOn(
            workspace: workspace,
            project: "Bloom",
            plan: CarryOnPlan(
                branch: "freek/dark-mode-toggle-2",
                baseBranch: "main",
                agentSessionID: "thread",
                agentKind: .claudeCode
            )
        )
        #expect(built == handover)
    }
}
