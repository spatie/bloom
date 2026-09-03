import Foundation

/// How Bloom resolves a merge conflict, as a file in the worktree rather than as eight paragraphs
/// in the chat.
///
/// Pressing Fix merge conflicts does not run git. It composes a turn and sends it, exactly as if
/// the user had typed it, and until now that turn carried the whole procedure inline: fetch the
/// base, work through every conflicted file, commit, push with `--force-with-lease`, and when not
/// to push at all. Beside a Create pull request turn, which is one sentence and a path, it read as
/// a wall of text nobody was going to reread. The steps are in a file now and the message names it,
/// which is the arrangement `PullRequestInstructions` already made for opening one.
///
/// **This is deliberately the opposite call to the one merging took.** `MergeInstructions` used to
/// be a file and was moved back into the message, because a reader watching an agent about to
/// change a server has to see what it was told without opening anything, and because those words
/// are the same on every press. Both halves of that argument are weaker here. Nothing in this turn
/// touches a server, so what the reader needs from the transcript is what was asked for rather than
/// how it is done; and the steps are long enough that leaving them inline is what actually stopped
/// them being read. What the message keeps is the record: which pull request, which two branches,
/// and that the pull request is not to be merged.
///
/// **The file is Bloom's, and it is rewritten on every press.** It sits in the shielded folder
/// (`WorktreeScratch`), so git cannot see it and an agent told to commit what it finds cannot
/// commit it. It is not a customisation point and says so in its own first paragraph: editing the
/// copy in a worktree is an edit that is overwritten by the next press and thrown away with the
/// worktree. The two routes that do last are `PromptRegistry.fixConflicts`, which is the message,
/// and `.bloom/conflict-instructions.md` or the project settings field, which is `ProjectInstructions`
/// and which is attached after this and outranks it.
///
/// Rewritten rather than kept, for the reason `ProjectInstructions.spill` is: `PullRequestInstructions`
/// may keep its copy because that copy is a constant, where this one is written from whatever the
/// caller handed in, and a kept copy would be an agent following a wording that had already changed.
public enum ConflictInstructions {
    /// Where Bloom writes the steps.
    ///
    /// Deliberately not `conflict-instructions.md`: `ProjectInstructions.scratchPath(for:)` already
    /// owns that name in this same folder, for the project's settings field spilled out as a file.
    /// Two writers on one path would have each press overwrite the other's file and point both
    /// sentences at whichever won.
    public static let scratchPath = "\(WorktreeScratch.generated)/resolving-conflicts.md"

    /// The turn that carries the steps, with the path in the sentence that asks for it.
    ///
    /// When nothing can be written, which a read-only checkout is, the steps go into the message
    /// itself. That is the wall of text this type exists to avoid, and it is still the right answer
    /// in that case: a button that stops working is worse than a long message. Same fallback as
    /// `WorkspaceModel.pullRequestTurn` and `ProjectInstructions.Extra.inline`.
    public static func asking(
        _ text: String, in worktree: String, contents: String = defaultMarkdown
    ) -> String {
        guard let path = ensure(in: worktree, contents: contents) else {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? contents : "\(body)\n\n\(contents)"
        }
        return InstructionFile.asking(text, toFollow: path)
    }

    /// Writes the steps into the shielded folder and answers where they are, or nil when nothing
    /// could be written.
    ///
    /// The path that comes back is a file that was on disk and readable at the moment of answering.
    /// That is the contract every path Bloom writes into a turn holds: a path in a turn is a
    /// promise to the agent that it can read what it names.
    public static func ensure(in worktree: String, contents: String = defaultMarkdown) -> String? {
        WorktreeScratch.shield(WorktreeScratch.generated, in: worktree)
        let full = (worktree as NSString).appendingPathComponent(scratchPath)
        guard (try? contents.write(toFile: full, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return InstructionFile.isFile(scratchPath, in: worktree) ? scratchPath : nil
    }

    /// What the file says.
    ///
    /// It names no branch and no pull request. All three are in the message the file is attached
    /// to, because the steps are the same in every workspace and the facts are not, which is the
    /// same split `PullRequestInstructions.defaultMarkdown` and `MergeInstructions.canonical` are
    /// on the right side of.
    ///
    /// The three lines that no shorter version may lose, because each of them is a way this turn
    /// can make somebody's day worse: the base goes into this branch and never the other way round,
    /// a force push may only ever reach this branch, and an agent that is guessing stops instead of
    /// pushing.
    public static let defaultMarkdown = """
    # Resolving merge conflicts

    Bloom attaches this file when someone presses Fix merge conflicts. This copy is Bloom's own, is
    rewritten on every press and is invisible to git, so an edit made here does not last. To change
    what this project does about conflicts, write it in `.bloom/conflict-instructions.md` and commit
    it: Bloom attaches that as well, and where the two disagree yours wins. The message these steps
    arrived with is a prompt you can reword in Bloom's settings.

    That message names the pull request, the branch this worktree is on, and the branch that
    conflicts with it. Call the second one this branch and the third the base branch below.

    - If this project has a skill or an instruction file about resolving conflicts, follow that
      first. It outranks everything here.
    - Fetch the base branch first, so you are working against what is on the server rather than a
      stale copy of it.
    - Bring the base branch into this branch the way this project brings it in: merge it unless
      the project's own conventions say to rebase onto it.
      It goes into this branch and never the other way round.
    - Work through every conflicted file. Keep what this branch changed and what the base branch
      changed, and where the two genuinely disagree, read enough of the code around them to work out
      which is right instead of taking a side.
    - Follow this project's conventions, and run whatever it uses to check itself before you call
      anything resolved.
    - Commit the resolution, with a message worded the way this project words one.
    - Then push it. A conflict resolved only in this worktree is still a conflict to everybody else,
      and the pull request goes on refusing to merge until the branch on the server carries the
      resolution. If bringing the base branch in rewrote this branch's commits, which a rebase does,
      the push needs `--force-with-lease`, and it may only ever go to this branch, never to the base
      branch and never to any other branch.
    - **Do not push if you are not sure.** Genuine uncertainty about what a resolution should be, a
      check that fails for a reason neither branch explains, or anything you had to guess at: leave
      the commit here, say what you are unsure about, and let a person look. A resolution nobody
      believes in is worse on the server than in a worktree.
    - Do not merge the pull request whatever happens. Whether the work is good is the reader's
      decision, and they are the one who pressed the button.
    - Finish by saying which files conflicted, what you decided in each of them, whether you pushed,
      and anything you are not sure about.

    If a step fails, stop and say what went wrong instead of working around it.
    """
}
