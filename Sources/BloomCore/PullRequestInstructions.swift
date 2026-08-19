import Foundation

/// How this project opens a pull request, as a file in the repository.
///
/// Pressing Create pull request does not call `gh`. It composes a turn and sends it, exactly as if
/// the user had typed it, with this file attached. The agent is already authenticated, already
/// standing in the worktree and already knows what it changed, so it can write a real description
/// instead of Bloom guessing one, and the whole request lands in the transcript where it can be
/// read, corrected and sent again.
///
/// The instructions are a FILE rather than a string buried in the app, for the same reason setup
/// scripts became `.bloom/setup.sh`: a program belongs somewhere it can be read, edited, diffed
/// and shared with the team. A project that opens pull requests differently changes this file, and
/// everybody working in that repository gets the change.
///
/// There are two of them, and which one is which matters more than anything else here:
///
/// - `.bloom/pr-instructions.md` is the PROJECT's. If it exists it wins, tracked or not, and
///   nothing here ever writes it, edits it or deletes it. Once it exists it belongs to the
///   project rather than to this app.
/// - `.bloom/scratch/pr-instructions.md` is BLOOM's, written on demand from the default below so
///   nobody has to author one before the button works. It sits in a shielded folder
///   (`WorktreeScratch`), so git cannot see it and no agent can commit it.
///
/// The split exists because the first version had only the first path and wrote the default into
/// it. That file was untracked, covered by no ignore rule, and attached to a turn whose own
/// instructions say to commit anything uncommitted. The agent obeyed, and Bloom's scratch file
/// went out in a user's pull request and was merged. A file only Bloom writes has no business
/// being anywhere git will report it.
public enum PullRequestInstructions {
    /// The project's own copy, if it has one. Relative to the worktree, because that is where the
    /// agent is standing and a path inside the worktree is one it may read without asking.
    public static let projectPath = ".bloom/pr-instructions.md"

    /// Where Bloom writes the default when the project has no copy of its own.
    public static let scratchPath = "\(WorktreeScratch.generated)/pr-instructions.md"

