import BloomCore

/// Archiving a workspace, undoing that, reading what has been archived, and bringing one back.
///
/// One file because it is one promise, made in four places: **nothing is destroyed that exists
/// nowhere else.** `WorkspaceSafetyReport` decides whether that is true, `ArchiveHazards` and
/// `ArchiveRequest` in BloomCore turn the answer into a question worth asking, `offerUndo` puts
/// the archive back on Edit > Undo when it really can be taken back, and `restore` rebuilds the
/// worktree from the branch that kept the commits.
///
/// The optimistic half is the part to read carefully. The row leaves the sidebar before a single
/// byte moves, because the decision has already been taken and the disk work is seconds of a
/// window that otherwise looks broken. `hideFromSidebar`, `stopHidingFromSidebar` and
/// `forgetWorkspace` live in `AppModel.swift`, next to the properties they are the only writer
/// of, and they are what this file reaches for instead of writing those lists itself.

extension AppModel {


    /// Every archived workspace with what it still holds, and whether its branch is still here.
    ///
    /// The branch question is asked once per project rather than once per workspace: `branchExists`
    /// is a `git show-ref` per call, and a list of forty archived workspaces across three projects
    /// would be forty processes to answer a question three `for-each-ref` calls answer completely.
    ///
    /// Only the local half of the question is asked. `RestoreSource` is the full answer and needs a
    /// fetch per workspace, which is a network round trip a list cannot afford; a branch that is
    /// not here may still be on a remote, and `ArchiveDeletion.branchStanding` is careful to say
    /// that rather than claim the work is gone.
    func archiveCleanup() async -> ArchiveCleanup {
        guard let store, var footprints = try? await store.archivedFootprints() else {
            return ArchiveCleanup(footprints: [])
        }

        var localBranches: [RepoID: Set<String>] = [:]
        for repo in repos where footprints.contains(where: { $0.workspace.repoID == repo.id }) {
            guard let branches = try? await Git.branches(of: repo.path) else { continue }
            localBranches[repo.id] = Set(branches)
        }
        for index in footprints.indices {
            let workspace = footprints[index].workspace
            footprints[index].branchIsLocal = localBranches[workspace.repoID]?.contains(workspace.branch)
        }
        return ArchiveCleanup(footprints: footprints)
    }

    func databaseSize() async -> DatabaseSize? {
        guard let store else { return nil }
        return try? await store.databaseSize()
    }

    /// Destroys the records for archived workspaces, and forgets everything the window was holding
    /// about them.
    ///
    /// The selection is moved first. A window sitting on `.archived(id)` whose row has just been
    /// deleted would fall through `DetailColumn` to Home, which is the right answer to an
    /// impossible state and the wrong thing to do to somebody who is halfway through tidying up.
    /// The outcome rather than a count, because a refused write and an empty selection used to be
    /// the same `0` and the caller could not tell them apart to say so.
    @discardableResult
    func deleteArchived(_ ids: [WorkspaceID]) async -> ArchiveDeletionOutcome {
        guard let store, !ids.isEmpty else { return .deleted(0) }
        let removed: Int
        do {
            removed = try await store.deleteArchivedWorkspaces(ids: ids)
        } catch {
            return .refused(complaint: WorkspaceTrouble.complaint(about: error))
        }
        guard removed > 0 else { return .deleted(0) }

        if let open = selection.archivedWorkspaceID, ids.contains(open) {
            selection = .archive
        }
        // Torn down rather than only dropped. Everything here was archived, and archiving stops
        // its agents, so in practice there is nothing left to stop; a model let go of while it
        // still holds a runner is a writer aimed at rows that have just been deleted, and that is
        // the shape of failure this whole path was fixed for.
        for id in ids {
            workspaceModels[id]?.teardown()
            workspaceModels[id] = nil
        }
        invalidateArchived()
        return .deleted(removed)
    }

    /// Rewrites the database so the pages a delete freed go back to the filesystem. Slow on a
    /// large file and deliberately never automatic. See `Store.compactDatabase`.
    func compactDatabase() async {
        guard let store else { return }
        try? await store.compactDatabase()
    }

