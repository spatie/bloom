import Testing
import Foundation
@testable import BloomCore

/// A directory that Bloom recorded and that has stopped being a checkout, asked to do each of the
/// things Bloom does in it.
///
/// The bug behind this suite: creating a workspace put up a modal reading "`git for-each-ref
/// --format=%(refname:short) refs/heads` exited 128: fatal: not a git repository (or any of the
/// parent directories): .git", and the inspector said the same about `git rev-parse --verify
/// main^{commit}` for a different workspace in the same window. Both were the raw `ShellError`.
@Suite("Trouble with a recorded directory", .tags(.git, .destructive), .scratchDirectory)
struct WorkspaceTroubleTests {
    // MARK: - The probes

    @Test("asks the path rather than reading git's stderr")
    func standingOfEveryState() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }

        #expect(await CheckoutStanding.of(repo.path, branch: "main") == .fine)
        #expect(await CheckoutStanding.of(repo.path, branch: "nope") == .branchMissing("nope"))
        #expect(await CheckoutStanding.of(repo.path + "-gone") == .missing)

        let plain = TestScratch.unique("plain")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        #expect(await CheckoutStanding.of(plain) == .notACheckout)

        let fresh = TestScratch.unique("fresh")
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q", "-b", "main"], cwd: fresh)
        #expect(await CheckoutStanding.of(fresh) == .noCommitsYet)
    }

    /// The command line is the one part of a failure the reader neither chose nor can change.
    @Test("drops the command line from git's complaint")
    func complaintDropsTheCommand() {
        let error = ShellError(
            command: "git for-each-ref --format=%(refname:short) refs/heads",
            status: 128,
            stderr: "fatal: not a git repository (or any of the parent directories): .git"
        )
        let complaint = CheckoutStanding.complaint(about: error)
        #expect(complaint == "fatal: not a git repository (or any of the parent directories): .git.")
        #expect(!complaint.contains("for-each-ref"))
    }

    // MARK: - Creating a workspace

    @Test("names the project and its folder when the project has gone")
    func creatingInAProjectThatHasGone() async throws {
        let path = TestScratch.unique("harbour")
        let trouble = await WorkspaceTrouble.creating(
            ShellError(command: "git for-each-ref", status: 128, stderr: "fatal: not a git repository"),
            project: "harbour", projectPath: path, baseBranch: "main"
        )
        #expect(trouble == .projectGone(project: "harbour", path: path))
        #expect(trouble.sentence.contains("The project 'harbour' is no longer at \(path)."))
        #expect(trouble.sentence.contains("add it again"))
        #expect(!trouble.sentence.contains("for-each-ref"))
        #expect(!trouble.sentence.contains("`"))
    }

    /// The state Freek's machine was in: a folder still there, with no `.git` in it or above it.
    @Test("says a project folder is no longer a checkout, rather than quoting git")
    func creatingInAFolderThatIsNoLongerACheckout() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        try FileManager.default.removeItem(atPath: repo.path + "/.git")

        // The failure the sheet would actually be holding, produced by running the real command.
        let error = await #expect(throws: (any Error).self) {
            try await Git.branches(of: repo.path)
        }
        let trouble = await WorkspaceTrouble.creating(
            error ?? ShellError(command: "git", status: 128, stderr: ""),
            project: "bloom", projectPath: repo.path, baseBranch: "main"
        )
        #expect(trouble == .projectNotACheckout(project: "bloom", path: repo.path))
        #expect(trouble.sentence.contains("is not a git repository any more"))
        #expect(!trouble.sentence.contains("for-each-ref"))
        #expect(!trouble.sentence.contains("exited 128"))
    }

    @Test("says which branch is gone when the base branch has been deleted")
    func creatingFromABranchThatIsGone() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }

        let trouble = await WorkspaceTrouble.creating(
            ShellError(command: "git worktree add", status: 128, stderr: "fatal: invalid reference"),
            project: "bloom", projectPath: repo.path, baseBranch: "release"
        )
        #expect(trouble == .baseBranchGone(branch: "release", project: "bloom"))
        #expect(trouble.sentence.contains("no branch called 'release'"))
    }

    @Test("passes a failure through when the project is perfectly healthy")
    func creatingInAHealthyProject() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }

        let trouble = await WorkspaceTrouble.creating(
            WorkspaceError.pathInUse("/somewhere"),
            project: "bloom", projectPath: repo.path, baseBranch: "main"
        )
        #expect(trouble == .unexplained("/somewhere already exists."))
    }

    // MARK: - Reading the changes

    @Test("names the workspace, not its path, when the worktree has been deleted")
    func readingChangesWithNoWorktree() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "sidebar-blue", base: "main")
        try FileManager.default.removeItem(atPath: worktree)

        // Launching a subprocess in a deleted directory throws before git runs at all, which is
        // why the stderr can never be what decides this.
        let error = await #expect(throws: (any Error).self) {
            try await Git.changedFiles(worktree: worktree, base: "main")
        }
        let trouble = await WorkspaceTrouble.readingChanges(
            error ?? ShellError(command: "git", status: 128, stderr: ""),
            workspace: "Sidebar blue", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .worktreeGone(workspace: "Sidebar blue"))
        #expect(trouble.sentence.contains("The worktree for 'Sidebar blue' is not on disk any more."))
        #expect(trouble.sentence.contains("archive this workspace"))
        #expect(!trouble.sentence.contains(worktree))
    }

    /// A folder deleted and then recreated, which is what was actually left behind on the machine
    /// this was found on: one `.DS_Store` and nothing else.
    @Test("says a worktree folder is no longer a worktree")
    func readingChangesWithARecreatedFolder() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "limits-panel", base: "main")
        try FileManager.default.removeItem(atPath: worktree)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        let error = await #expect(throws: (any Error).self) {
            try await Git.changedFiles(worktree: worktree, base: "main")
        }
        // The exact modal Freek was shown, which is what has to stop reaching a reader.
        #expect("\(error!)".contains("rev-parse"))

        let trouble = await WorkspaceTrouble.readingChanges(
            error!, workspace: "Limits panel", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .worktreeNotACheckout(workspace: "Limits panel"))
        #expect(trouble.sentence.contains("git does not know it as a worktree any more"))
        #expect(!trouble.sentence.contains("rev-parse"))
        #expect(!trouble.sentence.contains("`"))
    }

    @Test("says which base branch went missing under a healthy worktree")
    func readingChangesWithNoBaseBranch() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "retry-surfaces", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let trouble = await WorkspaceTrouble.readingChanges(
            ShellError(command: "git merge-base", status: 128, stderr: "fatal: bad revision"),
            workspace: "Retry surfaces", path: worktree, baseBranch: "release"
        )
        #expect(trouble == .worktreeBaseBranchGone(branch: "release", workspace: "Retry surfaces"))
        #expect(trouble.sentence.contains("'release', the branch 'Retry surfaces' is measured against"))
    }

    // MARK: - Archiving

    /// The proven failure, reproduced the way it happens: the safety check clears, then the
    /// archive script writes a log into the worktree, then the safe removal refuses. Freek was
    /// shown "`git worktree remove ...` exited 128: fatal: '/.../wt1' contains modified or
    /// untracked files, use --force to delete it".
    @Test("blames the leftover files, not the command that tripped over them")
    func archivingAWorktreeAScriptDirtied() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "archive-logs", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        // What an archive script leaves behind after the check for unsaved work has already run.
        try "teardown ok\n".write(toFile: worktree + "/archive.log", atomically: true, encoding: .utf8)

        let error = await #expect(throws: (any Error).self) {
            try await Git.removeWorktree(repo: repo.path, path: worktree, force: false)
        }
        #expect("\(error!)".contains("worktree remove"))

        let trouble = await WorkspaceTrouble.archiving(
            error!, workspace: "Archive logs", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .archiveWorktreeNotEmpty(workspace: "Archive logs"))
        #expect(trouble.sentence.contains("holds files that are in no commit"))
        #expect(trouble.sentence.contains("archive script"))
        #expect(!trouble.sentence.contains("git"))
        #expect(!trouble.sentence.contains("exited"))
        #expect(!trouble.sentence.contains("`"))
    }

    @Test("says there is nothing left to lose when the worktree has already gone")
    func archivingAWorktreeThatIsNotThere() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")

        let trouble = await WorkspaceTrouble.archiving(
            ShellError(command: "git status --porcelain", status: 128, stderr: "fatal: cannot chdir"),
            workspace: "Sidebar blue", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .archiveWorktreeGone(workspace: "Sidebar blue"))
        #expect(trouble.sentence.contains("destroys nothing that is still there"))
        #expect(!trouble.sentence.contains("status --porcelain"))
    }

    /// The one sentence in the type that names a worktree path, because deleting that folder is
    /// the only thing that unblocks the archive.
    @Test("names the folder when git no longer knows it as a worktree")
    func archivingAFolderGitHasLostTrackOf() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "limits-panel", base: "main")
        try FileManager.default.removeItem(atPath: worktree)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let trouble = await WorkspaceTrouble.archiving(
            ShellError(command: "git worktree remove", status: 128, stderr: "fatal: not a working tree"),
            workspace: "Limits panel", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .archiveWorktreeNotACheckout(workspace: "Limits panel", path: worktree))
        #expect(trouble.sentence.contains("delete it yourself"))
        #expect(!trouble.sentence.contains("not a working tree"))
    }

    @Test("passes an archive failure through when the worktree is clean and healthy")
    func archivingAHealthyWorktree() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "retry-surfaces", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let trouble = await WorkspaceTrouble.archiving(
            ShellError(command: "git branch -d retry-surfaces", status: 1, stderr: "error: the branch is not fully merged"),
            workspace: "Retry surfaces", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .archiveUnexplained(
            workspace: "Retry surfaces", complaint: "error: the branch is not fully merged."
        ))
        #expect(trouble.sentence.contains("Nothing has been removed."))
        #expect(!trouble.sentence.contains("branch -d"))
    }

    // MARK: - Bringing one back

    /// The proven failure: git allows a branch in one worktree at a time, and the refusal names
    /// the folder holding it inside an argv and an exit status nobody can act on.
    @Test("names the branch and the folder holding it, rather than quoting the refusal")
    func restoringOntoABranchAnotherWorktreeHas() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let held = TestScratch.unique("wt1")
        try await Git.addWorktree(repo: repo.path, path: held, branch: "feature", base: "main")
        defer { try? FileManager.default.removeItem(atPath: held) }

        // Exactly what restoring does: a second worktree for a branch that already has one.
        let error = await #expect(throws: (any Error).self) {
            try await Git.addWorktree(
                repo: repo.path, path: TestScratch.unique("wt2"), branch: "feature", base: "main"
            )
        }
        #expect("\(error!)".contains("already used by worktree"))

        let trouble = await WorkspaceTrouble.restoring(
            error!, workspace: "Feature", branch: "feature",
            project: "bloom", projectPath: repo.path
        )
        guard case let .restoreBranchInUse(branch, workspace, folder) = trouble else {
            Issue.record("expected the branch to be diagnosed as in use, got \(trouble)")
            return
        }
        #expect(branch == "feature")
        #expect(workspace == "Feature")
        #expect(folder.hasSuffix((held as NSString).lastPathComponent))
        #expect(trouble.sentence.contains("is already checked out in the worktree at"))
        #expect(!trouble.sentence.contains("worktree add"))
        #expect(!trouble.sentence.contains("exited"))
    }

    @Test("says the branch is gone when neither this Mac nor a remote has it")
    func restoringABranchNobodyHas() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }

        let trouble = await WorkspaceTrouble.restoring(
            WorkspaceRestoreRefusal.branchGone(branch: "sidebar-blue"),
            workspace: "Sidebar blue", branch: "sidebar-blue",
            project: "bloom", projectPath: repo.path
        )
        #expect(trouble == .restoreBranchGone(branch: "sidebar-blue", workspace: "Sidebar blue"))
        #expect(trouble.sentence.contains("not on this Mac and not on any remote"))
        #expect(trouble.sentence.contains("stays in Archived"))
    }

    @Test("names the project and its folder when the project has gone")
    func restoringIntoAProjectThatHasGone() async throws {
        let path = TestScratch.unique("harbour")
        let trouble = await WorkspaceTrouble.restoring(
            ShellError(command: "git worktree add", status: 128, stderr: "fatal: not a git repository"),
            workspace: "Sidebar blue", branch: "sidebar-blue",
            project: "harbour", projectPath: path
        )
        #expect(trouble == .projectGone(project: "harbour", path: path))
        #expect(!trouble.sentence.contains("worktree add"))
    }

    /// The raw-SQL path, and the reason this suite exists twice over: restoring ends by writing
    /// the row, `SQLiteError.description` appends the statement, and the modal read
    /// "message [UPDATE workspaces SET ... VALUES (?, ?, ?)]".
    @Test("drops the statement when the database refuses the restored row")
    func restoringWhenTheDatabaseRefusesTheRow() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }

        let trouble = await WorkspaceTrouble.restoring(
            SQLiteError(
                message: "database disk image is malformed",
                sql: "UPDATE workspaces SET name = ?, branch = ?, path = ?, state = ? WHERE id = ?"
            ),
            workspace: "Sidebar blue", branch: "sidebar-blue",
            project: "bloom", projectPath: repo.path
        )
        #expect(trouble == .recordUnwritable(
            workspace: "Sidebar blue", complaint: "database disk image is malformed."
        ))
        #expect(!trouble.sentence.contains("?"))
        #expect(!trouble.sentence.contains("UPDATE"))
        #expect(!trouble.sentence.contains("workspaces SET"))
        #expect(trouble.sentence.contains("Nothing in the worktree is at risk"))
        #expect(trouble.sentence.contains("The database said: database disk image is malformed."))
    }

    // MARK: - Continuing after a merge

    /// The fifth modal that showed `error.readableMessage`. Both calls behind Continue are git in
    /// a worktree, so a refusal put the argv in front of somebody who had pressed one button.
    @Test("says why continuing stopped without quoting the command")
    func continuingAHealthyWorktree() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "file-pill", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let trouble = await WorkspaceTrouble.continuing(
            ShellError(
                command: "git checkout -b file-pill-2 abc123",
                status: 128,
                stderr: "fatal: a branch named 'file-pill-2' already exists"
            ),
            workspace: "File pill", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .continueUnexplained(
            workspace: "File pill",
            complaint: "fatal: a branch named 'file-pill-2' already exists."
        ))
        #expect(!trouble.sentence.contains("checkout -b"))
        #expect(!trouble.sentence.contains("128"))
        // The reassurance the bar used to glue on, said where it is true.
        #expect(trouble.sentence.contains("The worktree is where it was"))
        #expect(trouble.sentence.contains("already exists"))
    }

    /// And not said where it is false: a deleted worktree is emphatically not where it was, which
    /// is why the appended sentence had to move into the enum rather than stay at the call site.
    @Test("does not promise the worktree is intact when it has gone")
    func continuingWithNoWorktree() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "merge-scroll", base: "main")
        try FileManager.default.removeItem(atPath: worktree)

        let trouble = await WorkspaceTrouble.continuing(
            ShellError(command: "git rev-parse", status: 128, stderr: "fatal: not a git repository"),
            workspace: "Merge scroll", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .worktreeGone(workspace: "Merge scroll"))
        #expect(!trouble.sentence.contains("The worktree is where it was"))
    }

    /// The last step of a continuation is the branch write, by which point the checkout has
    /// already moved, so probing the folder would report the wrong fault entirely.
    @Test("blames the database rather than the folder for a refused write")
    func continuingWithARefusedWrite() async throws {
        let trouble = await WorkspaceTrouble.continuing(
            SQLiteError(
                message: "database disk image is malformed",
                sql: "UPDATE workspaces SET branch = ? WHERE id = ?"
            ),
            workspace: "Merge scroll", path: "/nowhere", baseBranch: "main"
        )
        #expect(trouble == .recordUnwritable(
            workspace: "Merge scroll", complaint: "database disk image is malformed."
        ))
        #expect(!trouble.sentence.contains("UPDATE"))
    }

    // MARK: - One missing worktree does not take down the rest

    /// The question the modal raised: creating workspace B should not care that workspace A's
    /// folder has gone. It reads its branches from the project, which is still there.
    @Test("creates a workspace while another workspace's worktree is missing")
    func createsWhileAnotherWorktreeIsMissing() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeTestStore("trouble"))
        let registered = try await manager.addRepository(at: repo.path)

        let first = try await manager.createWorkspace(repo: registered, prompt: "Sidebar blue")
        try FileManager.default.removeItem(atPath: first.path)

        let second = try await manager.createWorkspace(repo: registered, prompt: "Limits panel")
        #expect(second.branch == "limits-panel")
        #expect(FileManager.default.fileExists(atPath: second.path + "/README.md"))

        // And the workspace whose folder went is diagnosed rather than reported.
        let error = await #expect(throws: (any Error).self) {
            try await Git.changedFiles(worktree: first.path, base: first.baseBranch)
        }
        let trouble = await WorkspaceTrouble.readingChanges(
            error!, workspace: first.name, path: first.path, baseBranch: first.baseBranch
        )
        #expect(trouble == .worktreeGone(workspace: first.name))
    }
}

