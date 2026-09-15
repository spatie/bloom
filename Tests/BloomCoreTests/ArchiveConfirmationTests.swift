import Testing
import Foundation
@testable import BloomCore

/// How loudly the archive confirmation speaks, and what it says.
///
/// This exists because of one report. The owner merged a pull request, pressed Archive, and was
/// offered a red "Archive and lose that work" over thirteen ignored paths: a `.env`, generated
/// route and type files, a folder of attachments. None of that was ever in a commit, none of it
/// was meant to be, and the branch's code was already on the default branch. Spending the app's
/// strongest words there is how people learn to click through them, on the one action in Bloom
/// that cannot be undone.
///
/// So each test below is a sentence somebody reads before destroying a worktree, and the two that
/// matter most are the quiet one and the unknown one: the strong wording has to stop being spent
/// on a `.env`, and it has to keep being spent when git could not be asked at all.
@Suite("Archive confirmation")
struct ArchiveConfirmationTests {
    private func makeWorkspace(name: String = "Fix the login redirect") -> Workspace {
        Workspace(
            repoID: .new(),
            name: name,
            branch: "bloom/fix-the-login-redirect",
            path: "/tmp/bloom/fix-the-login-redirect",
            baseBranch: "main"
        )
    }

    /// The thirteen paths from the report that started this, in git's own order and shape.
    private let ownersIgnoredPaths = [
        ".env",
        "resources/js/actions/",
        "resources/js/routes/",
        "resources/js/types/",
        "storage/app/attachments/",
        "storage/app/private/",
        "storage/app/public/",
        "storage/framework/cache/",
        "storage/framework/sessions/",
        "storage/framework/testing/",
        "storage/framework/views/",
        "storage/logs/",
        "public/hot",
    ]

    @Test("an unrecognized folder confirmation explains what is kept")
    func unrecognizedFolderIsKept() {
        let workspace = makeWorkspace()
        var report = WorkspaceSafetyReport()
        report.preservedFolderPath = workspace.path
        let request = ArchiveRequest(
            workspace: workspace, report: report,
            hazards: ArchiveHazards(isDeletingBranch: true)
        )

        #expect(request.confirmLabel == "Archive")
        #expect(request.losses.isEmpty)
        #expect(request.message.contains("The folder at \(workspace.path) and the branch are kept."))
        #expect(request.message.contains("The archive script is skipped."))
        #expect(!request.message.contains("is deleted"))
    }

