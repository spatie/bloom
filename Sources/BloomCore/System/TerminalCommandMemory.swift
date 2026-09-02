import Foundation

/// What a terminal pane was running when Bloom last saw it, and whether that is worth offering
/// back on the next launch.
///
/// The problem this exists for: a dev server is started in a terminal tab, Bloom is quit, and the
/// next launch has the tab, the split and the shell but not the server. Without persistence there
/// is nothing left to reattach to, so the pane is a fresh prompt in a worktree whose page no longer
/// loads, and the only way back is to remember what was typed or to ask an agent to type it again.
///
/// **Nothing here ever runs anything.** The command is remembered, drawn in the pane and started by
/// a person pressing a button, never by the app deciding to. It has to be that way round because
/// the command may have been written by an agent rather than by the owner: `terminal_start` sends
/// whatever the model asked for, and a launch that re-ran the last thing an agent typed would be
/// Bloom executing an agent's words with nobody in the loop. Shown and pressed, not executed.
public enum TerminalCommandMemory {
    /// One key per pane in the store's key value table, which is where a per-pane value with no
    /// column of its own lives. Nil is stored as no row at all, so a pane that was never running
    /// anything and a pane whose command has been dismissed read back the same.
    public static func key(paneID: String) -> String {
        "terminal.pane.\(paneID).command"
    }

    /// The longest command worth keeping.
    ///
    /// `ps` writing into a pipe truncates nothing, and the longest line on the owner's machine was
    /// 9,826 characters: a Java service, a browser helper, anything whose argv carries a classpath.
    /// None of that is a command a person typed into a dev-server pane, and a strip cannot show it
    /// anyway. Five hundred is well past every real one and well short of what turns the strip into
    /// a wall.
    public static let lengthLimit = 500

    /// The shells that are never offered.
    ///
    /// A pane always has one of these in it, so a shell as the answer means the pane was idle. The
    /// leading dash of a login shell's argv[0] is stripped before the comparison, because that is
    /// how `zsh` reports itself when it was started as one.
    static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "ash", "nu", "xonsh", "elvish",
    ]

    /// The command as it should be shown, or nil when there is nothing worth offering.
    ///
    /// Three things are refused. A bare shell, because that is the pane sitting at its prompt and
    /// not a process anybody started. Anything carrying a newline or a control character, because
    /// pressing Start types the text into a shell and a newline in it is a second command nobody
    /// read. And anything past `lengthLimit`, for the reason given there.
    ///
    /// A shell WITH arguments is kept: `zsh -c "npm run dev"` is a command somebody ran, and the
    /// pane being idle is not what it says. So is an editor or a pager, which is deliberate too:
    /// the strip reports what was there rather than judging what deserves to come back, and the
    /// person reading it is the one who decides.
    public static func offerable(_ command: String?) -> String? {
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= lengthLimit else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count == 1, let first = words.first else { return trimmed }
        let name = (String(first) as NSString).lastPathComponent
        return shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name) ? nil : trimmed
    }

    /// What to write down for a pane, from the two things known about it: the last line Bloom sent
    /// into it, and what its shell is running now.
    ///
    /// `running` nil means the shell is at its prompt, and then there is nothing to remember at
    /// all. A command that has already exited is not offered back: the pane it ran in is not
    /// waiting for it, and a memory that outlived the process would make every finished `git push`
    /// an offer on the next launch.
    ///
    /// When something IS running, the text Bloom sent wins over what the machine calls it. They
    /// describe the same process and only one of them is what a person typed: `npm run dev` against
    /// `node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js run dev`. The machine's answer is
    /// the fallback, because a command typed into the shell by hand never passed through Bloom.
    public static func remembered(sent: String?, running: String?) -> String? {
        guard running != nil else { return nil }
        return offerable(sent) ?? offerable(running)
    }
}
