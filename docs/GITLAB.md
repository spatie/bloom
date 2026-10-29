# GitLab

Bloom speaks to GitLab through `glab`, the GitLab CLI, the way it speaks to GitHub through `gh`. A
project on GitLab gets the merge request strip, its pipeline's jobs, a failed job's log handed to
the agent, create and merge directly or through the agent, ready and rebase, and workspaces started
from a merge request, in GitLab's own words. Checked against `glab` 1.92.1 and the REST API v4.

The rule every part of it follows: **nothing changes for a project on GitHub.** The deliberate
exceptions are the onboarding checks screen, which shows an optional "GitLab CLI" row to everybody
and never changes the verdict or its sentence, and Settings > GitHub & GitLab, which took the
GitHub account row out of Agents.

## Which forge a project uses

`ForgeRouting.decide`, applied to a directory by `ForgeResolver`. First match wins:

| Situation | Forge |
|---|---|
| `git.forge = "github"` or `"gitlab"` in a settings file | as stated |
| Any remote on a host containing `github` (github.com, Enterprise, an SSH alias) | GitHub |
| Base remote on gitlab.com | GitLab |
| Another host, `glab` installed and `glab auth status --hostname <host>` succeeds | GitLab |
| Anything else, including no remote | GitHub |

A project added with a GitHub remote and a GitLab one (gitlab.com, or a host `glab` is signed in
to) and no `git.forge` is asked which forge it uses. The answer is written as `git.forge` to
`.bloom/settings.local.toml` in the project's checkout, which every workspace reads: remotes are
this machine's git config, so the answer is not committed for the team. "Not now" writes nothing: the
table above stays in charge, so GitHub, and the question comes back the next time the folder is
added.

The answer is cached per directory until git's config or a settings file is written, or for five
minutes when it is GitHub only because `glab` said no. Where the
config file's own text settles it, which is every GitHub remote and every machine without `glab`,
no process runs at all. The `glab` probe runs at most once per host at a time, a yes is kept for
the launch and a no for five minutes.

## What runs

Reads go through `glab api --hostname <host>` against the REST API, naming the project rather
than letting `glab` guess it from the remotes. The project is the base remote's when that is on
GitLab, else the GitLab remote beside it, gitlab.com and hosts `glab` is signed in to first, so a
GitLab project mirrored to a GitHub `origin` is read, checked out, pushed to and merged through
its GitLab remote. `GitLabReads` shares them: one read in flight per
workspace, `maxAge` honoured as on GitHub, and the jobs of a finished pipeline read once.

| Need | Call |
|---|---|
| Merge requests from a branch | `projects/<path>/merge_requests?source_branch=<branch>&state=all` |
| One merge request | `projects/<path>/merge_requests/<iid>` |
| Its pipeline's jobs | `projects/<head_pipeline.project_id>/pipelines/<id>/jobs`, the source project for a fork |
| A failed job's log | `projects/<job's project>/jobs/<id>/trace` |
| Mark ready | `glab mr update <iid> --ready -R <project URL>` |
| Workspace from a merge request | `glab mr checkout <iid> --branch <name> -R <project URL>` |

Creating and merging offer the same two routes as on GitHub, the agent or Bloom itself, and
merging directly is the default. Rebasing and resolving conflicts are turns sent to the agent. The
agent's steps are `GitLabInstructions`; the direct ones are in `GitLab`:

| Direct route | Call |
|---|---|
| Create | `glab mr create --source-branch <branch> --target-branch <base> --title <title> --description <commits> --yes -R <project URL>`, after Bloom commits and pushes, setting the branch's `pushRemote` to the GitLab remote if pushes would go elsewhere |
| Merge | `glab mr merge <iid> --yes --auto-merge=false --sha <head> [--squash] -R <project URL>` |
| Rebase merge | `glab mr rebase <iid>` first, then the merge above at the new head |

Without `--auto-merge=false` glab sets "merge when the pipeline succeeds" instead of merging.
glab's own `--rebase` rebases and then GitLab refuses the `--sha` it was given, because the head
has moved, so neither route uses it. The direct rebase merge goes ahead only if the rebased branch
has as many commits as the confirmed one and holds exactly the tree `git merge-tree` gives for the
confirmed head on the new base. Bloom fetches `refs/merge-requests/<iid>/head` from the GitLab
remote to compare them, so a push with the same titles and other contents is refused, and a target
that changed a line beside a confirmed change is not. The description is what `gh pr create --fill`
writes: one commit's body, or the subjects of several. Not glab's `--fill`, which pushes again.

A merge request is found by its source branch, which GitLab keeps after the branch is deleted, and
otherwise by the number on the workspace row, as on GitHub: written when a workspace is opened from
a merge request and when one is first found. A fork's merge request is only ever found by that
number, because `glab mr checkout` tracks the fork's branch under a local name GitLab does not know,
and the same number keeps a branch renamed after its merge request was found. A project that moves
to the other forge, through the question when it is added or through "Hosted on", forgets these
numbers, which the other forge would read as its own.

## What GitLab says that GitHub has no word for

`detailed_merge_status` becomes `PullRequest.blockers`: waiting for approval, unresolved threads,
needs rebase, pipeline must pass, and so on. Any blocker turns the merge button off with GitLab's
reason, and an unknown status is read as a refusal, never as mergeable. Needs rebase offers Rebase.
The GitHub decoder never fills `blockers`.

## Settings

- Settings > GitHub & GitLab, shown with or without either CLI: the account each is signed in as,
  per host for `glab`, and the sign in sheet to install it with Homebrew, sign in, sign in again,
  or switch account with `gh auth switch`. `glab` keeps one account per host, so switching there
  is signing in again as the other one.
- `git.forge`, in the project's settings screen as "Hosted on" when `glab` is installed.
- `git.branch_prefix_type = "gitlab_username"`, the user `glab` is signed in as on the project's
  host, read once per launch from `glab auth status` and again after a sign in.
- Prompt overrides for GitLab live under `prompts.gitLab.<id>`, edited from the GitLab side of the
  prompt settings. A GitHub override never reaches a GitLab project; prompts with no GitLab
  variant are shared.
- `.bloom/pr-instructions.md` and the other instruction files are shared: they are the team's own
  words, and a project uses one forge.

## What stays GitHub's

Creating a repository, the onboarding verdict, the `gh` row and its sign in, App Intents
identifiers, the sidebar legend (it is not about one project), and the tool descriptions an agent
outside a GitLab workspace sees.

## Tests

`Tests/fixtures/gitlab` holds real REST answers from gitlab.com (`gitlab-org/cli`, 2026-10-08),
trimmed to the fields Bloom reads and with authors anonymised. The texts an agent is told on
GitLab are pinned under `Tests/fixtures/characterisation/gitlab-*`, beside GitHub's.
