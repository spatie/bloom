import Foundation

/// How this project opens a pull request, as a file in the repository.
///
/// Pressing Create pull request does not call `gh`. It composes a turn and sends it, exactly as if
/// the user had typed it, with this file attached. The agent is already authenticated, already
/// standing in the worktree and already knows what it changed, so it can write a real description
/// instead of Bloom guessing one, and the whole request lands in the transcript where it can be
/// read, corrected and sent again.
///
/// The instructions are a FILE rather than a string buried in the app, for the same reason setup
/// scripts became `.bloom/setup.sh`: a program belongs somewhere it can be read, edited, diffed
/// and shared with the team. A project that opens pull requests differently changes this file, and
/// everybody working in that repository gets the change. It lives in `.bloom`, which is Bloom's
/// corner of a repository and is meant to be committed. See `SettingsWriter.prepareFolder`.
///
/// It is written on demand from the default below, so nobody has to author one before the button
/// works. Nothing ever rewrites a file that is already there: once it exists it belongs to the
/// project, not to this app.
public enum PullRequestInstructions {
    /// Where it lives, relative to the worktree. Relative because that is where the agent is
    /// standing, and because a path inside the worktree is one the agent may read without asking.
    public static let path = ".bloom/pr-instructions.md"

    /// Makes sure the file exists in this worktree, and answers where it is.
    ///
    /// Nil when it could not be written, which is the caller's signal to put the instructions in
    /// the message itself rather than to fail. A read-only checkout is a reason to fall back, not
    /// a reason for a button to stop working.
    public static func ensure(in worktree: String, contents: String = defaultMarkdown) -> String? {
        let full = (worktree as NSString).appendingPathComponent(path)
        let manager = FileManager.default
        if manager.isReadableFile(atPath: full) { return path }

        SettingsWriter.prepareFolder(for: full, repo: worktree)
        // Belt and braces: `prepareFolder` only makes the folder while it is creating it for the
        // first time, and this file may be the first thing written into a `.bloom` that some
        // other part of the app already made.
        try? manager.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )

        do {
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return path
    }

    /// What the file says until somebody edits it.
    ///
    /// It never names a branch. The branch to target is in the message the file is attached to,
    /// because the file is shared by every workspace in the repository and the target is not.
    public static let defaultMarkdown = """
    # Opening a pull request

    Bloom attaches this file when someone presses Create pull request. It is a normal file in this
    repository: edit it to say how this project opens pull requests, and everybody working here
    gets the change.

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
    """
}
