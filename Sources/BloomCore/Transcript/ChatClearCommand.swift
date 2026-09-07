import Foundation

/// A host command, never a prompt sent to a paid agent. Arguments and sentences mentioning the
/// command stay ordinary text; both a typed command and the completed slash chip end up here.
public enum ChatClearCommand {
    public static func matches(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "/clear"
    }
}
