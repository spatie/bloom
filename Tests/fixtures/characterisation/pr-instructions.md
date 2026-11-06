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