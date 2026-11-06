import Foundation
import Testing
@testable import BloomCore

/// The decisions that keep the project's own checkout from being treated as a worktree, each one
/// asked of the checkout and of a worktree with the same facts, so a rule that went missing for
/// one and a rule that leaked onto the other both fail here. See `WorkspaceKind`.
@Suite("Project checkout rules")
struct ProjectCheckoutRulesTests {
    private let repo = Repo(name: "limbo", path: "/Users/someone/Herd/limbo")

    private func row(_ kind: WorkspaceKind, at path: String? = nil, branch: String = "main") -> Workspace {
        Workspace(
            repoID: repo.id, name: "row", branch: branch, path: path ?? repo.path,
            baseBranch: branch, kind: kind
        )
    }

    // MARK: - Setup, autostart, diff

    @Test("no setup is offered in the checkout, and a worktree still offers it")
    func setupOffer() {
        #expect(SetupRunOffer.offer(
            hasSetupScript: true, hasRunSetup: false, isRunning: false,
            allowsSetup: WorkspaceKind.projectCheckout.allowsSetup
        ) == nil)
        #expect(SetupRunOffer.offer(
            hasSetupScript: true, hasRunSetup: false, isRunning: false,
            allowsSetup: WorkspaceKind.worktree.allowsSetup
        ) != nil)
    }

    @Test("approved autostart scripts start in a worktree and not in the checkout")
    func autostart() {
        let vite = RunScript(id: "vite", name: "Vite", command: "npm run dev", autostart: true)
        let approval = RunScriptAutostartApproval().approving([vite])

        #expect(RunScriptAutostart.decide(scripts: [vite], approval: approval, kind: .projectCheckout) == .nothing)
        #expect(RunScriptAutostart.decide(scripts: [vite], approval: approval, kind: .worktree) == .run([vite]))
    }

    @Test("the checkout offers one scope and calls it what it shows")
    func diffScopes() {
        #expect(DiffScope.offered(for: .projectCheckout) == [.all])
        #expect(DiffScope.all.title(for: .projectCheckout) == "Uncommitted changes")
        #expect(DiffScope.all.emptyMessage(base: "main", kind: .projectCheckout).contains("checkout"))

        #expect(DiffScope.offered(for: .worktree) == [.all, .uncommitted])
        #expect(DiffScope.all.title == "All branch changes")
        #expect(DiffScope.all.emptyMessage(base: "main") == "Nothing in this worktree differs from main.")
    }

    // MARK: - Branch moves

    @Test("the checkout's branch is never renamed, and a worktree with the same facts is")
    func rename() {
        var facts = BranchRenameFacts(
            recordedBranch: "main", checkedOutBranch: "main", desiredBranch: "fix-login"
        )
        #expect(BranchRenameGate.decide(facts) == .rename(to: "fix-login"))

        facts.isProjectCheckout = true
        #expect(BranchRenameGate.decide(facts) == .refuse(.projectCheckout))
        #expect(!BranchRenameRefusal.projectCheckout.isWorthReporting)
    }

    @Test("Continue never moves the checkout to a new branch, even after a merge")
    func continuation() {
        var facts = ContinuationFacts(
            mergedBranch: "feature", checkedOutBranch: "feature", baseBranch: "main",
            isPullRequestMerged: true
        )
        #expect(ContinuationGate.decide(facts).refusal == nil)

        facts.isProjectCheckout = true
        #expect(ContinuationGate.decide(facts) == .refuse(.projectCheckout))
    }

    // MARK: - Archive wording

    @Test("the archive confirmation and notice say the checkout is left as it is")
    func archiveWording() {
        let checkout = ArchiveRequest.preservedFolderNotice(for: row(.projectCheckout), path: repo.path)
        #expect(checkout.contains("own checkout"))
        #expect(!checkout.contains("no longer recognizes"))

        let stray = ArchiveRequest.preservedFolderNotice(for: row(.worktree, at: "/tmp/w"), path: "/tmp/w")
        #expect(stray.contains("no longer recognizes"))
    }

    // MARK: - Lookups

    @Test("the live checkout of a project is found, archived ones and other projects are not")
    func liveLookup() {
        var archived = row(.projectCheckout)
        archived.archive()
        let other = Workspace(
            repoID: RepoID("elsewhere"), name: "x", branch: "main", path: "/x", baseBranch: "main",
            kind: .projectCheckout
        )
        let live = row(.projectCheckout)

        #expect(WorkspaceKind.liveProjectCheckout(in: repo.id, among: [archived, other]) == nil)
        #expect(WorkspaceKind.liveProjectCheckout(in: repo.id, among: [archived, other, live])?.id == live.id)
        #expect(WorkspaceKind.liveProjectCheckout(in: repo.id, among: [live], excluding: live.id) == nil)
    }

    // MARK: - The owner's registration inside the checkout

    @Test("the owner's own terminal is let through in a live checkout")
    func ownerTerminalLetThrough() {
        let workspaces = [row(.projectCheckout)]
        let directory = repo.path + "/app/Models"

        #expect(BridgeOwnerPlacement.needsLineage(workingDirectory: directory, workspaces: workspaces))
        #expect(BridgeOwnerPlacement.refusal(
            workingDirectory: directory, workspaces: workspaces, descendsFromBloom: false
        ) == nil)
    }

    @Test("a process Bloom started in the checkout is refused, and so is an unread lineage")
    func bloomDescendantRefused() throws {
        let workspaces = [row(.projectCheckout)]

        let refusal = try #require(BridgeOwnerPlacement.refusal(
            workingDirectory: repo.path, workspaces: workspaces, descendsFromBloom: true
        ))
        #expect(refusal.contains("project checkout"))
        #expect(BridgeOwnerPlacement.refusal(
            workingDirectory: repo.path, workspaces: workspaces, descendsFromBloom: nil
        ) != nil)
    }

    @Test("a worktree kept under the project's folder is still refused as a worktree")
    func nestedWorktreeRefused() throws {
        let nested = repo.path + "/.worktrees/feature"
        let workspaces = [row(.projectCheckout), row(.worktree, at: nested, branch: "feature")]

        #expect(!BridgeOwnerPlacement.needsLineage(workingDirectory: nested, workspaces: workspaces))
        let refusal = try #require(BridgeOwnerPlacement.refusal(
            workingDirectory: nested + "/src", workspaces: workspaces, descendsFromBloom: false
        ))
        #expect(refusal.contains("outside Bloom's workspaces"))
    }

    @Test("a process under the app or its tmux server descends from Bloom, a terminal's does not")
    func lineage() {
        let table = ProcessTable(rows: [
            .init(pid: 100, parent: 1, group: 100, command: "/Applications/Bloom.app/Contents/MacOS/Bloom"),
            .init(pid: 200, parent: 100, group: 200, command: "claude -p"),
            .init(pid: 201, parent: 200, group: 200, command: "bloom-bridge"),
            .init(pid: 300, parent: 1, group: 300, command: "tmux -L bloom-abc123 -f /tmp/conf -u new-session"),
            .init(pid: 301, parent: 300, group: 301, command: "-zsh"),
            .init(pid: 302, parent: 301, group: 302, command: "claude"),
            .init(pid: 400, parent: 1, group: 400, command: "/System/Applications/Utilities/Terminal.app"),
            .init(pid: 401, parent: 400, group: 401, command: "-zsh"),
            .init(pid: 402, parent: 401, group: 402, command: "claude"),
        ])

        #expect(table.descends(201, fromApp: 100, tmuxSocket: "bloom-abc123"))
        #expect(table.descends(302, fromApp: 100, tmuxSocket: "bloom-abc123"))
        #expect(!table.descends(402, fromApp: 100, tmuxSocket: "bloom-abc123"))
        // Another copy's tmux server is not this app's.
        #expect(!table.descends(302, fromApp: 100, tmuxSocket: "bloom-other"))
    }

    // MARK: - workspace_start reading

    @Test("project_checkout is a source of its own and cannot be combined with another")
    func readingTheFlag() {
        #expect(AgentStartRequest.read(baseBranch: nil, existingBranch: nil, projectCheckout: true) == .projectCheckout)
        guard case .refused(let sentence) = AgentStartRequest.read(
            baseBranch: "main", existingBranch: nil, projectCheckout: true
        ) else {
            Issue.record("a combination was not refused")
            return
        }
        #expect(sentence.contains("project_checkout"))
    }

    @Test("a project checkout call digests apart from every older call")
    func digest() {
        let parent = WorkspaceID(rawValue: "w-parent")
        let checkout = AgentWorkspaceOrder(prompt: "look at it", source: .projectCheckout)
        let cut = AgentWorkspaceOrder(prompt: "look at it", source: .newBranch(from: nil))

        #expect(checkout.spawnID(parentWorkspaceID: parent) != cut.spawnID(parentWorkspaceID: parent))
        #expect(AgentStartSource.projectCheckout.kind == .projectCheckout)
        #expect(AgentStartSource.newBranch(from: nil).kind == .worktree)
    }

    @Test("naming the project's own branch as existing_branch points at project_checkout")
    func refusalPointsAtTheFlag() {
        let checkout = BranchHolder.projectCheckout(path: repo.path).agentRefusal(branch: "main")
        let elsewhere = BranchHolder.otherWorktree(path: "/tmp/x").agentRefusal(branch: "main")

        #expect(checkout.contains("project_checkout"))
        #expect(!elsewhere.contains("project_checkout"))
    }
}

extension ProjectCheckoutRulesTests {
    @Test("a chat in the checkout starts on Auto rather than Bypass, and other defaults stand")
    func startingPermission() {
        #expect(WorkspaceKind.projectCheckout.startingPermission(.bypassPermissions) == .auto)
        #expect(WorkspaceKind.projectCheckout.startingPermission(.acceptEdits) == .acceptEdits)
        #expect(WorkspaceKind.worktree.startingPermission(.bypassPermissions) == .bypassPermissions)
    }
}
