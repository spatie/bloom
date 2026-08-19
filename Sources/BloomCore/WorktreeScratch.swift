import Foundation

/// The folders Bloom writes into inside somebody else's checkout, and the one rule about them:
/// git must be blind to every one.
///
/// `.bloom` itself is meant to be committed. `settings.toml`, `setup.sh` and the rest are what a
/// team shares, and that is the whole point of the folder. But Bloom also has to put working
/// files where the agent can read them, which on this platform means inside the worktree: an
/// agent will not read a path outside its working directory without asking, and Bloom has nothing
/// that can answer that question. So Bloom's scratch lives in the user's checkout by necessity,
/// and it has to be provably unable to get out of there.
///
/// Provably, because the thing on the other side of it is an agent that has been told to commit
/// what it finds. Bloom's own pull request instructions say "Run `git status`. If anything is
/// uncommitted, review it and commit it", and an untracked file in the worktree is something an
/// agent obeying that will pick up. It did: `.bloom/pr-instructions.md` was written next to the
/// user's work, was covered by no ignore rule, and landed in a real pull request. On the pull
/// request before it the same agent happened to name its paths and missed it, which is worse than
/// failing every time.
///
/// The shield is a `.gitignore` containing `*` inside the folder itself, and it is what makes the
/// answer provable rather than likely. That file ignores every path beside it, itself included,
/// so there is nothing for git to report: `status` is clean, `add -A` and `add .` add nothing,
/// `commit -a` commits nothing, and `ls-files --others --exclude-standard`, which is where
/// Bloom's own changed file list comes from, does not list it. An agent cannot commit what git
/// will not name.
///
/// Deliberately NOT `.git/info/exclude`: a linked worktree shares that file with the repository it
/// was forked from, so writing there would edit the user's main checkout to hide Bloom's scratch.
/// Deliberately NOT a line appended to `.bloom/.gitignore` either: in a repository that already
/// commits `.bloom`, that file is tracked, and editing it would show up as a modified tracked
/// file in the user's diff. That is the same bug wearing different clothes.
///
/// Every scratch folder is local to itself, so removing the folder removes every trace of the
/// arrangement and `git worktree remove` still works without `--force`.
public enum WorktreeScratch {
    /// Copies of files somebody dropped, pasted or picked into a prompt.
    public static let attachments = ".bloom/attachments"

    /// Files Bloom generates for its own use, that no project asked for and no reviewer wants to
    /// read: the default pull request instructions, and whatever comes after them.
    public static let generated = ".bloom/scratch"

    /// Every folder covered by the rule. The list exists so a test can walk it, which is the only
    /// way a folder added later cannot quietly go unshielded.
    public static let folders = [attachments, generated]

    /// Whether a path relative to the worktree lies in one of them.
    ///
    /// Pure, and asserted on directly. Anything Bloom writes into a worktree that this says no
    /// about is a file that can reach a commit.
    public static func isShielded(_ path: String) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Makes one scratch folder exist and makes git blind to it.
    ///
    /// Safe to call every time something is written: the ignore file is written once and never
    /// rewritten, so a user who edited it keeps their edit.
    public static func shield(_ folder: String = attachments, in worktree: String) {
        let full = (worktree as NSString).appendingPathComponent(folder)
        let ignore = (full as NSString).appendingPathComponent(".gitignore")
        let manager = FileManager.default
        guard !manager.fileExists(atPath: ignore) else { return }
        // `.bloom` itself is created as a side effect and deliberately left bare. Its own
        // `.gitignore` is a file the team commits, and writing one here would put a file in the
        // user's pull request that they did not ask for, which is the bug this type exists to
        // stop. `SettingsWriter.prepareFolder` still lays it down the first time somebody writes
        // a setting, whether or not `.bloom` already exists by then.
        try? manager.createDirectory(atPath: full, withIntermediateDirectories: true)
        try? "*\n".write(toFile: ignore, atomically: true, encoding: .utf8)
    }
}
