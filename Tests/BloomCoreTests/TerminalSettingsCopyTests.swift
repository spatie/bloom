import Testing
import Foundation
@testable import BloomCore

/// The Appearance pane tells somebody where their terminal's text size comes from, which is the one
/// question a stepper reading "13 pt" cannot answer on its own. Three states, and the failure is
/// silent: a pane that says Bloom is following a configuration it stopped following is worse than
/// one that says nothing.
@Suite("Terminal settings copy")
struct TerminalSettingsCopyTests {
    @Test("an override says it has stopped following Ghostty")
    func overrideWins() {
        let line = TerminalSettingsCopy.textSizeSource(override: 15, ghostty: 13)

        #expect(line == "Set here, so it no longer follows Ghostty.")
    }

    @Test("with no override the Ghostty size is named")
    func followsGhostty() {
        let line = TerminalSettingsCopy.textSizeSource(override: nil, ghostty: 13)

        #expect(line.contains("13 pt"))
        #expect(line.contains("Ghostty"))
    }

    /// Whole points, because the stepper beside it shows whole points. A configuration carrying
    /// 13.5 read back as "13.5 pt" next to a stepper reading "13 pt".
    @Test("a fractional Ghostty size is said in whole points")
    func roundsGhosttySize() {
        let line = TerminalSettingsCopy.textSizeSource(override: nil, ghostty: 13.5)

        #expect(line.contains("13 pt"))
    }

    @Test("with neither, the system size is named rather than left unexplained")
    func fallsBackToSystem() {
        let line = TerminalSettingsCopy.textSizeSource(override: nil, ghostty: nil)

        #expect(line.contains("system monospaced"))
        // Naming Ghostty in the negative is the point: the failure this sentence guards against is
        // a pane claiming to follow a configuration that is not there. Saying none was found is
        // the clearest way to not claim it.
        #expect(line.contains("No Ghostty configuration"))
    }

    /// The switch is disabled without tmux, and a disabled switch with no reason beside it is the
    /// state people file bugs about.
    @Test("without tmux the sentence says what to install")
    func namesTheMissingDependency() {
        let line = TerminalSettingsCopy.persistence(isTmuxInstalled: false)

        #expect(line.contains("brew install tmux"))
    }

    /// Archiving stops a workspace's terminals whatever this is set to, and that guarantee is the
    /// reason the feature cannot leave a shell inside a deleted worktree. It stays in the sentence.
    @Test("with tmux the archive guarantee is still stated")
    func keepsTheArchiveGuarantee() {
        let line = TerminalSettingsCopy.persistence(isTmuxInstalled: true)

        #expect(line.contains("Archiving a workspace always stops its terminals"))
    }
}