    /// Archives when there is nothing to lose, and asks first when there is.
    ///
    /// Nothing is torn down before the decision: a refused archive used to take the workspace's
    /// shells and dev servers with it anyway, which is a strange thing to happen after being told
    /// the workspace was too valuable to remove.
    ///
    /// Whether an entry point asks even when there is nothing to lose is that entry point's own
    /// business, and `alwaysConfirm` is how it says so. Exactly one caller passes it: the sidebar
    /// row's hover archive button, which appears under the pointer unbidden and is the easiest
    /// way in the app to archive something by accident. The context menu, the Workspace menu, the
    /// keyboard shortcut and the merged pull request strip all leave it alone, because opening a
    /// menu or pressing a shortcut is already saying what you mean, and a confirmation with
    /// nothing to warn about is how a confirmation stops being read.
    ///
    /// It is a flag here rather than a second dialog at the call site, and that is deliberate.
    /// The row used to raise a compact "are you sure" of its own, so a workspace with real work
    /// in it produced two dialogs of different shapes for one decision: a small one that warned
    /// about nothing, then a large one listing what was at stake. One question, asked once, in
    /// one shape.
    ///
    /// A merged pull request needs no new logic and gets none. It already clears the commits
    /// through `isPullRequestMerged`, so what is left to stop an archive is an agent mid turn and
    /// work that exists nowhere but that directory. Neither is weakened for it.
    func archive(
        _ workspace: Workspace, deleteBranch: Bool? = nil, alwaysConfirm: Bool = false
    ) async {
        guard let manager, let repo = repo(for: workspace) else {
            Log.archive.error(
                "asked to archive \(workspace.name, privacy: .public), but the app has no manager or no project for it"
            )
            return
        }

        let hazards = ArchiveHazards(
            isAgentRunning: isRunning(workspace),
            isPullRequestMerged: isPullRequestMerged(workspace),
            // Resolved here rather than left as nil, because the confirmation has to say whether
            // the commits are at stake, and only the repository's settings know that when the
            // caller did not say.
            isDeletingBranch: deleteBranch ?? SettingsLoader.load(repo: repo.path).deleteBranchOnArchive
        )

        let report: WorkspaceSafetyReport
        do {
            report = try await manager.safetyReport(workspace: workspace, repo: repo)
        } catch {
            // Git could not answer, and not knowing what is at stake is not a licence to delete it.
            // The user still gets the choice, with the reason the check failed in front of them.
            //
            // Diagnosed rather than reported, and this is the worst of the four places that used
            // not to be: it is read while somebody is deciding whether to destroy a worktree, and
            // `error.readableMessage` on a `ShellError` put a git command line and an exit status
            // there. See `WorkspaceTrouble.archiving`.
            let trouble = await WorkspaceTrouble.archiving(
                error,
                workspace: workspace.name,
                path: workspace.path,
                baseBranch: workspace.baseBranch
            )
            pendingArchive = ArchiveRequest(
                workspace: workspace,
                report: WorkspaceSafetyReport(),
                deleteBranch: deleteBranch,
                problem: "Bloom could not check this workspace for unsaved work. \(trouble.sentence)",
                hazards: hazards
            )
            return
        }

        let isSafe = report.isSafeToDiscard(
            deletingBranch: hazards.isDeletingBranch,
            isPullRequestMerged: hazards.isPullRequestMerged
        )

        guard isSafe, !hazards.isAgentRunning, !alwaysConfirm else {
            pendingArchive = ArchiveRequest(
                workspace: workspace, report: report, deleteBranch: deleteBranch, hazards: hazards
            )
            return
        }

        await performArchive(
            workspace,
            repo: repo,
            deleteBranch: deleteBranch,
            force: false,
            report: report,
            hazards: hazards
        )
    }

    /// GitHub's verdict on this workspace's branch, from whichever of the two places has already
    /// asked: the open workspace's own model, or the store every sidebar row reads.
    ///
    /// Never asks itself. A merged pull request only ever makes this check more permissive, so a
    /// missing answer costs a confirmation rather than a workspace, and an archive that waited on
    /// the network before it could decide would be worse than the confirmation it saved.
    private func isPullRequestMerged(_ workspace: Workspace) -> Bool {
        let pullRequest = workspaceModels[workspace.id]?.pullRequest
            ?? WorkspacePullRequests.shared.pullRequest(for: workspace.id)
        return pullRequest?.isMerged ?? false
    }