// MARK: - Trouble writing a transcript

/// The other half of the same bug, a day later.
///
/// The owner archived a workspace while its agent was still working and got a modal reading
/// "The agent stopped in Review the changes / Could not store a system row: FOREIGN KEY constraint
/// failed [INSERT INTO messages (session_id, seq, kind, payload, created_at, duration_ms, ref_id)
/// VALUES (?, ?, ?, ?, ?, ?, ?)]". Two faults in one dialog: it was not a failure at all, and if
/// it had been, that is not how one is said.
@Suite("Trouble writing a transcript", .tags(.persistence), .scratchDirectory)
struct TranscriptTroubleTests {
    // MARK: - The probe

    @Test("asks the database whether the session is there, rather than reading its complaint")
    func standingOfEverySession() async throws {
        let store = try makeTestStore("transcript-standing")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))

        #expect(await TranscriptStanding.of(sessionID: session.id, in: store) == .there)

        // Exactly what archiving or removing does: the cascade takes the session with it.
        try await store.deleteWorkspace(id: workspace.id)
        #expect(await TranscriptStanding.of(sessionID: session.id, in: store) == .gone)
    }

    // MARK: - Which refusals are silence

    /// A row refused because the owner has just deleted the workspace it belonged to is not a
    /// fault, and there is no transcript left to report it in.
    @Test("a session that has gone is not worth a word")
    func aDeletedTranscriptIsSilent() {
        #expect(WorkspaceTrouble.recording(transcript: .gone, complaint: "anything") == nil)
    }

    /// And the swallow-everything version of the same fix would hide the failure the `.error`
    /// event on a refused write exists for.
    @Test("a database that refused for any other reason is still reported")
    func anythingElseIsReported() {
        #expect(WorkspaceTrouble.recording(transcript: .there, complaint: "Disk image is malformed.")
            == .transcriptUnwritable(complaint: "Disk image is malformed."))
        // A database that cannot answer the question is broken by any reading of it, so the
        // benefit of the doubt goes to reporting rather than to silence.
        #expect(WorkspaceTrouble.recording(transcript: .unanswerable, complaint: "It is closed.")
            == .transcriptUnwritable(complaint: "It is closed."))
    }

    // MARK: - The sentence

    /// The statement is the one part of the failure the reader neither wrote nor can change, and
    /// seven bound question marks are the worst version of the thing `WorkspaceTrouble` exists to
    /// prevent.
    @Test("drops the statement from the database's complaint")
    func complaintDropsTheStatement() {
        let error = SQLiteError(
            message: "FOREIGN KEY constraint failed",
            sql: "INSERT INTO messages (session_id, seq, kind, payload, created_at, duration_ms, ref_id) "
                + "VALUES (?, ?, ?, ?, ?, ?, ?)"
        )
        #expect(TranscriptStanding.complaint(about: error) == "FOREIGN KEY constraint failed.")
        #expect(!TranscriptStanding.complaint(about: error).contains("?"))
        #expect(!TranscriptStanding.complaint(about: error).contains("INSERT INTO"))
    }

    @Test("says what happened, what is safe, and whether trying again helps")
    func theSentenceIsWhatAPersonNeeds() {
        let sentence = WorkspaceTrouble.transcriptUnwritable(
            complaint: "Database disk image is malformed."
        ).sentence

        #expect(!sentence.contains("?"))
        #expect(!sentence.contains("INSERT"))
        #expect(!sentence.contains("session_id"))
        // What is at stake, which is nothing on disk.
        #expect(sentence.contains("worktree"))
        // Whether trying again helps, which here it does not.
        #expect(sentence.contains("Sending again will fail the same way"))
        // The database's own words survive, marked as the database's, exactly as a CLI's do on a
        // failed turn.
        #expect(sentence.contains("The database said: Database disk image is malformed."))
    }
}

