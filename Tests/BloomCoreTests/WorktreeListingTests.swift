import Foundation
import Testing
@testable import BloomCore

/// `git worktree list --porcelain`, and who a branch of this repository is held by.
///
/// The fixtures are output this Mac actually produced, not output anybody imagined. The
/// there-there project lists twenty-two worktrees over three applications, several locked by an
/// agent, with the main checkout among them looking exactly like the rest; the Bloom repository
/// adds the `locked <reason>` line. Both are trimmed to the records that make a point, and not one
/// character of a record is changed.
@Suite("Worktree listing")
struct WorktreeListingTests {
    /// `git worktree list --porcelain` in /Users/freek/dev/code/there-there, trimmed to six of its
    /// twenty-two records: the main checkout, two of Bloom's, and three of Conductor's, including
    /// the one that held pull request #362's branch and made this whole thing necessary.
    static let thereThere = """
        worktree /Users/freek/dev/code/there-there
        HEAD 67bfc360dad6fea4dcecb3964c027b0800bb0801
        branch refs/heads/main

        worktree /Users/freek/bloom/workspaces/there-there/freekmurze-mawson-sea
        HEAD ba5d665bd1d21692e8bd4c24e59bd74889d58338
        branch refs/heads/freekmurze/review-changes

        worktree /Users/freek/bloom/workspaces/there-there/freekmurze-molucca-sea
        HEAD ba5d665bd1d21692e8bd4c24e59bd74889d58338
        branch refs/heads/freekmurze/review-repo-changes

        worktree /Users/freek/conductor/workspaces/there-there/adelaide
        HEAD ba5d665bd1d21692e8bd4c24e59bd74889d58338
        branch refs/heads/freekmurze/figma-mcp-check

        worktree /Users/freek/conductor/workspaces/there-there/port-louis
        HEAD 9a5419ea7120db9a74ae0486c9b19f808d9cdc90
        branch refs/heads/freekmurze/investigate-ticket-issues

        worktree /Users/freek/orca/workspaces/there-there/anglerfish
        HEAD a870d24b0287a3f9c7c3273d54a9a970c4d0bc82
        branch refs/heads/freekmurze/delete-ticket-workflow-crash

        """

    /// The same command in the Bloom repository, whose agents lock the worktrees they are working
    /// in. `locked <reason>` is the line that arrives with them.
    static let bloom = """
        worktree /Users/freek/dev/code/bloom
        HEAD 7c28676194979a756ff1ec3987b75bf9e6eb1e04
        branch refs/heads/feat/quick-prompt-icon-picker

        worktree /Users/freek/dev/code/bloom/.claude/worktrees/agent-a027934bc60df6d12
        HEAD 97c58990967b1f091feac9de1d019b28edabcbca
        branch refs/heads/docs/audit-fixes

        worktree /Users/freek/dev/code/bloom/.claude/worktrees/agent-a2f34e223cc574ba6
        HEAD 4d885856a5ee18427ed0d771bbf6b76c116dfcc2
        branch refs/heads/swiftlint
        locked claude agent agent-a2f34e223cc574ba6 (pid 2545 start Mon Aug 24 13:40:21 2026)

        """

    // MARK: - Parsing what git prints

    @Test("every record of a real listing is read, in the order git printed them")
    func readsARealListing() {
        let entries = WorktreeListing.parse(Self.thereThere)
        #expect(entries.count == 6)
        #expect(entries.first?.path == "/Users/freek/dev/code/there-there")
        #expect(entries.first?.branch == "main")
        #expect(entries.last?.path == "/Users/freek/orca/workspaces/there-there/anglerfish")
    }

    /// The failure that started this. Only the `refs/heads/` prefix comes off: a branch name may
    /// itself carry slashes, and the name git refused to check out twice is the whole of
    /// `freekmurze/figma-mcp-check`, so anything shorter would not match the branch being asked for.
    @Test("a branch is the full ref with refs/heads/ taken off and nothing else")
    func keepsSlashesInsideABranchName() {
        let entries = WorktreeListing.parse(Self.thereThere)
        let adelaide = entries.first { $0.path.hasSuffix("/adelaide") }
        #expect(adelaide?.branch == "freekmurze/figma-mcp-check")
        #expect(adelaide?.head == "ba5d665bd1d21692e8bd4c24e59bd74889d58338")
    }

