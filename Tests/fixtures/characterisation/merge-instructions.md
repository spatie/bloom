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