import Foundation

/// The one line above a run script's shell, if there is one, and what it says.
///
/// Two strips can stand over a terminal pane and they must never stand there together. "Was
/// running here" is the pane saying what it lost across a relaunch; "Stopped after" is the pane
/// saying what ended in this launch. A pane with both would be asking the reader to choose between
/// two buttons that do the same thing, so this picks one.
public enum RunScriptPaneStrip: Sendable, Hashable {
    /// Nothing above the shell.
    case none
    /// `TerminalRestartStrip`: the command from the last launch, offered back.
    case restart(command: String)
    /// The command ended in this launch.
    case stopped(caption: String, command: String)

    /// - Parameters:
    ///   - offer: what `TerminalCommandRecall` would offer back for this pane, or nil.
    ///   - activity: what the pane's readings say about the command.
    ///   - script: the run script the tab was opened for, as the settings file states it now, or
    ///     nil for an ordinary terminal and for a tab whose script has since been removed.
    ///
    /// **A run script's tab offers the command the file says now**, never the one remembered from
    /// the last launch. The remembered text is whatever was typed then, and a branch that changed
    /// `yarn dev` to `pnpm dev` since would otherwise put the old one back under a Start button.
    ///
    /// An ordinary terminal is exactly what it was before run scripts had tabs: the offer or
    /// nothing, and never a stopped strip, because a shell somebody ran `ls` in has not stopped
    /// anything worth a line.
    public static func decide(
        offer: String?, activity: RunScriptActivity.State, script: RunScript?
    ) -> RunScriptPaneStrip {
        guard let script else { return offer.map { .restart(command: $0) } ?? .none }
        let command = script.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .none }

        switch activity {
        case .running:
            return .none
        case .stopped(let after):
            return .stopped(caption: caption(after: after), command: command)
        case .idle:
            return offer == nil ? .none : .restart(command: command)
        }
    }

    /// "Stopped after 2m 14s", or just "Stopped" when it ended too quickly to be seen running.
    public static func caption(after length: Duration?) -> String {
        guard let length else { return "Stopped" }
        return "Stopped after \(format(length))"
    }

    /// Whole seconds, then minutes and seconds, then hours and minutes. A dev server runs for
    /// hours, and "3h 12m 40s" is more precision than anybody reading a stopped strip wants.
    public static func format(_ length: Duration) -> String {
        let seconds = Int(length.components.seconds)
        guard seconds >= 1 else { return "under a second" }
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
