import Foundation

/// What Bloom tells an agent on a GitLab project: GitHub's texts in GitLab's words, so the two
/// cannot drift, except where the commands differ. GitHub's own defaults are never edited.
public enum GitLabInstructions {
    /// Not `pr-instructions.md`, which a worktree may already hold with GitHub's steps in it.
    public static let mergeRequestScratchPath = "\(WorktreeScratch.generated)/mr-instructions.md"

    public static var mergeRequestMarkdown: String {
        translate(PullRequestInstructions.defaultMarkdown).replacingOccurrences(
            of: "`gh pr create --base <target branch> --title <title> --body\n  <description>`",
            with: "`glab mr create --target-branch <target branch> --title <title>\n  --description <description> --yes`"
        ).replacingOccurrences(
            of: "Push the branch with `git push -u origin HEAD`. If it already tracks a different upstream,\n  push to that one instead.",
            with: "Push the branch with `git push -u <remote> HEAD`, where `<remote>` is the remote\n"
                + "  `git remote -v` lists on GitLab, usually `origin`. If it already tracks a different\n"
                + "  upstream on GitLab, push to that one instead."
        )
    }

    public static var conflictMarkdown: String { translate(ConflictInstructions.defaultMarkdown) }

    public static let merge = """
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
    """

    /// The built-in template for a GitLab project, or nil to use GitHub's as it stands.
    public static func defaultTemplate(for id: PromptID) -> String? {
        switch id {
        case .mergePullRequest:
            "Merge merge request !{{number}} into {{base_branch}} as a {{method}} ({{method_flag}}). "
                + "It is on the branch {{branch}}."
        case .createPullRequest, .pushLocalWork, .fixConflicts, .continueAfterMerge:
            translate(PromptRegistry.definition(for: id).defaultTemplate)
        case .carryOnArchived, .review, .nameWorkspace:
            nil
        }
    }

    /// The merge method as the GitLab template names it. Merge is no flag at all: the project's
    /// own method, whether that is a merge commit, semi-linear or fast forward.
    public static func flag(for method: GitHub.MergeMethod) -> String {
        switch method {
        case .merge: "no method flag, the project's own merge method"
        case .squash: "`--squash`"
        case .rebase: "`glab mr rebase` first, then no method flag"
        }
    }

    /// A tool as an agent in a GitLab workspace is told about it: the same tool and schema, with
    /// every description in GitLab's words. Field names, such as `include_github`, do not move.
    public static func listing(of tool: BridgeTool) -> JSONValue {
        describedForGitLab(tool.listing)
    }

    private static func describedForGitLab(_ value: JSONValue, key: String? = nil) -> JSONValue {
        switch value {
        case .string(let text) where key == "description":
            return .string(translate([
                // `#123` stays: it works on both forges, and a start may target a GitHub project.
                ("`gh pr merge`", "`glab mr merge`"), ("gh call", "glab call"),
            ].reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }))
        case .object(let fields):
            return .object(fields.reduce(into: [:]) { $0[$1.key] = describedForGitLab($1.value, key: $1.key) })
        case .array(let items):
            return .array(items.map { describedForGitLab($0) })
        default:
            return value
        }
    }

    static func translate(_ text: String) -> String {
        [
            ("Pull request #", "Merge request !"), ("pull request #", "merge request !"),
            ("Pull request", "Merge request"), ("pull request", "merge request"),
            ("Pull Request", "Merge Request"), ("GitHub", "GitLab"),
        ].reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}
