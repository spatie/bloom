import Foundation

/// How this project lands a pull request, as a file in the repository.
///
/// Pressing Merge does not call `gh`. It composes a turn and sends it, exactly as if the user had
/// typed it, with this file attached. The same arrangement `PullRequestInstructions` already made
/// for opening one, and for the same reasons plus one that only applies here: merging is the one
/// destructive, off-machine thing this app offers, and an agent doing it in the transcript is an
/// agent whose command the reader can see, whose permission prompt the reader answers, and whose
/// refusal the reader is told about in words. `gh pr merge` fired from a button reported a shell
/// error into a notice and nothing else.
///
/// The instructions are a FILE rather than a string buried in the app, so a project that merges
/// differently, and plenty do, changes this file and everybody working in that repository gets the
/// change. The two paths mean the same as they do for pull request creation:
///
/// - `.bloom/merge-instructions.md` is the PROJECT's. If it exists it wins, tracked or not, and
///   nothing here ever writes it, edits it or deletes it.
/// - `.bloom/scratch/merge-instructions.md` is BLOOM's, written on demand from the default below
///   so nobody has to author one before the button works. It sits in a shielded folder
///   (`WorktreeScratch`), so git cannot see it and no agent can commit it.
///
/// There is no reclaim step here, and its absence is deliberate rather than an omission. The one
/// `PullRequestInstructions` carries exists to pick up copies an older Bloom wrote into the
/// project's own path before there was a scratch folder to put them in. This file has never been
/// written anywhere but the scratch folder, so there is nothing to pick up, and code that moves
/// somebody's file about with no bug behind it is code that will one day move the wrong one.
public enum MergeInstructions {
    /// The project's own copy, if it has one. Relative to the worktree, because that is where the
    /// agent is standing and a path inside the worktree is one it may read without asking.
    public static let projectPath = ".bloom/merge-instructions.md"

    /// Where Bloom writes the default when the project has no copy of its own.
    public static let scratchPath = "\(WorktreeScratch.generated)/merge-instructions.md"

    /// Makes sure a copy exists in this worktree, and answers where it is.
    ///
    /// Nil when nothing could be written, which is the caller's signal to put the instructions in
    /// the message itself rather than to fail. A read-only checkout is a reason to fall back, not
    /// a reason for a button to stop working.
    ///
    /// The path that comes back is a file that was on disk and readable at the moment of
    /// answering, which is the same contract `PullRequestInstructions.ensure` holds: a path in a
    /// turn is a promise to the agent that it can read what it names.
    public static func ensure(in worktree: String, contents: String = defaultMarkdown) -> String? {
        guard let path = choose(in: worktree, contents: contents) else { return nil }
        return InstructionFile.isFile(path, in: worktree) ? path : nil
    }

    /// The turn that carries the file, with the path in the sentence that asks for it.
    public static func asking(_ text: String, toFollow path: String) -> String {
        InstructionFile.asking(text, toFollow: path)
    }

    private static func choose(in worktree: String, contents: String) -> String? {
        if InstructionFile.isFile(projectPath, in: worktree) { return projectPath }

        WorktreeScratch.shield(WorktreeScratch.generated, in: worktree)
        if InstructionFile.isFile(scratchPath, in: worktree) { return scratchPath }

        let scratch = (worktree as NSString).appendingPathComponent(scratchPath)
        guard (try? contents.write(toFile: scratch, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return scratchPath
    }

    /// What the file says until somebody edits it.
    ///
    /// It names no pull request, no branch and no method. All three are in the message this file
    /// is attached to, because the file is shared by every workspace in the repository and none of
    /// the three is.
    ///
    /// Every line here is written for a reader that is about to run a command that changes a
    /// server. The three that matter most, and that no shorter version may lose: the merge and the
    /// branch deletion are separate commands in that order, a refusal from GitHub is an answer
    /// rather than an obstacle, and nothing on this machine is touched.
    public static let defaultMarkdown = """
    # Merging a pull request

    Bloom attaches this file when someone presses Merge. This copy is Bloom's own and is invisible
    to git. To make it this project's, move it to `.bloom/merge-instructions.md`, edit it to say
    how this project merges, and commit it. Bloom then uses that copy instead and never writes
    over it, so everybody working here gets the change.

    The message this file came with names the pull request, the branch it is on, and the merge
    method to use. Nothing here chooses any of those, and nothing here may change them.

    - If this project has a skill or an instruction file about merging, follow that first. It
      outranks everything here.
    - Merge with `gh pr merge <number> <method flag>`, run from this worktree, where the method
      flag is the one the message names: `--squash`, `--merge` or `--rebase`.
    - Pass no other flags.
      Not `--admin`, which overrides the repository's own rules.
      Not `--auto`, which merges later, when nobody is watching.
      Not `--delete-branch`, which makes gh reach for this checkout and fail, because a worktree
      cannot check out the branch the main copy is standing on.
    - **If GitHub refuses the merge, stop.** Say what it said, in its own words. Do not retry it,
      do not force it, and do not change a branch protection rule, a required check, a review or
      any other repository setting to get round it. A refusal is an answer, and the person who
      pressed the button is reading this.
    - Only once the merge has actually succeeded, delete the branch on the server with
      `git push --delete -- origin refs/heads/<branch>`, using the branch the message names. If
      git answers that the remote ref does not exist, the repository deleted it on merge and there
      is nothing left to do. This is a separate command from the merge and it runs second, never
      instead.
    - Change nothing on this machine. Do not delete the local branch, do not remove or move the
      worktree, and do not check out anything else. This worktree stays where it is, on the branch
      it is on, and Bloom archives it separately when the person asks.
    - Do not commit and do not push. If the worktree is holding work GitHub has not got, that was
      the reader's decision before pressing the button, not a thing to fix. Say in one line that it
      was left behind.
    - Finish by saying what happened: that it merged, and whether the branch on the server is gone.

    If a step fails, stop and say what went wrong instead of working around it.
    """
}