    /// Makes sure a copy exists in this worktree, and answers where it is.
    ///
    /// The project's copy wins outright. Otherwise the default goes into the scratch folder, whose
    /// `.gitignore` is written first so the file is invisible from the moment it lands rather than
    /// from a moment afterwards.
    ///
    /// Nil when nothing could be written, which is the caller's signal to put the instructions in
    /// the message itself rather than to fail. A read-only checkout is a reason to fall back, not
    /// a reason for a button to stop working.
    public static func ensure(in worktree: String, contents: String = defaultMarkdown) async -> String? {
        let manager = FileManager.default
        let project = (worktree as NSString).appendingPathComponent(projectPath)

        if manager.isReadableFile(atPath: project) {
            if let moved = await reclaimStrayDefault(at: project, in: worktree) { return moved }
            return projectPath
        }

        WorktreeScratch.shield(WorktreeScratch.generated, in: worktree)
        let scratch = (worktree as NSString).appendingPathComponent(scratchPath)
        if manager.isReadableFile(atPath: scratch) { return scratchPath }

        do {
            try contents.write(toFile: scratch, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return scratchPath
    }

    /// Moves a copy an older Bloom left lying in `.bloom/pr-instructions.md` into the scratch
    /// folder, and answers its new path. Nil when the file stays where it is.
    ///
    /// Two conditions, both required, because getting this wrong destroys somebody's work. The
    /// file has to be byte for byte the default this app ships, which is what proves Bloom wrote
    /// it rather than a person; and it has to be untracked, which is what proves moving it is not
    /// a deletion in the user's diff.
    ///
    /// The tracked half is the important one. A repository that has already committed this file,
    /// which is exactly what the bug produced before it was found, keeps it: deleting a committed
    /// file would show up as a deletion in every workspace cut from that repository and would be
    /// committed by the next agent told to commit what it finds. Bloom does not undo what is
    /// already in somebody's history; it stops adding to it.
    private static func reclaimStrayDefault(at project: String, in worktree: String) async -> String? {
        guard let text = try? String(contentsOfFile: project, encoding: .utf8),
              isUnedited(text)
        else { return nil }
        guard await Git.isTracked(projectPath, in: worktree) == false else { return nil }

        WorktreeScratch.shield(WorktreeScratch.generated, in: worktree)
        let scratch = (worktree as NSString).appendingPathComponent(scratchPath)
        let manager = FileManager.default
        if manager.fileExists(atPath: scratch) {
            try? manager.removeItem(atPath: project)
            return scratchPath
        }
        guard (try? manager.moveItem(atPath: project, toPath: scratch)) != nil else { return nil }
        return scratchPath
    }

    /// Whether this text is one Bloom wrote and nobody has touched since.
    ///
    /// Byte for byte against every default this app has ever shipped, not a resemblance. A file
    /// somebody edited by one character is theirs, and the only safe way to tell the two apart is
    /// to require an exact match. `retiredDefaults` grows by one entry whenever `defaultMarkdown`
    /// is edited, which is the price of being able to recognise what older versions left behind.
    public static func isUnedited(_ text: String) -> Bool {
        text == defaultMarkdown || retiredDefaults.contains(text)
    }

    /// What `defaultMarkdown` used to say. Kept only so `isUnedited` can recognise a copy an
    /// older Bloom wrote into `.bloom/pr-instructions.md` before there was a scratch folder to
    /// put it in. Nothing renders these.
    public static let retiredDefaults: [String] = [
        """
        # Opening a pull request

        Bloom attaches this file when someone presses Create pull request. It is a normal file in this
        repository: edit it to say how this project opens pull requests, and everybody working here
        gets the change.

        The message this file came with names the branch to target. Call it the target branch below.

        - If this project has a skill or an instruction file about opening pull requests, follow that
          first. It outranks everything here.
        - Run `git status`. If anything is uncommitted, review it and commit it, following whatever
          this project says about commit messages.
        - Push the branch with `git push -u origin HEAD`. If it already tracks a different upstream,
          push to that one instead.
        - Read the whole branch with `git diff <target branch>...` before writing anything. The
          description has to cover every change on the branch, not only what was done in this session.
        - Open the pull request with `gh pr create --base <target branch> --title <title> --body
          <description>`. If the repository has a pull request template, fill that in instead of
          writing your own structure. Keep the title under 80 characters and the description under
          five sentences.
        - Say what the pull request URL is once it exists.

        If a step fails, stop and say what went wrong instead of working around it.
        """,
    ]

    /// What the file says until somebody edits it.
    ///
    /// It never names a branch. The branch to target is in the message the file is attached to,
    /// because the file is shared by every workspace in the repository and the target is not.
    ///
    /// The first paragraph says where the file is and how to adopt it, because a file git will not
    /// report is a file nobody will find by accident.
    public static let defaultMarkdown = """
    # Opening a pull request

    Bloom attaches this file when someone presses Create pull request. This copy is Bloom's own and
    is invisible to git. To make it this project's, move it to `.bloom/pr-instructions.md`, edit it
    to say how this project opens pull requests, and commit it. Bloom then uses that copy instead
    and never writes over it, so everybody working here gets the change.

    The message this file came with names the branch to target. Call it the target branch below.

    - If this project has a skill or an instruction file about opening pull requests, follow that
      first. It outranks everything here.
    - Run `git status`. If anything is uncommitted, review it and commit it, following whatever
      this project says about commit messages.
    - Push the branch with `git push -u origin HEAD`. If it already tracks a different upstream,
      push to that one instead.
    - Read the whole branch with `git diff <target branch>...` before writing anything. The
      description has to cover every change on the branch, not only what was done in this session.
    - Open the pull request with `gh pr create --base <target branch> --title <title> --body
      <description>`. If the repository has a pull request template, fill that in instead of
      writing your own structure. Keep the title under 80 characters and the description under
      five sentences.
    - Say what the pull request URL is once it exists.

    If a step fails, stop and say what went wrong instead of working around it.
    """
}
