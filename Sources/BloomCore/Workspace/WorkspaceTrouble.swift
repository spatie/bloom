import Foundation

/// Why something Bloom did for a workspace failed, said to the owner rather than to an agent.
///
/// Mostly that is a recorded directory: a project folder or a worktree that has stopped being
/// what the database says it is. One case is the database itself refusing a write, and it is
/// here rather than in a vocabulary of its own because it is the same kind of sentence about the
/// same workspace, and because a second set of words for "this went wrong and here is what to do
/// about it" is how the two drift apart.
///
/// The companion of `WorkspaceStartTrouble`, which says the same diagnoses to a model calling
/// `workspace_start`. Two enums rather than one because the two readers can do different things
/// about it: an agent is told to stop guessing and carry on with its own work, and the owner is
/// told which folder to put back. What they share is the method and the probes, which are
/// `CheckoutStanding`: neither of them reads git's stderr to decide what happened.
///
/// This exists because both surfaces used to show `error.readableMessage`, and for a `ShellError`
/// that is the command line, its exit status and its stderr. Creating a workspace in a project
/// whose folder had stopped being a checkout put up "`git for-each-ref --format=%(refname:short)
/// refs/heads` exited 128: fatal: not a git repository (or any of the parent directories): .git",
/// and the diff pane said the same thing about `git rev-parse --verify main^{commit}` for a
/// workspace whose worktree had been deleted underneath it. Neither says which project or which
/// workspace, neither says what to do, and both hand the reader a command they never ran.
///
/// Every sentence names the thing that is wrong, says what is true about it, and ends with the one
/// action that helps. None of them quotes a command. A project's path is named, because that is the
/// owner's own folder and the whole remedy is about it; a Bloom worktree's path is not, because it
/// is a directory inside Bloom's workspaces root that the owner did not choose and cannot usefully
/// act on. The workspace's name is named instead. A worktree that is **not** one of Bloom's is the
/// exception on both counts: it is somebody else's application's folder, the app has no name for
/// it, and its path is the only thing that says which window to go and close. See `BranchHolder`.
public enum WorkspaceTrouble: Sendable, Equatable {
    /// The project's folder is not there at all.
    case projectGone(project: String, path: String)
    /// The project's folder is there, and git does not know it any more.
    case projectNotACheckout(project: String, path: String)
    /// The project is a repository that has never been committed to.
    case projectHasNoCommits(project: String)
    /// The branch the worktree would have been cut from is not in the project.
    case baseBranchGone(branch: String, project: String)
    /// Creating cannot go on because something already has the branch checked out. See
    /// `BranchHolder`: that something is not always one of Bloom's own workspaces, and the two
    /// read differently because only one of them is somewhere Bloom can take you.
    case createBranchInUse(branch: String, holder: BranchHolder)
    /// The workspace's worktree folder is not there at all.
    case worktreeGone(workspace: String)
    /// The workspace's worktree folder is there, and git does not know it any more.
    case worktreeNotACheckout(workspace: String)
    /// The branch this workspace is measured against is not in the project any more.
    case worktreeBaseBranchGone(branch: String, workspace: String)
    /// Archiving cannot go on because the worktree it would remove is not there.
    case archiveWorktreeGone(workspace: String)
    /// Archiving cannot go on because the folder is there and git does not own it any more.
    ///
    /// The one case that names a worktree's path, against the rule above, because it is the one
    /// case whose remedy is the owner opening that folder: git will not release a worktree it
    /// does not recognise, so nothing in Bloom can finish this until the directory is gone.
    case archiveWorktreeNotACheckout(workspace: String, path: String)
    /// Archiving stopped because the worktree holds work that is in no commit.
    case archiveWorktreeNotEmpty(workspace: String)
    /// Archiving stopped for a reason nothing about the worktree explains.
    case archiveUnexplained(workspace: String, complaint: String)
    /// Restoring cannot go on because another worktree already has the branch checked out.
    case restoreBranchInUse(branch: String, workspace: String, worktree: String)
    /// Restoring cannot go on because the branch is on neither this Mac nor a remote.
    case restoreBranchGone(branch: String, workspace: String)
    /// Restoring stopped for a reason nothing about the project explains.
    case restoreUnexplained(workspace: String, complaint: String)
    /// Continuing after a merge stopped for a reason nothing about the worktree explains.
    case continueUnexplained(workspace: String, complaint: String)
    /// The disk work is done and the database would not record it, so every list in the app is
    /// showing where this workspace was rather than where it is. The sibling of
    /// `transcriptUnwritable`, which is the same refusal about a conversation.
    case recordUnwritable(workspace: String, complaint: String)
    /// Bloom could not write a turn into its own database, and the transcript it would have
    /// gone into is still there. See `recording(transcript:complaint:)` for the refusal that
    /// is deliberately not this.
    case transcriptUnwritable(complaint: String)
    /// Bloom could not write a review comment, so the list on screen is what the row still holds.
    case reviewCommentUnwritable(complaint: String)
    /// Anything else, in git's own words with the command line dropped.
    case unexplained(String)

