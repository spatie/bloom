import Foundation

/// A copyable sign-in command for users who prefer their own terminal.
/// Paths and arguments stay literal even when they contain spaces or shell operators.
public enum TerminalLaunchScript {
    public static func shellCommand(directory: String, executable: String, arguments: [String]) -> String {
        "cd " + shellQuoted(directory) + " && "
            + command(executable: executable, arguments: arguments)
    }

    public static func command(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