    /// The user has seen exactly what would be destroyed and asked for it anyway.
    ///
    /// Takes the request as an argument, and that is the whole of the fix for an archive that did
    /// nothing at all. This used to read `pendingArchive` back out of the model, and by the time
    /// it ran there was nothing there to read: the confirmation's own dismissal writes `false`
    /// into the `isPresented` binding, `Binding.isPresent()` turns that into `pendingArchive =
    /// nil`, and the button's action is a `Task` that reaches the main actor about 270ms later,
    /// after the dismissal. The guard then failed and the method returned, silently, every single
    /// time. Pressing "Archive and lose that work" genuinely did nothing.
    ///
    /// So nothing here may depend on state a dismissal can clear. The value the dialog was built
    /// from is the value it acts on.
    func confirmArchive(_ request: ArchiveRequest) async {
        pendingArchive = nil
        guard let repo = repo(for: request.workspace) else {
            Log.archive.error(
                "confirmed the archive of \(request.workspace.name, privacy: .public), but its project is gone"
            )
            return
        }
        // A request that carries a problem has no report at all, only the reason git could not be
        // asked. Passing it on would let an empty report be read as "nothing was at stake".
        await performArchive(
            request.workspace,
            repo: repo,
            deleteBranch: request.deleteBranch,
            force: true,
            report: request.problem == nil ? request.report : nil,
            hazards: request.hazards
        )
    }

    func cancelPendingArchive() {
        pendingArchive = nil
    }