    /// What the owner is told, whole and on its own.
    ///
    /// **In paragraphs, because it is read at the worst possible moment.** Every one of these
    /// says three things: what is wrong, what is true about it, and the one action that helps.
    /// They were one block of prose, and a hundred and fifty centred words under a warning
    /// triangle is a wall somebody skips to reach the button, which loses exactly the middle
    /// paragraph that says nothing has been destroyed. The breaks are where the three movements
    /// already were, and not one word changed.
    ///
    /// `unexplained` is the exception and stays a single line: it is git's own sentence with the
    /// argv taken off, and Bloom does not know enough about it to say where a break belongs.
    public var sentence: String {
        switch self {
        case let .projectGone(project, path):
            return """
                The project '\(project)' is no longer at \(path).

                It has been moved, renamed or deleted since Bloom recorded it, so there is no \
                repository left to cut a worktree from.

                Put the folder back, or remove the project from the sidebar and add it again \
                where it lives now.
                """

        case let .projectNotACheckout(project, path):
            return """
                The folder for the project '\(project)' is still at \(path), but it is not a \
                git repository any more.

                Every worktree is cut from the project's own repository, so nothing can be \
                created here until git knows that folder again.

                Restore it, or remove the project from the sidebar and add it again wherever the \
                repository is now.
                """

        case let .projectHasNoCommits(project):
            return """
                The project '\(project)' has no commits yet.

                A worktree is cut from a commit, so there is nothing to start from until the \
                first one is made.

                Make a commit in the project and try again.
                """

        case let .baseBranchGone(branch, project):
            return """
                The project '\(project)' has no branch called '\(branch)' any more, so there \
                is nothing to cut this worktree from.

                Choose another base branch, or put that one back.
                """

        case let .createBranchInUse(branch, holder):
            return """
                The branch '\(branch)' is already checked out in \(holder.described).

                Git allows one worktree per branch, so a second workspace on it cannot be made. \
                Nothing has been created and nothing has been changed.

                \(holder.wayOut), or start a new branch from '\(branch)' on the Create new \
                branch tab, which git does allow and which gets you the same code.
                """

        case let .worktreeGone(workspace):
            return """
                The worktree for '\(workspace)' is not on disk any more.

                Something outside Bloom deleted the folder this workspace was working in, so \
                there are no changes left to read.

                Its branch is still in the project, so archive this workspace and start a new one \
                from that branch to carry on.
                """

        case let .worktreeNotACheckout(workspace):
            return """
                The folder for '\(workspace)' is still there, but git does not know it as a \
                worktree any more, which is what a folder that was deleted and then recreated \
                looks like.

                Its branch is still in the project, so archive this workspace and start a new one \
                from that branch to carry on.
                """

        case let .worktreeBaseBranchGone(branch, workspace):
            return """
                '\(branch)', the branch '\(workspace)' is measured against, is not in the \
                project any more, so there is nothing to compare this worktree with.

                Put that branch back, or give the workspace a base branch that is still there.
                """

        case let .archiveWorktreeGone(workspace):
            return """
                The worktree for '\(workspace)' is not on disk any more.

                Something outside Bloom deleted the folder, so there is no unsaved work left in \
                it and nothing left to remove.

                Archiving it destroys nothing that is still there.
                """

        case let .archiveWorktreeNotACheckout(workspace, path):
            return """
                The folder for '\(workspace)' is still at \(path), and git does not know it as \
                a worktree any more, which is what a folder that was deleted and then recreated \
                looks like.

                A worktree git no longer recognises cannot be handed back, so archiving cannot \
                finish while that folder is there.

                Look at what is in it, delete it yourself, and archive again.
                """

        case let .archiveWorktreeNotEmpty(workspace):
            return """
                The worktree for '\(workspace)' holds files that are in no commit, and Bloom \
                will not delete a worktree holding work that is nowhere else. Nothing has been \
                removed.

                Bloom looks for unsaved work before it runs the archive script, so files that \
                appeared after that, a log or a dump the script left behind, are the usual reason \
                for this.

                Archive again and the confirmation will list what is there, so you can look \
                before you go ahead.
                """

        case let .archiveUnexplained(workspace, complaint):
            return """
                Archiving '\(workspace)' stopped, and Bloom cannot say why.

                Its worktree is still a checkout in good order and holds nothing that is not \
                committed, so this is neither a folder that has moved nor work standing in the \
                way. Nothing has been removed.

                The reason given was: \(complaint)
                """

        case let .restoreBranchInUse(branch, workspace, worktree):
            return """
                The branch '\(branch)' is already checked out in the worktree at \(worktree), \
                and git allows one worktree per branch, so there is nowhere to bring \
                '\(workspace)' back to.

                Another workspace on the same branch is the usual reason.

                Archive that one, or delete that folder if it is not one of Bloom's, and try \
                again.
                """

        case let .restoreBranchGone(branch, workspace):
            return """
                The branch '\(branch)' is not on this Mac and not on any remote Bloom can see, \
                so the commits '\(workspace)' held cannot be reached by name and there is nothing \
                to rebuild its worktree from.

                It stays in Archived, still readable.

                If somebody else still has that branch, fetch the project and try again.
                """

        case let .restoreUnexplained(workspace, complaint):
            return """
                Bringing '\(workspace)' back stopped, and Bloom cannot say why.

                Its project is a checkout in good order and nothing else is holding its branch, \
                so this is neither a project nor a branch that has gone missing. It stays in \
                Archived, with nothing lost.

                The reason given was: \(complaint)
                """

        case let .continueUnexplained(workspace, complaint):
            return """
                Continuing '\(workspace)' stopped, and Bloom cannot say why.

                Its worktree is still a checkout in good order and the branch it would be cut \
                from is still there, so this is neither a folder that has moved nor a branch that \
                has gone missing. The worktree is where it was, on the branch it was on, with \
                everything in it untouched.

                The reason given was: \(complaint)
                """

        case let .recordUnwritable(workspace, complaint):
            return """
                Bloom finished the disk work for '\(workspace)' and could not write the result \
                into its own database, so the sidebar and the archive are showing where this \
                workspace was rather than where it is.

                Nothing in the worktree is at risk; the record is the only thing that is wrong.

                Quit Bloom and open it again, and if it happens a second time the database itself \
                needs looking at.

                The database said: \(complaint)
                """

        case let .transcriptUnwritable(complaint):
            return """
                Bloom could not write this turn into its own database, so this conversation is \
                missing rows from here on.

                Nothing in the worktree has been touched and every change the agent has made is \
                still there.

                Sending again will fail the same way while the database is refusing writes, so \
                quit Bloom and open it again; if it happens a second time the database itself \
                needs looking at.

                The database said: \(complaint)
                """

        case let .reviewCommentUnwritable(complaint):
            return """
                Bloom could not save that review comment, so the list is showing what is \
                stored rather than what you typed.

                Nothing in the worktree has been touched and no comment already written has been \
                lost.

                Trying again will fail the same way while the database is refusing writes, so \
                quit Bloom and open it again; if it happens a second time the database itself \
                needs looking at.

                The database said: \(complaint)
                """

        case let .unexplained(message):
            return message
        }
    }

