# Opening a merge request

Bloom attaches this file when someone presses Create merge request. This copy is Bloom's own and
is invisible to git. To make it this project's, move it to `.bloom/pr-instructions.md`, edit it
to say how this project opens merge requests, and commit it. Bloom then uses that copy instead
and never writes over it, so everybody working here gets the change.

The message this file came with names the branch to target. Call it the target branch below.

- If this project has a skill or an instruction file about opening merge requests, follow that
  first. It outranks everything here.
- Run `git status`. If anything is uncommitted, review it and commit it, following whatever
  this project says about commit messages.
- Push the branch with `git push -u <remote> HEAD`, where `<remote>` is the remote
  `git remote -v` lists on GitLab, usually `origin`. If it already tracks a different
  upstream on GitLab, push to that one instead.
- Read the whole branch with `git diff <target branch>...` before writing anything. The
  description has to cover every change on the branch, not only what was done in this session.
- Open the merge request with `glab mr create --target-branch <target branch> --title <title>
  --description <description> --yes`. If the repository has a merge request template, fill that in instead of
  writing your own structure. Keep the title under 80 characters and the description under
  five sentences.
- Say what the merge request URL is once it exists.

If a step fails, stop and say what went wrong instead of working around it.