/// The shape of what the owner is told, rather than its words.
///
/// These are read under a warning triangle at the moment something has gone wrong, and they were
/// one block of a hundred and fifty centred words. A wall like that is skipped on the way to the
/// button, and the paragraph most often skipped is the middle one, which is the one saying nothing
/// has been destroyed.
@Suite("Trouble reads as paragraphs")
struct WorkspaceTroubleShapeTests {
    /// One of every case, so a case added later has to be added here and answered for.
    private static let all: [WorkspaceTrouble] = [
        .projectGone(project: "bloom", path: "/tmp/bloom"),
        .projectNotACheckout(project: "bloom", path: "/tmp/bloom"),
        .projectHasNoCommits(project: "bloom"),
        .baseBranchGone(branch: "main", project: "bloom"),
        .createBranchInUse(branch: "main", holder: .workspace("Sidebar blue")),
        .createBranchInUse(branch: "main", holder: .projectCheckout(path: "/tmp/bloom")),
        .createBranchInUse(branch: "main", holder: .otherWorktree(path: "/tmp/conductor/wt")),
        .worktreeGone(workspace: "Sidebar blue"),
        .worktreeNotACheckout(workspace: "Sidebar blue"),
        .worktreeBaseBranchGone(branch: "main", workspace: "Sidebar blue"),
        .archiveWorktreeGone(workspace: "Sidebar blue"),
        .archiveWorktreeNotACheckout(workspace: "Sidebar blue", path: "/tmp/wt"),
        .archiveWorktreeNotEmpty(workspace: "Sidebar blue"),
        .archiveUnexplained(workspace: "Sidebar blue", complaint: "it stopped."),
        .restoreBranchInUse(branch: "main", workspace: "Sidebar blue", worktree: "/tmp/wt"),
        .restoreBranchGone(branch: "main", workspace: "Sidebar blue"),
        .restoreUnexplained(workspace: "Sidebar blue", complaint: "it stopped."),
        .continueUnexplained(workspace: "Sidebar blue", complaint: "it stopped."),
        .recordUnwritable(workspace: "Sidebar blue", complaint: "disk image is malformed."),
        .transcriptUnwritable(complaint: "disk image is malformed."),
        .reviewCommentUnwritable(complaint: "disk image is malformed."),
    ]

    @Test("every trouble is broken into paragraphs")
    func everyTroubleHasParagraphs() {
        for trouble in Self.all {
            let paragraphs = trouble.sentence.components(separatedBy: "\n\n")
            #expect(paragraphs.count >= 2, "\(trouble) is still one block")
            for paragraph in paragraphs {
                #expect(!paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// A paragraph break is not a line break: these are drawn centred in a narrow column that
    /// wraps them itself, and a hard wrap would fight it.
    @Test("nothing is wrapped by hand")
    func nothingIsHardWrapped() {
        for trouble in Self.all {
            for paragraph in trouble.sentence.components(separatedBy: "\n\n") {
                #expect(!paragraph.contains("\n"), "\(trouble) has a hard line break in it")
            }
        }
    }

    /// git's own sentence, with the argv taken off. Bloom does not know enough about it to say
    /// where a break would belong.
    @Test("the one Bloom did not write is left alone")
    func theUnexplainedOneIsPassedThrough() {
        #expect(WorkspaceTrouble.unexplained("fatal: not a git repository").sentence
            == "fatal: not a git repository")
    }
}
