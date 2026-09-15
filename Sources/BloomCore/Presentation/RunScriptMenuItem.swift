import Foundation

/// One run script's row in the title bar's `+` menu.
///
/// The command is the row's second line, so what is about to run can be read before it runs. A
/// script that is already running says so instead, because picking it then shows the tab rather
/// than starting anything, and the command would promise the opposite.
public struct RunScriptMenuItem: Sendable, Hashable {
    public var title: String
    public var subtitle: String
    /// Off for a script whose file is missing: there is nothing to type.
    public var isEnabled: Bool

    /// - Parameters:
    ///   - missingFile: the path the settings file named, when nothing is there.
    public static func make(
        script: RunScript, isRunning: Bool, missingFile: String?
    ) -> RunScriptMenuItem {
        let subtitle: String
        if isRunning {
            subtitle = "Running"
        } else if let missingFile {
            subtitle = "Missing \(missingFile)"
        } else {
            subtitle = firstLine(of: script.command)
        }
        let hasCommand = !script.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return RunScriptMenuItem(
            title: script.name,
            subtitle: subtitle,
            // A running script stays pickable even if its file went since: picking it only shows
            // the tab.
            isEnabled: isRunning || (missingFile == nil && hasCommand)
        )
    }

    /// A script kept in a file of its own is the file's text, shebang and all, and a menu row has
    /// one line. The first line that is not a comment is the one that says what it does.
    static func firstLine(of command: String) -> String {
        let lines = command.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first { !$0.hasPrefix("#") } ?? lines.first ?? ""
    }
}