    @Test("a locked worktree carries its reason and still holds its branch")
    func readsALockedWorktree() {
        let entries = WorktreeListing.parse(Self.bloom)
        let locked = entries.first { $0.branch == "swiftlint" }
        #expect(locked?.isLocked == true)
        #expect(locked?.lockReason?.hasPrefix("claude agent agent-a2f34e223cc574ba6") == true)
        #expect(entries.first { $0.branch == "docs/audit-fixes" }?.isLocked == false)
    }

    /// A bare main worktree has no HEAD and no branch, a detached one has a HEAD and no branch, and
    /// a prunable one is a folder git has noticed has gone. None of the three is invented: this is
    /// the shape `git worktree list --porcelain` is documented to print.
    @Test("bare, detached and prunable records are read for what they are")
    func readsTheAwkwardRecords() {
        let entries = WorktreeListing.parse("""
            worktree /Users/freek/mirrors/bloom.git
            bare

            worktree /Users/freek/looking/at/a/tag
            HEAD 623188465f198b813d32b4520e43b4e8f84aa2ab
            detached

            worktree /Users/freek/gone
            HEAD 623188465f198b813d32b4520e43b4e8f84aa2ab
            branch refs/heads/left-behind
            prunable gitdir file points to non-existent location

            worktree /Users/freek/locked/without/a/reason
            HEAD 623188465f198b813d32b4520e43b4e8f84aa2ab
            branch refs/heads/parked
            locked
            """)
        #expect(entries.count == 4)
        #expect(entries[0].isBare)
        #expect(entries[0].branch == nil)
        #expect(entries[1].isDetached)
        #expect(entries[1].branch == nil)
        #expect(entries[2].isPrunable)
        #expect(entries[2].pruneReason == "gitdir file points to non-existent location")
        #expect(entries[3].lockReason == "")
        #expect(entries[3].isLocked)
    }

    @Test("a path with spaces in it survives, and the last record needs no blank line after it")
    func readsAPathWithSpaces() {
        let entries = WorktreeListing.parse("""
            worktree /Users/freek/My Projects/there there
            HEAD 67bfc360dad6fea4dcecb3964c027b0800bb0801
            branch refs/heads/main
            """)
        #expect(entries.map(\.path) == ["/Users/freek/My Projects/there there"])
    }

    /// Records are flushed on the next `worktree` line as well as on the blank one. Without that,
    /// one missing separator merges two worktrees into a record naming the first path and the
    /// second branch, which is exactly how Bloom would come to name the wrong folder to close.
    @Test("a missing blank line does not merge two worktrees into one")
    func survivesAMissingSeparator() {
        let entries = WorktreeListing.parse("""
            worktree /a
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/one
            worktree /b
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/two
            """)
        #expect(entries.map(\.path) == ["/a", "/b"])
        #expect(entries.map(\.branch) == ["one", "two"])
    }

    /// Against a real repository rather than against a fixture, because a fixture only proves the
    /// parser agrees with whoever pasted it. This one cuts the second worktree that git will
    /// refuse a third of, which is the exact shape of the failure.
    @Test("git's own output, read back out of a repository with a second worktree in it")
    func readsARepositoryOnThisMachine() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let second = TestScratch.unique("held")
        try await Git.addWorktree(repo: repo.path, path: second, branch: "feature", base: "main")
        defer { try? FileManager.default.removeItem(atPath: second) }

        let entries = try await Git.worktrees(of: repo.path)
        #expect(entries.count == 2)
        #expect(entries.contains { $0.branch == "main" })
        #expect(entries.contains { $0.branch == "feature" })

        let holders = BranchHolder.byBranch(worktrees: entries, projectPath: repo.path)
        #expect(holders["feature"]?.isBloomWorkspace == false)
        if case .projectCheckout = holders["main"] {} else {
            Issue.record("the repository's own checkout was read as something else")
        }
        // And git agrees that it is taken, which is the fact the whole feature rests on.
        let refused = await #expect(throws: (any Error).self) {
            try await Git.addWorktree(
                repo: repo.path, path: TestScratch.unique("third"), branch: "feature", base: "main"
            )
        }
        #expect("\(refused!)".contains("already used by worktree"))
    }

    @Test("nothing at all is no worktrees rather than one empty one")
    func readsNothing() {
        #expect(WorktreeListing.parse("").isEmpty)
        #expect(WorktreeListing.parse("\n\n").isEmpty)
        #expect(WorktreeListing.parse("HEAD 1111111111111111111111111111111111111111").isEmpty)
    }
}

