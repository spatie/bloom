import Testing
import Foundation
@testable import BloomCore

/// Which shell a Bloom terminal starts, and what it calls it.
///
/// Two places decided this independently and identically: the pty `TerminalView` launches, and
/// the tmux configuration `TerminalPersistence` writes. Neither knew about the other, so the day
/// one learned something the other did not, the difference would be invisible until somebody's
/// `.zprofile` stopped running in one of Bloom's two terminals and not the other.
@Suite("Which shell a terminal starts")
struct LoginShellTests {
    private func path(_ shell: String?, executable: Set<String> = ["/bin/zsh", "/opt/homebrew/bin/fish"]) -> String {
        LoginShell.path(
            environment: shell.map { ["SHELL": $0] } ?? [:],
            isExecutable: executable.contains
        )
    }

    @Test("the user's own shell is used when it is really there")
    func theUsersShellWins() {
        #expect(path("/opt/homebrew/bin/fish") == "/opt/homebrew/bin/fish")
    }

    /// A stale `SHELL` pointing at a removed homebrew shell is the ordinary way this goes wrong.
    @Test("a shell that is not on disk falls back")
    func aMissingShellFallsBack() {
        #expect(path("/opt/homebrew/bin/nushell") == LoginShell.fallback)
        #expect(path(nil) == LoginShell.fallback)
    }

    /// Empty is not a path, and `?? "/bin/zsh"` only catches a missing key.
    @Test("an empty SHELL is not treated as a shell")
    func anEmptyShellIsNotAPath() {
        #expect(path("") == LoginShell.fallback)
    }

    /// The leading dash is the whole convention: it is what makes bash read `.bash_profile` and
    /// zsh read `.zprofile`, so a terminal that gets it wrong is one where the user's own setup
    /// silently did not run.
    @Test("argv zero is the shell's name with a dash in front")
    func argumentZeroCarriesTheDash() {
        #expect(LoginShell.argumentZero(for: "/bin/zsh") == "-zsh")
        #expect(LoginShell.argumentZero(for: "/opt/homebrew/bin/fish") == "-fish")
    }

    /// The bug this pair existed to close. `TerminalView` tested the path, fell back, and then
    /// named the shell from the value it had just rejected, so a machine with a stale `SHELL`
    /// would run `/bin/zsh` under the name `-fish` and read the wrong profile.
    @Test("a rejected shell does not lend its name to the one that runs")
    func theNameFollowsTheShellThatRuns() {
        let resolved = path("/opt/homebrew/bin/nushell")
        #expect(resolved == LoginShell.fallback)
        #expect(LoginShell.argumentZero(for: resolved) == "-zsh")
        #expect(LoginShell.argumentZero(for: resolved) != "-nushell")
    }
}
