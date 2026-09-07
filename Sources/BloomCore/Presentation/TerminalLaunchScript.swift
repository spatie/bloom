import Foundation

/// A Terminal AppleScript carries a shell command inside another language's string literal.
/// Escaping only the AppleScript layer leaves spaces and shell operators in paths executable.
public enum TerminalLaunchScript {
    public static func shellCommand(directory: String, executable: String, arguments: [String]) -> String {
        "cd " + shellQuoted(directory) + " && "
            + ([executable] + arguments).map(shellQuoted).joined(separator: " ")
    }

    public static func appleScript(directory: String, executable: String, arguments: [String]) -> String {
        let command = shellCommand(directory: directory, executable: executable, arguments: arguments)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "tell application \"Terminal\" to do script \"\(escaped)\""
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
