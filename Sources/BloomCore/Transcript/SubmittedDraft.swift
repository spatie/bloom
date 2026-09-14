import Foundation

/// A composed review differs from its compact draft. Clearing still compares against the
/// original draft, so words typed while that review was prepared survive the submission.
public enum SubmittedDraft {
    public static func matching(current: String, message: String, source: String? = nil) -> String? {
        let expected = (source ?? message).trimmingCharacters(in: .whitespacesAndNewlines)
        return current.trimmingCharacters(in: .whitespacesAndNewlines) == expected ? current : nil
    }
}