    /// Why creating a workspace in this project failed.
    ///
    /// The project, and never the workspace being created, because the worktree is cut from the
    /// project's repository and the branches are listed there. A workspace whose own folder has
    /// been deleted has nothing to do with it, which is why creating one still works while another
    /// one's worktree is missing.
    public static func creating(
        _ error: any Error, project: String, projectPath: String, baseBranch: String
    ) async -> WorkspaceTrouble {
        // Asked of the error's type rather than of its words, which is the rule this whole file
        // exists to keep. `WorkspaceManager.open` decided this before it ran anything and threw
        // the branch and the holder as a value, so there is no stderr to read and no chance of
        // "exit status 128" arriving in a dialogue by way of `unexplained`.
        if let inUse = error as? BranchInUse {
            return .createBranchInUse(branch: inUse.branch, holder: inUse.holder)
        }

        switch await CheckoutStanding.of(projectPath, branch: baseBranch) {
        case .missing: return .projectGone(project: project, path: projectPath)
        case .notACheckout: return .projectNotACheckout(project: project, path: projectPath)
        case .noCommitsYet: return .projectHasNoCommits(project: project)
        case .branchMissing(let branch): return .baseBranchGone(branch: branch, project: project)
        case .fine: return .unexplained(CheckoutStanding.complaint(about: error))
        }
    }