    private func performArchive(
        _ workspace: Workspace,
        repo: Repo,
        deleteBranch: Bool?,
        force: Bool,
        report: WorkspaceSafetyReport?,
        hazards: ArchiveHazards
    ) async {
        guard let manager else {
            Log.archive.error(
                "archiving \(workspace.name, privacy: .public) stopped before it began: no workspace manager"
            )
            return
        }

        // The agents go first: they are the ones writing to the worktree that is about to be
        // removed, and `git worktree remove --force` unlinking files under a running agent is how
        // work gets corrupted rather than merely lost. The shells and dev servers only go once the
        // removal has actually happened, so a failing archive script does not cost the user their
        // terminals for nothing.
        //
        // This does mean an archive that the manager then refuses has already stopped the agent.
        // That trade is deliberate and it is the reason the archive script's failure message says
        // so rather than claiming the workspace is untouched. Moving the teardown after the
        // script would mean the script running while an agent still writes, which is worse.
        workspaceModels[workspace.id]?.teardown()

        // Out of the sidebar now, before a single byte moves.
        //
        // Archiving used to show nothing at all until every last thing had finished: a safety
        // report over the whole worktree, an archive script, `git worktree remove` deleting a
        // `node_modules` file by file, a branch delete, and a reload. On a real project that is
        // seconds of a window that looks broken, and the report above is the reason people press
        // the button twice.
        //
        // None of that work decides anything the user has not already decided. The decision was
        // made before this method was called, so the row can go at once and the disk can catch
        // up. If the disk refuses, the `catch` below reloads from the store, where the row is
        // still active, and it comes back with the reason in front of it.
        let previousSelection = selection
        hideFromSidebar(workspace.id)
        if selection.workspaceID == workspace.id { selection = .home }

        do {
            try await manager.archive(
                workspace: workspace,
                repo: repo,
                deleteBranch: deleteBranch,
                force: force,
                isPullRequestMerged: hazards.isPullRequestMerged
            )
            // The worktree is gone from disk now. Its shells are sitting in a directory that no
            // longer exists and its dev servers are still holding their ports, and nothing else in
            // the app will ever come back for them.
            await TerminalSessionStore.shared.discard(workspaceID: workspace.id)
            // Everything at once, and after the discard rather than before it. The store agrees
            // the workspace is archived by now, so the reload filter has nothing left to protect,
            // and holding it across one more await can only keep a row from flickering back.
            forgetWorkspace(workspace.id)
            // One more workspace is archived now, so anything holding the old answer is wrong.
            invalidateArchived()
            await offerUndo(of: workspace, repo: repo, report: report)
            Log.archive.info("archived \(workspace.name, privacy: .public)")
        } catch let error as WorkspaceError {
            await undoOptimisticArchive(workspace, restoring: previousSelection)
            switch error {
            case .archiveScriptFailed(let status, let output):
                Log.archive.error(
                    "the archive script for \(workspace.name, privacy: .public) exited \(status), so nothing was removed"
                )
                // Worth its own wording: the manager stops before removing anything, so the user
                // needs to hear that the worktree is still there rather than fear the worst. It
                // does not claim the workspace is untouched, because the agent went first: see
                // the teardown above.
                //
                // Titled without the workspace name. Names here are whole sentences, and a title
                // built from one wraps to three lines of bold text that reads as the warning
                // itself. The name goes in the message, which has room for it.
                alert = BloomAlert(
                    title: "The archive script failed",
                    message: "\u{201C}\(workspace.name)\u{201D} is still here: its worktree and "
                        + "its branch are untouched. Any agent it was running has been stopped.\n\n"
                        + "The script exited with status \(status).\n\n"
                        // The tail is where a script says why it gave up.
                        + String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1_000))
                )
            case .unsafeToArchive(let fresh):
                Log.archive.notice(
                    "\(workspace.name, privacy: .public) changed between the check and the archive, so it is being asked about again"
                )
                // Only reachable when the worktree changed between the check and the archive.
                pendingArchive = ArchiveRequest(
                    workspace: workspace, report: fresh, deleteBranch: deleteBranch, hazards: hazards
                )
            default:
                Log.archive.error(
                    "could not archive \(workspace.name, privacy: .public): \(error.readableMessage, privacy: .public)"
                )
                await reportArchiveFailure(error, workspace: workspace)
            }
        } catch {
            await undoOptimisticArchive(workspace, restoring: previousSelection)
            Log.archive.error(
                "could not archive \(workspace.name, privacy: .public): \(error.readableMessage, privacy: .public)"
            )
            await reportArchiveFailure(error, workspace: workspace)
        }
    }

    /// Diagnosed rather than reported, for both of the archive's catches.
    ///
    /// `error.readableMessage` used to be the message here, so a `ShellError` put "`git worktree
    /// remove ...` exited 128" in a modal and a refused row put "[UPDATE workspaces SET ...
    /// VALUES (?, ?, ?)]" in one. Neither said what to do. `WorkspaceTrouble.archiving` asks the
    /// worktree instead.
    private func reportArchiveFailure(_ error: any Error, workspace: Workspace) async {
        let trouble = await WorkspaceTrouble.archiving(
            error,
            workspace: workspace.name,
            path: workspace.path,
            baseBranch: workspace.baseBranch
        )
        alert = BloomAlert(title: "Could not archive the workspace", message: trouble.sentence)
    }

    /// Puts a workspace back in the sidebar after the disk refused to let it go.
    ///
    /// Reloaded from the store rather than reinstated from a copy held in memory. `Workspace.state`
    /// is only written once the removal has actually happened, so a failed archive leaves the row
    /// exactly as it was, and reading it back is the one version that cannot disagree with what
    /// every other part of the app is about to read.
    private func undoOptimisticArchive(_ workspace: Workspace, restoring selection: SidebarSelection) async {
        stopHidingFromSidebar(workspace.id)
        await reload()
        self.selection = selection
    }

    /// Offers Edit > Undo for an archive that really can be taken back.
    ///
    /// The test is not "was this archive safe". `WorkspaceSafetyReport.isSafeToDiscard` also weighs
    /// the commits, because deleting the branch would strand them, and an archive that keeps the
    /// branch strands nothing: the branch holds the commits and the worktree is a checkout of it.
    /// What decides is `isRestorableFromBranch`, which asks only whether anything lived in that
    /// directory and nowhere else. The other two guards are about the same promise:
    ///
    /// - The branch is checked on disk rather than inferred from `deleteBranch`, which can also be
    ///   decided by the repository's settings file. A deleted branch takes the commits with it.
    /// - An archive script has already wound the workspace down, and Bloom has no idea what it
    ///   did. Rebuilding the checkout would hand back a workspace whose containers, databases and
    ///   ports are gone, which is not the workspace that was archived.
    ///
    /// A missing report means git could not be asked what was at stake, which is never a reason to
    /// claim there was nothing.
    private func offerUndo(
        of workspace: Workspace, repo: Repo, report: WorkspaceSafetyReport?
    ) async {
        guard let manager, undoManager != nil else { return }
        guard let report, report.isRestorableFromBranch else { return }
        guard SettingsLoader.load(repo: repo.path).archiveScript == nil else { return }
        guard await manager.canRestore(workspace: workspace, repo: repo) else { return }
        registerArchiveUndo(workspace, repo: repo)
    }

    private func registerArchiveUndo(_ workspace: Workspace, repo: Repo) {
        guard let undoManager else { return }
        // The handler runs on the main thread, from the Edit menu or Command+Z, so the isolation
        // is real rather than assumed away.
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.beginRestore(of: workspace, repo: repo) }
        }
        // Named for the action being reversed, which is what every other Mac app puts after
        // "Undo". SwiftUI's stock Edit menu draws a fixed "Undo" title and only takes the enabled
        // state from the manager, so this currently shows up in `undoActionName` rather than in
        // the menu. Spelling it out anyway is what makes the menu title correct the moment that
        // group is replaced.
        undoManager.setActionName("Archive Workspace")
    }

    private func beginRestore(of workspace: Workspace, repo: Repo) {
        Task { await restore(workspace) }
    }

    /// Opens an archived workspace for reading.
    ///
    /// Reading and resuming are two different things and this is the first of them. Everything an
    /// archived workspace ever said is still in the database: the transcript, the sessions, what
    /// each turn cost. Only the worktree is gone. Before this there was no way to reach any of it
    /// once the undo had expired, so a workspace archived yesterday took its whole history out of
    /// the app while its branch sat on disk.
    ///
    /// The model is prepared here rather than in the selection setter, because an archived
    /// workspace is not in `workspaces` and the setter has nowhere to look it up.
    func openArchived(_ workspace: Workspace) {
        model(for: workspace)
        selection = .archived(workspace.id)
    }

    /// Opens whatever a workspace id points at, live or archived.
    ///
    /// The one entry point for "show me this workspace" from outside the window: the menu bar
    /// item, the Services item, a deep link and the capture harness all arrive here through
    /// `OpenWorkspaceNotification`. It used to set `.workspace(id)` whatever the id was, and an
    /// id that had since been archived resolved to no workspace at all, so the window quietly fell
    /// back to Home. Now an archived id opens the reader instead of nothing.
    func open(workspaceID id: WorkspaceID) async {
        if workspaces.contains(where: { $0.id == id }) {
            selection = .workspace(id)
            return
        }
        guard let archived = await archivedWorkspaces().first(where: { $0.id == id }) else { return }
        openArchived(archived)
    }

    /// Where this workspace's branch still is. See `RestoreSource`.
    ///
    /// Asks the network, so it is called once by the screen that offers Restore rather than per
    /// redraw, and never from a body.
    func restoreSource(for workspace: Workspace) async -> RestoreSource? {
        guard let manager, let repo = repo(for: workspace) else { return nil }
        return await manager.restoreSource(workspace: workspace, repo: repo)
    }

    /// Rebuilds the worktree and puts the workspace back in the sidebar.
    ///
    /// This is the second of the two things Restore could mean, and the one that can fail: a
    /// branch that is gone from this Mac and from the remote leaves nothing to build from. The
    /// refusal says so and the workspace stays where it is, still readable.
    ///
    /// No redo is registered when this arrives from Edit > Undo. Redo of an archive would delete
    /// a worktree from a menu item, with no safety report in front of it, which is the one thing
    /// this app is careful never to do.
    func restore(_ workspace: Workspace) async {
        guard let manager else { return }
        guard let repo = repo(for: workspace) else {
            alert = BloomAlert(
                title: "Could not bring \(workspace.name) back",
                message: "Its project is no longer in Bloom, so there is no repository to cut a "
                    + "worktree from. Add the project again and try once more."
            )
            return
        }
        guard !restoring.contains(workspace.id) else { return }

        restoring.insert(workspace.id)
        defer { restoring.remove(workspace.id) }

        do {
            let outcome = try await manager.restore(workspace: workspace, repo: repo)
            // The other half of the pair: this workspace has left the archived list.
            invalidateArchived()
            await reload()
            selection = .workspace(outcome.workspace.id)
            Log.archive.info("restored \(workspace.name, privacy: .public)")

            if let from = outcome.relocatedFrom {
                // The one notice that waits. Everything else here is news about something
                // that is now settled; this is a path the user has to go and look at, and it is
                // the only sentence anywhere that says where their worktree actually is.
                notice = BloomNotice(
                    message: "\(outcome.workspace.name) came back to a different place. "
                        + "Something else is at `\(from)`, so the worktree was rebuilt at "
                        + "`\(outcome.workspace.path)`.",
                    dismissal: .untilDismissed
                )
            }
        } catch {
            Log.archive.error(
                "could not restore \(workspace.name, privacy: .public): \(error.readableMessage, privacy: .public)"
            )
            // Diagnosed rather than reported. A store error reaching here rendered its own SQL,
            // "message [UPDATE workspaces SET ... VALUES (?, ?, ?)]", and the likeliest git
            // failure, the branch being checked out in another worktree, arrived as an argv and
            // an exit status. See `WorkspaceTrouble.restoring`.
            let trouble = await WorkspaceTrouble.restoring(
                error,
                workspace: workspace.name,
                branch: workspace.branch,
                project: repo.name,
                projectPath: repo.path
            )
            alert = BloomAlert(
                title: "Could not bring \(workspace.name) back",
                message: trouble.sentence
            )
        }
    }
}