/// Who holds a branch, and how that is said.
@Suite("Branch holders")
struct BranchHolderTests {
    private var thereThere: [WorktreeEntry] {
        WorktreeListing.parse(WorktreeListingTests.thereThere)
    }

    /// The whole bug in one assertion. Bloom's database knew about the two workspaces under
    /// `~/bloom/workspaces`, and about nothing else, so the row for pull request #362 looked free
    /// and the create ran until git refused it.
    @Test("a worktree Bloom did not make holds its branch just as firmly")
    func seesAWorktreeFromAnotherApplication() {
        let holders = BranchHolder.byBranch(
            worktrees: thereThere,
            projectPath: "/Users/freek/dev/code/there-there",
            workspaceNames: ["freekmurze/review-changes": "Mawson Sea"]
        )
        #expect(
            holders["freekmurze/figma-mcp-check"]
                == .otherWorktree(path: "/Users/freek/conductor/workspaces/there-there/adelaide")
        )
        #expect(holders["freekmurze/review-changes"] == .workspace("Mawson Sea"))
        // One of Bloom's own that the database has no row for. Git still says it is taken, and it
        // is: the honest answer is the path, because there is no workspace to name.
        #expect(
            holders["freekmurze/review-repo-changes"]
                == .otherWorktree(
                    path: "/Users/freek/bloom/workspaces/there-there/freekmurze-molucca-sea"
                )
        )
        #expect(holders["nothing-has-this"] == nil)
    }

    /// The main checkout is in the listing like any other worktree. Telling somebody Conductor has
    /// his own project's `main` would send him looking for a window that does not exist.
    @Test("the project's own checkout is not another tool holding the branch")
    func tellsTheMainCheckoutApart() {
        let holders = BranchHolder.byBranch(
            worktrees: thereThere, projectPath: "/Users/freek/dev/code/there-there"
        )
        #expect(holders["main"] == .projectCheckout(path: "/Users/freek/dev/code/there-there"))
        #expect(holders["main"]?.note == "Checked out in the project")
    }

    @Test("a trailing slash or a dot in the project's path is still the project's path")
    func comparesPathsRatherThanStrings() {
        for path in [
            "/Users/freek/dev/code/there-there/",
            "/Users/freek/dev/code/./there-there",
            "/Users/freek/dev/code/bloom/../there-there",
        ] {
            let holders = BranchHolder.byBranch(worktrees: thereThere, projectPath: path)
            #expect(holders["main"]?.isBloomWorkspace == false)
            if case .projectCheckout = holders["main"] {} else {
                Issue.record("\(path) was not recognised as the project's own checkout")
            }
        }
    }

    @Test("a bare record and a detached head hold no branch")
    func ignoresWhatHoldsNoBranch() {
        let holders = BranchHolder.byBranch(
            worktrees: [
                WorktreeEntry(path: "/mirror", isBare: true),
                WorktreeEntry(path: "/tag", head: "abc", isDetached: true),
                WorktreeEntry(path: "/real", head: "abc", branch: "feature"),
            ],
            projectPath: "/project"
        )
        #expect(holders.count == 1)
        #expect(holders["feature"] == .otherWorktree(path: "/real"))
    }

    /// Archived workspaces do not count, because their worktrees are gone, and a branch name is
    /// not unique across repositories: an unfiltered list once labelled this project's `develop`
    /// as held by a workspace in another project, and picking that row left the sheet somewhere
    /// else entirely.
    @Test("only this project's live workspaces supply a name")
    func namesOnlyLiveWorkspacesOfThisProject() {
        let mine = RepoID("there-there")
        let theirs = RepoID("bloom")
        var archived = Workspace(
            repoID: mine, name: "Old", branch: "gone", path: "/tmp/a", baseBranch: "main"
        )
        archived.state = .archived
        let names = BranchHolder.names(
            of: [
                archived,
                Workspace(
                    repoID: mine, name: "Mawson Sea", branch: "freekmurze/review-changes",
                    path: "/tmp/b", baseBranch: "main"
                ),
                Workspace(
                    repoID: theirs, name: "Elsewhere", branch: "develop",
                    path: "/tmp/c", baseBranch: "main"
                ),
            ],
            in: mine
        )
        #expect(names == ["freekmurze/review-changes": "Mawson Sea"])
    }

    // MARK: - What the owner is told

    /// The row's note is short and carries no path on purpose: it is one line, right aligned and
    /// truncated from the tail, so "In use by /Users/freek/conduc…" would name nothing. The three
    /// read differently, which is the point, because only one of them is somewhere Bloom can take
    /// you.
    @Test("the row says which kind of holder it is without printing a path")
    func notesReadDifferently() {
        #expect(BranchHolder.workspace("Quiet Harbour").note == "In use by Quiet Harbour")
        #expect(BranchHolder.otherWorktree(path: "/Users/freek/conductor/workspaces/x/adelaide")
            .note == "Checked out elsewhere")
        #expect(!BranchHolder.otherWorktree(path: "/tmp/x").note.contains("/"))
        #expect(BranchHolder.workspace("Quiet Harbour").isBloomWorkspace)
        #expect(!BranchHolder.otherWorktree(path: "/tmp/x").isBloomWorkspace)
        #expect(!BranchHolder.projectCheckout(path: "/tmp/x").isBloomWorkspace)
    }

    /// The sentence the owner reads instead of "failed to run git: exit status 128". It names the
    /// folder to close, and it ends with the thing he can have right now: git is perfectly happy
    /// to cut a new branch from a branch that is checked out somewhere else.
    @Test("the refusal names the holder and offers the way out")
    func refusalNamesTheHolderAndTheOffer() {
        let conductor = BranchHolder.otherWorktree(
            path: "/Users/freek/conductor/workspaces/there-there/adelaide"
        )
        let sentence = conductor.refusal(branch: "freekmurze/figma-mcp-check")
        #expect(sentence.contains("/Users/freek/conductor/workspaces/there-there/adelaide"))
        #expect(sentence.contains("freekmurze/figma-mcp-check"))
        #expect(sentence.contains("Create new branch"))
        #expect(!sentence.contains("128"))
        #expect(!sentence.contains("--force"))

        let ours = BranchHolder.workspace("Quiet Harbour").refusal(branch: "review")
        #expect(ours.contains("'Quiet Harbour'"))
        #expect(!ours.contains("/"))
        #expect(ours.contains("Create new branch"))
    }

    /// `readableMessage` reaches `description` on a value-type error, so even a caller with no
    /// diagnosis of its own says something a person can act on rather than an argv.
    @Test("the thrown error says the same thing on its own")
    func theErrorDescribesItself() {
        let error = BranchInUse(
            branch: "freekmurze/figma-mcp-check",
            holder: .otherWorktree(path: "/Users/freek/conductor/workspaces/there-there/adelaide")
        )
        #expect(error.description == error.holder.refusal(branch: error.branch))
        #expect((error as any Error).readableMessage.contains("adelaide"))
    }

    /// The dialogue the owner actually saw, rewritten. Diagnosed from the error's type rather than
    /// from its words, so no stderr is read and no exit status can arrive by accident.
    @Test("creating turns the thrown refusal into the owner's sentence")
    func troubleDiagnosesTheRefusal() async {
        let trouble = await WorkspaceTrouble.creating(
            BranchInUse(
                branch: "freekmurze/figma-mcp-check",
                holder: .otherWorktree(
                    path: "/Users/freek/conductor/workspaces/there-there/adelaide"
                )
            ),
            project: "there-there",
            // Deliberately a path that is not there. The diagnosis must not depend on probing the
            // project, because the project is fine and has nothing to do with it.
            projectPath: "/Users/freek/nowhere-at-all",
            baseBranch: "main"
        )
        guard case let .createBranchInUse(branch, holder) = trouble else {
            Issue.record("expected createBranchInUse, got \(trouble)")
            return
        }
        #expect(branch == "freekmurze/figma-mcp-check")
        #expect(holder == .otherWorktree(path: "/Users/freek/conductor/workspaces/there-there/adelaide"))
        #expect(trouble.sentence.contains("/Users/freek/conductor/workspaces/there-there/adelaide"))
        #expect(trouble.sentence.contains("Nothing has been created"))
        #expect(trouble.sentence.contains("Create new branch"))
        #expect(!trouble.sentence.lowercased().contains("exit status"))
    }
}
