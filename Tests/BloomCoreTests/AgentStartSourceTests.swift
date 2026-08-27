import CryptoKit
import Foundation
import Testing
@testable import BloomCore

/// The choice the create window draws as two tabs, as `workspace_start` takes it: cut a new branch
/// from one, or carry on one that already exists.
///
/// Everything here is the pure half, which is where the decisions are. What the tool does with
/// them, and the git reads behind `listing`, are in `WorkspaceStartToolTests`.
@Suite("workspace_start: which branch")
struct AgentStartSourceTests {
    // MARK: Reading the two arguments

    @Test("a call that names neither gets what it has always got")
    func silenceIsANewBranch() {
        #expect(AgentStartRequest.read(baseBranch: nil, existingBranch: nil) == .newBranch(from: nil))
    }

    @Test("each argument names one of the sheet's two tabs")
    func eachArgumentNamesATab() {
        #expect(
            AgentStartRequest.read(baseBranch: "develop", existingBranch: nil)
                == .newBranch(from: "develop")
        )
        #expect(
            AgentStartRequest.read(baseBranch: nil, existingBranch: "freek/figma")
                == .existingBranch("freek/figma")
        )
    }

    /// Opposite in effect and one keystroke apart in intent, which is why the sheet draws them as
    /// two tabs rather than as two rows of one list. A call that asked for both has not chosen.
    @Test("naming both is refused, and the refusal says what each one does")
    func bothIsRefused() {
        guard case .refused(let sentence) = AgentStartRequest.read(
            baseBranch: "main", existingBranch: "freek/figma"
        ) else {
            Issue.record("naming both should be refused")
            return
        }

        #expect(sentence.contains("'main'"))
        #expect(sentence.contains("'freek/figma'"))
        #expect(sentence.contains("base_branch"))
        #expect(sentence.contains("existing_branch"))
    }

    // MARK: Finding the branch

    private let branches = [
        ExistingBranch(name: "freek/figma", isLocal: true),
        ExistingBranch(name: "main", isLocal: true),
        ExistingBranch(name: "release/3.0", isLocal: false),
    ]

    @Test("a branch that is there, local or only on the remote, is found")
    func found() {
        #expect(
            AgentStartBranch.find("freek/figma", among: branches, project: "flare")
                == .found(branches[0])
        )
        #expect(
            AgentStartBranch.find("release/3.0", among: branches, project: "flare")
                == .found(branches[2])
        )
    }

    /// A model that has just run `git branch -r` writes down what git printed. Refusing that over
    /// a prefix Bloom strips everywhere else would be refusing the right branch.
    @Test("the name git prints for a remote branch finds the same branch")
    func remotePrefixIsStripped() {
        #expect(
            AgentStartBranch.find("origin/release/3.0", among: branches, project: "flare")
                == .found(branches[2])
        )
    }

    /// The whole reason the branch is looked up before anything is cut. A caller cannot see the
    /// picker, so the answer has to carry the list the picker would have shown.
    @Test("a branch that is not there is refused, and the refusal names what is")
    func unknownBranch() {
        guard case .refused(let sentence) = AgentStartBranch.find(
            "freek/figmaa", among: branches, project: "flare"
        ) else {
            Issue.record("an unknown branch should be refused")
            return
        }

        #expect(sentence.contains("'flare' has no branch called 'freek/figmaa'"))
        #expect(sentence.contains("'freek/figma'"))
        #expect(sentence.contains("'release/3.0'"))
        #expect(sentence.contains("existing_branch"))
    }

    @Test("a project with nothing to continue on says that rather than listing nothing")
    func noBranchesAtAll() {
        guard case .refused(let sentence) = AgentStartBranch.find(
            "main", among: [], project: "flare"
        ) else {
            Issue.record("an empty project should be refused")
            return
        }

        #expect(sentence.contains("no branches in the project 'flare'"))
        #expect(sentence.contains("no commits yet"))
    }

    /// Git allows one worktree per branch, so this is a refusal Bloom can make in words instead of
    /// letting git make it half way through a start.
    @Test("a branch something else is already on is refused, and the way out is an argument")
    func heldBranch() {
        let held = [ExistingBranch(name: "freek/figma", isLocal: true, inUseBy: .workspace("Coral Sea"))]

        guard case .refused(let sentence) = AgentStartBranch.find(
            "freek/figma", among: held, project: "flare"
        ) else {
            Issue.record("a held branch should be refused")
            return
        }

        #expect(sentence.contains("Coral Sea"))
        #expect(sentence.contains("one worktree per branch"))
        // The offer names the argument rather than the tab, because a tab is not something an
        // agent can be sent to.
        #expect(sentence.contains("base_branch"))
        #expect(!sentence.contains("tab"))
    }

    @Test("the project's own checkout is named by its path, not called a workspace")
    func heldByTheProjectItself() {
        let held = [
            ExistingBranch(name: "main", isLocal: true, inUseBy: .projectCheckout(path: "/dev/flare")),
        ]

        guard case .refused(let sentence) = AgentStartBranch.find(
            "main", among: held, project: "flare"
        ) else {
            Issue.record("a held branch should be refused")
            return
        }

        #expect(sentence.contains("/dev/flare"))
        #expect(sentence.contains("the project itself is on"))
    }

    // MARK: What the source becomes

    @Test("a new branch carries a base and no checkout")
    func newBranchSource() {
        let source = AgentStartSource.newBranch(from: "develop")

        #expect(source.tab == .newBranch)
        #expect(source.baseBranch == "develop")
        #expect(source.namedBranch == "develop")
        #expect(source.checkout == nil)
    }

    /// The point of the whole thing: what reaches `WorkspaceManager` is the same `WorkspaceCheckout`
    /// the create window hands it, so the worktree lands on the branch rather than beside it.
    @Test("an existing branch carries a checkout and no base")
    func existingBranchSource() {
        let branch = ExistingBranch(name: "freek/figma", isLocal: true)
        let source = AgentStartSource.existingBranch(branch)

        #expect(source.tab == .existingBranch)
        #expect(source.baseBranch == nil)
        #expect(source.namedBranch == "freek/figma")
        #expect(source.checkout == .branch(branch))
    }

    // MARK: The spawn digest

    /// Spawn ids are stored on workspace rows, so a call made before `existing_branch` existed has
    /// to digest the same way after it: a key that shifted would answer every retry of an older
    /// call with a second worktree. Pinned against the digest computed by hand rather than against
    /// a literal, so the reason survives a change to how the material is joined.
    @Test("a call that names no existing branch digests exactly as it did before there was one")
    func digestIsStableForOlderCalls() {
        let parent = WorkspaceID(rawValue: "w-parent")
        let order = AgentWorkspaceOrder(prompt: "Import the webhooks", source: .newBranch(from: "develop"))

        let material = [parent.rawValue, "Import the webhooks", "", "develop", ""]
            .joined(separator: "\u{0}")
        let expected = SHA256.hash(data: Data(material.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()

        #expect(order.spawnID(parentWorkspaceID: parent) == expected)
    }

    @Test("cutting from a branch and carrying it on are two different calls")
    func digestTellsTheTwoVerbsApart() {
        let parent = WorkspaceID(rawValue: "w-parent")
        let cut = AgentWorkspaceOrder(prompt: "look at it", source: .newBranch(from: "freek/figma"))
        let carryOn = AgentWorkspaceOrder(
            prompt: "look at it",
            source: .existingBranch(ExistingBranch(name: "freek/figma", isLocal: true))
        )

        #expect(cut.spawnID(parentWorkspaceID: parent) != carryOn.spawnID(parentWorkspaceID: parent))
    }
}