    @Test("nothing at stake and a merged pull request reads as routine")
    func cleanAndMergedIsRoutine() {
        let request = ArchiveRequest(
            workspace: makeWorkspace(),
            report: WorkspaceSafetyReport(),
            hazards: ArchiveHazards(isPullRequestMerged: true)
        )

        #expect(request.severity == .routine)
        #expect(request.isDestructive == false)
        #expect(request.confirmLabel == "Archive")
        #expect(request.message == """
        \u{201C}Fix the login redirect\u{201D}

        The worktree is deleted and the branch is kept. The workspace moves to Archived. Its pull \
        request is merged, so the branch\u{2019}s work is already on the default branch.
        """)
    }

    @Test("ignored files that differ are mentioned, never called a loss")
    func ignoredFilesAreMentionedNotWarnedAbout() {
        // The owner's case, whole. A plain button, no red, and the word "lose" nowhere on screen.
        let request = ArchiveRequest(
            workspace: makeWorkspace(),
            report: WorkspaceSafetyReport(modifiedIgnoredFiles: ownersIgnoredPaths),
            hazards: ArchiveHazards(isPullRequestMerged: true)
        )

        #expect(request.severity == .worthMentioning)
        #expect(request.isDestructive == false)
        #expect(request.confirmLabel == "Archive")
        #expect(request.losses.isEmpty)
        #expect(request.message.contains("lose") == false)
        #expect(request.message == """
        \u{201C}Fix the login redirect\u{201D}

        The worktree is deleted and the branch is kept. The workspace moves to Archived. Its pull \
        request is merged, so the branch\u{2019}s work is already on the default branch.

        Also in the worktree, ignored by git and so in no commit by design:
        \u{2022} 13 ignored files and folders that differ from the main checkout: .env, \
        resources/js/actions/, resources/js/routes/, resources/js/types/, \
        storage/app/attachments/, and 8 more
        """)
    }

    @Test("uncommitted changes to tracked files keep the strong wording")
    func uncommittedChangesStayStrong() {
        // A merged pull request says something about the commits. It says nothing about the files
        // sitting in the directory that is about to be deleted, so it must not soften this.
        let request = ArchiveRequest(
            workspace: makeWorkspace(),
            report: WorkspaceSafetyReport(hasUncommittedChanges: true),
            hazards: ArchiveHazards(isPullRequestMerged: true)
        )

        #expect(request.severity == .destructive)
        #expect(request.confirmLabel == "Archive and lose that work")
        #expect(request.message == """
        \u{201C}Fix the login redirect\u{201D}

        The worktree is deleted and the branch is kept. The workspace moves to Archived.

        This would lose:
        \u{2022} uncommitted changes to tracked files
        """)
    }

    @Test("a commit on a detached HEAD keeps the strong wording")
    func detachedCommitsStayStrong() {
        let request = ArchiveRequest(
            workspace: makeWorkspace(),
            report: WorkspaceSafetyReport(detachedCommits: 1),
            hazards: ArchiveHazards(isPullRequestMerged: true)
        )

        #expect(request.severity == .destructive)
        #expect(request.confirmLabel == "Archive and lose that work")
        #expect(request.message == """
        \u{201C}Fix the login redirect\u{201D}

        The worktree is deleted and the branch is kept. The workspace moves to Archived.

        This would lose:
        \u{2022} 1 commit made on a detached HEAD, held by no branch
        """)
    }

    @Test("a report git could not fill in is unknown, never nothing at stake")
    func anUnansweredCheckStaysStrong() {
        // The load-bearing one. `AppModel` builds this request with an empty report because
        // `Git.safetyReport` threw, and an empty report is all zeroes and empty arrays, which is
        // byte for byte what a spotless worktree produces. If the severity read the report alone,
        // the dialogue would say "nothing at stake" about a workspace nobody has checked.
        let request = ArchiveRequest(
            workspace: makeWorkspace(),
            report: WorkspaceSafetyReport(),
            problem: "Bloom could not check this workspace for unsaved work. The worktree for "
                + "\u{201C}Fix the login redirect\u{201D} is no longer on disk.",
            hazards: ArchiveHazards(isPullRequestMerged: true)
        )

        #expect(request.severity == .destructive)
        #expect(request.isDestructive)
        #expect(request.confirmLabel == "Archive and lose that work")
        #expect(request.message == """
        \u{201C}Fix the login redirect\u{201D}

        The worktree is deleted and the branch is kept. The workspace moves to Archived.

        Bloom could not check this workspace for unsaved work. The worktree for \
        \u{201C}Fix the login redirect\u{201D} is no longer on disk.
        """)
    }

    // MARK: - The rest of the rules the five cases lean on

    @Test("an agent mid turn is the first loss listed, because git cannot see it")
    func aRunningAgentLeadsTheList() {
        let request = ArchiveRequest(
            workspace: makeWorkspace(),
            report: WorkspaceSafetyReport(hasUncommittedChanges: true),
            hazards: ArchiveHazards(isAgentRunning: true)
        )

        #expect(request.severity == .destructive)
        #expect(request.losses.first?.contains("an agent is running") == true)
    }

    @Test("a merged pull request never quietens a real loss")
    func mergedNeverSoftensARealLoss() {
        for report in [
            WorkspaceSafetyReport(hasUncommittedChanges: true),
            WorkspaceSafetyReport(untrackedFiles: ["plan.md"]),
            WorkspaceSafetyReport(detachedCommits: 2),
        ] {
            let request = ArchiveRequest(
                workspace: makeWorkspace(),
                report: report,
                hazards: ArchiveHazards(isPullRequestMerged: true, isDeletingBranch: true)
            )
            #expect(request.severity == .destructive)
            #expect(request.message.contains("already on the default branch") == false)
        }
    }

    @Test("the branch's fate is stated either way")
    func theBranchIsAlwaysAccountedFor() {
        let kept = ArchiveRequest(workspace: makeWorkspace(), report: WorkspaceSafetyReport())
        #expect(kept.message.contains("the branch is kept."))

        let deleted = ArchiveRequest(
            workspace: makeWorkspace(),
            report: WorkspaceSafetyReport(),
            hazards: ArchiveHazards(isDeletingBranch: true)
        )
        #expect(deleted.message.contains("the branch is deleted too."))
    }

    @Test("ignored files are still listed beside a real loss, under their own calmer heading")
    func ignoredFilesKeepTheirOwnHeadingBesideALoss() {
        let request = ArchiveRequest(
            workspace: makeWorkspace(),
            report: WorkspaceSafetyReport(
                hasUncommittedChanges: true, modifiedIgnoredFiles: [".env"]
            )
        )

        #expect(request.confirmLabel == "Archive and lose that work")
        #expect(request.losses == ["uncommitted changes to tracked files"])
        #expect(request.notes == ["1 ignored file that differs from the main checkout: .env"])
        #expect(request.message.contains("This would lose:\n\u{2022} uncommitted changes"))
        #expect(request.message.contains("Also in the worktree, ignored by git"))
    }

    // MARK: - Docker

    private let footprint = ArchiveDockerFootprint(resources: [
        .init(kind: .container, name: "tt-postgres-1", isRunning: true),
        .init(kind: .container, name: "tt-redis-1"),
        .init(kind: .volume, name: "tt_database"),
        .init(kind: .network, name: "tt_default"),
    ])

    @Test("a workspace with its own containers is asked about, with removal on by default")
    func dockerIsOfferedAndOnByDefault() {
        let request = ArchiveRequest(workspace: makeWorkspace(), report: WorkspaceSafetyReport(), docker: footprint)
        #expect(request.offersDockerRemoval)
        #expect(request.removesDockerResources)
        // Asked, so the archive stops for the choice, but not in the red voice kept for lost work.
        #expect(request.severity == .worthMentioning)
        #expect(request.confirmLabel == "Archive")
        #expect(request.message.contains("In Docker it has 2 containers and 1 volume. They are removed after the archive script runs."))
    }

    @Test("turning removal off says the containers are kept and asks the archive for nothing")
    func dockerCanBeKept() {
        var request = ArchiveRequest(workspace: makeWorkspace(), report: WorkspaceSafetyReport(), docker: footprint)
        request.removesDocker = false
        #expect(!request.removesDockerResources)
        #expect(request.message.contains("They are kept."))
    }

    @Test("no footprint, or only a network, leaves a clean archive routine")
    func noDockerStaysRoutine() {
        let plain = ArchiveRequest(workspace: makeWorkspace(), report: WorkspaceSafetyReport())
        #expect(plain.severity == .routine)
        #expect(!plain.message.contains("Docker"))
        let network = ArchiveRequest(workspace: makeWorkspace(), report: WorkspaceSafetyReport(),
            docker: ArchiveDockerFootprint(resources: [.init(kind: .network, name: "tt_default")]))
        #expect(!network.offersDockerRemoval)
        #expect(network.severity == .routine)
    }

    @Test("a folder git no longer recognises keeps its containers along with everything else")
    func preservedFolderNeverOffersDocker() {
        var report = WorkspaceSafetyReport()
        report.preservedFolderPath = "/tmp/bloom/kept"
        let request = ArchiveRequest(workspace: makeWorkspace(), report: report, docker: footprint)
        #expect(!request.offersDockerRemoval)
        #expect(!request.removesDockerResources)
        #expect(!request.message.contains("Docker"))
    }

    @Test("the whole list is still one voice for the error that refuses an archive")
    func theErrorPathStillSeesEverything() {
        // `WorkspaceError.unsafeToArchive` reports every reason the archive was refused, so
        // splitting the confirmation's two halves must not have narrowed what it can say.
        let report = WorkspaceSafetyReport(
            hasUncommittedChanges: true, modifiedIgnoredFiles: [".env"], detachedCommits: 1
        )
        #expect(report.losses(deletingBranch: true).count == 3)
        #expect(
            report.losses(deletingBranch: true)
                == report.irreversibleLosses(deletingBranch: true) + report.ignoredFileNotes
        )
    }
}
