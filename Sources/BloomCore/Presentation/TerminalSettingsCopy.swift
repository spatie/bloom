import Foundation

/// The two sentences the Appearance pane says about a terminal, each of which is a choice between
/// states rather than a label.
///
/// They were computed properties inside `AppearanceSettingsView`, which is a decision nothing could
/// test: `Tests/BloomCoreTests` depends on the core alone. Three states for where a size comes from
/// and two for whether terminals can outlive a quit, and getting one of them wrong means telling
/// somebody Bloom is following a configuration it has stopped following.
public enum TerminalSettingsCopy {
    /// Where the terminal text size is coming from, and nothing else.
    ///
    /// "13 pt" on its own cannot say whether Bloom is following the user's own terminal or has
    /// quietly stopped, which is the only question the stepper leaves open. The keys that change it
    /// are in the View menu, where they are always visible, so they are not repeated here.
    public static func textSizeSource(override: Double?, ghostty: Double?) -> String {
        if override != nil {
            return "Set here, so it no longer follows Ghostty."
        }
        if let ghostty {
            return "Following your Ghostty configuration's font-size of \(Int(ghostty)) pt."
        }
        return "No Ghostty configuration was found, so terminals use the system monospaced size."
    }

    /// What surviving a quit gets you, and what it cannot do.
    ///
    /// The archive sentence is not a detail. A shell left running inside a worktree that has just
    /// been deleted is the one failure this feature could cause, and the guarantee that it cannot
    /// is worth stating where the switch is thrown.
    public static func persistence(isTmuxInstalled: Bool) -> String {
        guard isTmuxInstalled else {
            return "Requires tmux, which is not installed. Run `brew install tmux`."
        }
        return "Terminals come back on the next launch, with their scrollback and anything still "
            + "running in them. Archiving a workspace always stops its terminals."
    }
}
