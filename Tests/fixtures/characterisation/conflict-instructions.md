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