import Foundation

/// How Bloom lands a pull request, in the words the agent reads.
///
/// Pressing Merge does not call `gh`. It composes a turn and sends it, exactly as if the user had
/// typed it. The same arrangement `PullRequestInstructions` already made for opening one, and for
/// the same reasons plus one that only applies here: merging is the one destructive, off-machine
/// thing this app offers, and an agent doing it in the transcript is an agent whose command the
/// reader can see, whose permission prompt the reader answers, and whose refusal the reader is
/// told about in words. `gh pr merge` fired from a button reported a shell error into a notice and
/// nothing else.
///
/// **These words used to be a file, and are not one any more.** Every press wrote them into
/// `.bloom/scratch/merge-instructions.md` and attached that back, so the turn could say "follow
/// the instructions in that file". They are the same on every press and in every repository, so
/// the write bought nothing, and it cost the reader of the transcript the ability to see what the
/// agent had been told about a command that changes a server without opening a file git will not
/// report. What a project has to add on top of them is the part that varies, and that is what is
/// attached now. See `ProjectInstructions`.
///
/// They are a constant here rather than the merge prompt's `defaultTemplate` for the one reason
/// that matters at a merge: a prompt is editable in Settings, and a person who reworded the
/// sentence naming the pull request would otherwise have deleted the paragraph saying not to pass
/// `--admin`. The template carries the four facts; this carries the rules.
public enum MergeInstructions {
    /// What the agent is told, on every merge, in every repository.
    ///
    /// It names no pull request, no branch and no method. All three are in the sentence above it,
    /// because they belong to one workspace and these rules belong to none.
    ///
    /// Every line here is written for a reader that is about to run a command that changes a
    /// server. The three that matter most, and that no shorter version may lose: the merge and the
    /// branch deletion are separate commands in that order, a refusal from GitHub is an answer
    /// rather than an obstacle, and nothing on this machine is touched.
    public static let canonical = """
    This message names the pull request, the branch it is on, and the merge method to use. Nothing
    below chooses any of those, and nothing below may change them.

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
