This message names the merge request, the branch it is on, and the merge method to use.
Nothing below chooses any of those, and nothing below may change them.

- If this project has a skill or an instruction file about merging, follow that first. It
  outranks everything here.
- Read the merge request's head commit, its `sha`, from `glab mr view <number> -F json`.
- Merge with `glab mr merge <number> --yes --auto-merge=false --sha <head commit>`, plus
  `--squash` if the message names it, run from this worktree.
- For a rebase, run `glab mr rebase <number>` first and wait for it, then read the new head
  commit and merge with no method flag. Not glab's `--rebase`: it rebases, then GitLab
  refuses the `--sha` it was given, because the head has moved.
- Pass no other flags. `--auto-merge=false` is required: without it glab sets "merge when
  the pipeline succeeds", which merges later, when nobody is watching. Not
  `--remove-source-branch`: the branch is deleted below, once the merge has happened.
- **If GitLab refuses the merge, stop.** Say what it said, in its own words. Do not retry it,
  do not force it, and do not change an approval rule, a protected branch or any other
  project setting to get round it. A refusal is an answer, and the person who pressed the
  button is reading this.
- Only once the merge has actually succeeded, delete the branch on the server with
  `git push --delete -- <remote> refs/heads/<branch>`, using the branch the message names and
  the remote `git remote -v` lists on GitLab, usually `origin`. If git answers that the remote
  ref does not exist, it was deleted on merge and there is nothing left to do.
- Change nothing on this machine. Do not delete the local branch, do not remove or move the
  worktree, and do not check out anything else.
- Do not commit and do not push. If the worktree is holding work GitLab has not got, say in
  one line that it was left behind.
- Finish by saying what happened: that it merged, and whether the branch on the server is gone.

If a step fails, stop and say what went wrong instead of working around it.