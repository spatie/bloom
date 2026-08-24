import Foundation

/// Which shell Bloom starts, and what it calls it.
///
/// Two places decided this independently and identically: the pty `TerminalView` launches, and
/// the tmux configuration `TerminalPersistence` writes. Each read `SHELL`, each fell back to
/// `/bin/zsh` twice over, and neither knew about the other. The day one of them learns something
/// the other does not, an empty `SHELL`, a login flag, a shell that is a symlink, the difference
/// is invisible until somebody's `.zprofile` stops running in one of the two terminals Bloom
/// offers and not the other.
///
/// The environment and the executable test are parameters so this can be asserted on without the
/// answer depending on the machine running the suite.
public enum LoginShell {
    /// Where it lands when `SHELL` says nothing usable. macOS's own default since Catalina, and
    /// the one shell that is on every supported system.
    public static let fallback = "/bin/zsh"

    /// The shell to run.
    ///
    /// Empty is not a path. `SHELL=""` used to survive the `??`, which only catches a missing
    /// key, and then fail the executable test, so the shell was right and the name derived from
    /// it was not: see `argumentZero(for:)` and the bug it fixes.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        guard let named = environment["SHELL"], !named.isEmpty, isExecutable(named) else {
            return fallback
        }
        return named
    }

    /// `argv[0]` for a login shell, which is its name with a dash in front. That leading dash is
    /// the whole convention: it is what makes bash read `.bash_profile` and zsh read `.zprofile`,
    /// so a terminal that gets it wrong is one where the user's own setup silently did not run.
    ///
    /// Taken from the resolved path rather than from `SHELL` directly, which is the bug this
    /// exists to close. `TerminalView` tested the path for executability and fell back, then
    /// named the shell from the value it had just rejected: a machine with a stale `SHELL`
    /// pointing at a removed homebrew fish would run `/bin/zsh` under the name `-fish`.
    public static func argumentZero(for path: String) -> String {
        "-" + (path as NSString).lastPathComponent
    }
}
