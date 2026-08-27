import Foundation

/// Where a CLI is started when there is no workspace for it to stand in.
///
/// Five asks run with no project behind them: the two quota readers in `QuotaAsk`, the Codex model
/// catalogue, the automatic namer, and the sign-in terminal on the welcome window. None of them
/// opens a file in the folder it is standing in, so none of them needs a directory at all, and
/// four of the five were passing `NSHomeDirectory()`.
///
/// **Standing in `~` is not free, because the child is not Bloom.** macOS attributes what a
/// subprocess touches to the responsible application, so anything the CLI reads there is asked for
/// in Bloom's name, and the user is asked about it by a system prompt naming Bloom. Both agent CLIs
/// treat their working directory as the project they have been pointed at: Claude Code runs the
/// user's `SessionStart` hooks in it, measured on 27 August 2026 against 2.1.246, and both look
/// upwards from it for their own configuration. What either of them does with a directory is
/// theirs to decide and changes between releases, which is the point: the first thing a fresh
/// Bloom did, before it had been shown a single project, was name the user's home directory as the
/// place for a coding agent to work, once at launch and again every ten minutes.
///
/// **`WorkspaceNamer` already decided this once, for one of the five.** Its `scratchDirectory` had
/// the same folder under the same reasoning, in its own words: "Not the worktree and not the home
/// directory ... the cheapest way to be sure a naming call cannot see a user's code is to run it
/// where there is none." That was right, and the four callers that never heard about it are what
/// this type exists to stop. `Tools/house-rules.sh` holds the rule now, so the fifth caller is
/// caught by `make lint` rather than by somebody reading a default argument.
///
/// **Under the temporary directory rather than beside the database, and that is the load bearing
/// part.** Both are empty, so what separates them is what is above them. A CLI that walks upwards
/// looking for configuration walks `~/Library/Application Support/Bloom`, `~/Library` and then `~`
/// out of the one, and `/var/folders/…/T/` out of the other, which passes through nothing of the
/// user's at all.
public enum AgentScratchDirectory {
    /// The folder's name. Prefixed, because the temporary directory is shared with everything else
    /// on this Mac and an unqualified `agent-scratch` in there says nothing about whose it is.
    public static let folderName = "bloom-agent-scratch"

    /// The path this folder has inside a given directory. Pure, so the suite can ask about a
    /// machine that is not the one running it.
    public static func path(in base: String) -> String {
        (base as NSString).appendingPathComponent(folderName)
    }

    /// The folder inside `base`, made if it is not there yet.
    ///
    /// Made on every ask rather than once at launch, because macOS reaps the per-user temporary
    /// directory on its own schedule and a folder that was there when the app started is not
    /// necessarily there ten minutes later. Creating it is one syscall against a spawn.
    ///
    /// A base that cannot be written into falls back to `base` itself, and never to the home
    /// directory: a Mac where a folder cannot be made in the temporary directory is broken in ways
    /// this is not the place to report, and standing one level higher is still not standing in `~`.
    public static func make(in base: String) -> String {
        let directory = path(in: base)
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
            return directory
        } catch {
            return base
        }
    }

    /// The one on this machine.
    public static func current() -> String {
        make(in: NSTemporaryDirectory())
    }
}