    /// Whether a refused store write is worth telling the owner about, and what to say.
    ///
    /// Nil is the whole point of this method. A write for a workspace the owner has just archived
    /// or removed has nowhere to go and nothing to say: the session row went with the workspace,
    /// `ON DELETE CASCADE`, the foreign key correctly refused the row the turn was still trying to
    /// add, and the gesture that removed the transcript was the owner's own. There is no
    /// transcript left to record into, so the runner drops the write and stops, quietly.
    ///
    /// It is deliberately not a `try?` at the write site. That would swallow a database that has
    /// genuinely gone wrong along with it, which is the failure the `.error` event on a refused
    /// write was written to stop being invisible in the first place. So the two are told apart by
    /// asking the database which one it is, and only the second is said out loud.
    ///
    /// `.unanswerable` reports, and reports through the same case as `.there`. A database that
    /// cannot answer whether a row exists is broken by any reading, and guessing in the quiet
    /// direction would put the silence back exactly where it must not be.
    public static func recording(
        transcript: TranscriptStanding, complaint: String
    ) -> WorkspaceTrouble? {
        switch transcript {
        case .gone: return nil
        case .there, .unanswerable: return .transcriptUnwritable(complaint: complaint)
        }
    }

    /// Why reading a workspace's changes failed.
    ///
    /// Asked of the worktree rather than of the project, because that is where the diff is
    /// measured and because a worktree can be gone while the project it was cut from is perfectly
    /// healthy. A worktree shares its refs with that project, so the branch question is the same
    /// question either way.
    public static func readingChanges(
        _ error: any Error, workspace: String, path: String, baseBranch: String
    ) async -> WorkspaceTrouble {
        switch await CheckoutStanding.of(path, branch: baseBranch) {
        case .missing: return .worktreeGone(workspace: workspace)
        case .notACheckout: return .worktreeNotACheckout(workspace: workspace)
        // A worktree cannot outlive its repository's first commit, so this is the repository the
        // worktree points at having been emptied. The folder is what the reader can act on.
        case .noCommitsYet: return .worktreeNotACheckout(workspace: workspace)
        case .branchMissing(let branch):
            return .worktreeBaseBranchGone(branch: branch, workspace: workspace)
        case .fine: return .unexplained(CheckoutStanding.complaint(about: error))
        }
    }

    /// Why archiving a workspace failed.
    ///
    /// Covers both halves of the gesture, because both used to show `error.readableMessage` and
    /// the worse of the two was the safety check: its text is read while somebody is deciding
    /// whether to destroy a worktree, and it said "`git status --porcelain` exited 128" there.
    /// One method for the two, because the reader is answering the same question either way and
    /// two vocabularies for it would drift.
    ///
    /// The proven failure this exists for is the dirty worktree. `WorkspaceManager.archive` runs
    /// the safety check, then the archive script, then `Git.removeWorktree(force: false)`, so a
    /// script that leaves a log or a database dump behind makes the safe removal fail with
    /// "contains modified or untracked files" after the check has already cleared. Nothing in
    /// that stderr says the script was the cause, and the count of untracked files does.
    public static func archiving(
        _ error: any Error, workspace: String, path: String, baseBranch: String
    ) async -> WorkspaceTrouble {
        // The error's type, and only here. Every other question below is put to the worktree, but
        // the last thing an archive does is write the row, and by then the worktree is meant to
        // be gone: probing the folder for a refused write would find it missing and report a
        // deleted worktree as the fault. `readingChanges` needs no such test because nothing it
        // does touches the database.
        if error is SQLiteError {
            return .recordUnwritable(workspace: workspace, complaint: complaint(about: error))
        }

        switch await CheckoutStanding.of(path, branch: baseBranch) {
        case .missing: return .archiveWorktreeGone(workspace: workspace)
        case .notACheckout:
            return .archiveWorktreeNotACheckout(workspace: workspace, path: path)
        // A worktree cannot outlive its repository's first commit, so this is the repository the
        // worktree points at having been emptied. The folder is what the reader can act on.
        case .noCommitsYet:
            return .archiveWorktreeNotACheckout(workspace: workspace, path: path)
        case .branchMissing(let branch):
            return .worktreeBaseBranchGone(branch: branch, workspace: workspace)
        case .fine:
            // Asked of the worktree rather than read out of the stderr, so the same sentence
            // arrives whether git refused the removal or the safety check never finished.
            let work = try? await Git.localWork(worktree: path)
            if work?.hasUncommitted == true { return .archiveWorktreeNotEmpty(workspace: workspace) }
            return .archiveUnexplained(workspace: workspace, complaint: complaint(about: error))
        }
    }

