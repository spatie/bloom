import Foundation

/// Closing is handled by Bloom before a prompt can reach either agent backend.
public enum ChatCloseCommand {
    public static func matches(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "/close"
    }
}