    /// Why continuing a merged workspace on a fresh branch failed.
    ///
    /// Asked of the worktree, like `readingChanges`, because both halves of the gesture happen
    /// there: the facts are read out of the worktree, and the new branch is cut in it. The
    /// project is not probed at all, since a worktree shares its refs with the project it came
    /// from, so the base branch question is the same question either way.
    ///
    /// This is the fifth modal that used to show `error.readableMessage`. Every call behind it is
    /// git in a worktree, so a refusal put the argv and the exit status in front of somebody who
    /// had pressed one button, and `PullRequestBar` then appended "This worktree is where it was"
    /// to it. That reassurance belongs in the sentence rather than glued to whatever git said,
    /// which is why `.continueUnexplained` carries it and why the two folder cases, where the
    /// worktree is emphatically not where it was, do not get it.
    public static func continuing(
        _ error: any Error, workspace: String, path: String, baseBranch: String
    ) async -> WorkspaceTrouble {
        // See `archiving`: the last thing a continuation does is write the branch, and by then
        // the checkout has already moved, so probing the folder for a refused write would report
        // the wrong fault entirely.
        if error is SQLiteError {
            return .recordUnwritable(workspace: workspace, complaint: complaint(about: error))
        }

        switch await CheckoutStanding.of(path, branch: baseBranch) {
        case .missing: return .worktreeGone(workspace: workspace)
        case .notACheckout: return .worktreeNotACheckout(workspace: workspace)
        // A worktree cannot outlive its repository's first commit, so this is the repository the
        // worktree points at having been emptied. The folder is what the reader can act on.
        case .noCommitsYet: return .worktreeNotACheckout(workspace: workspace)
        case .branchMissing(let branch):
            return .worktreeBaseBranchGone(branch: branch, workspace: workspace)
        case .fine:
            return .continueUnexplained(workspace: workspace, complaint: complaint(about: error))
        }
    }

    /// Why bringing an archived workspace back failed.
    ///
    /// Asked of the project rather than of the worktree, which is the one thing that does not
    /// exist yet: restoring cuts a fresh worktree from the project's repository, so every
    /// question worth asking is about that repository.
    ///
    /// The proven failure this exists for is the branch being checked out somewhere else.
    /// `WorkspaceRestore` calls `Git.addWorktree`, git allows a branch in one worktree at a time,
    /// and the refusal is "fatal: 'feature' is already used by worktree at '/.../wt1'" with the
    /// argv and the exit status wrapped round it. The worktree list says the same thing without
    /// any of that, and says which folder to go and look at.
    public static func restoring(
        _ error: any Error, workspace: String, branch: String, project: String, projectPath: String
    ) async -> WorkspaceTrouble {
        // See `archiving`: restoring also ends by writing the row, and by then the worktree it
        // rebuilt is on disk and healthy, so no probe of the project would find anything wrong.
        if error is SQLiteError {
            return .recordUnwritable(workspace: workspace, complaint: complaint(about: error))
        }

        switch await CheckoutStanding.of(projectPath) {
        case .missing: return .projectGone(project: project, path: projectPath)
        case .notACheckout: return .projectNotACheckout(project: project, path: projectPath)
        case .noCommitsYet: return .projectHasNoCommits(project: project)
        // The branch is deliberately not asked of `CheckoutStanding`. A workspace restored from a
        // remote branch has no local branch by definition, and calling that missing would refuse
        // the one case that works.
        case .branchMissing, .fine:
            let worktrees = (try? await Git.worktrees(of: projectPath)) ?? []
            if let holder = worktrees.first(where: { $0.branch == branch }) {
                return .restoreBranchInUse(
                    branch: branch, workspace: workspace, worktree: holder.path
                )
            }
            let isLocal = await Git.branchExists(branch, in: projectPath)
            let isOnARemote = await Git.hasRemoteCounterpart(branch, in: projectPath)
            if !isLocal, !isOnARemote {
                return .restoreBranchGone(branch: branch, workspace: workspace)
            }
            return .restoreUnexplained(workspace: workspace, complaint: complaint(about: error))
        }
    }

    /// The failure in its own words, with both the command line and the SQL statement dropped.
    ///
    /// Archiving and restoring can fail in git or in the database inside one call, so one `catch`
    /// holds a `ShellError` on most paths and a `SQLiteError` on the last one. Each has its own
    /// stripper already, and picking between them here is what stops "message [UPDATE workspaces
    /// SET ... VALUES (?, ?, ?)]" reaching a modal the way it did from `readableMessage`.
    public static func complaint(about error: any Error) -> String {
        error is SQLiteError
            ? TranscriptStanding.complaint(about: error)
            : CheckoutStanding.complaint(about: error)
    }
}
