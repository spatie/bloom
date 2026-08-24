import Foundation

/// The two things every instruction file Bloom sends to an agent has to do: prove it is really
/// there, and get itself named in the sentence that asks for it.
///
/// Extracted when merging grew a file of its own beside `PullRequestInstructions`. Both rules are
/// load bearing and neither is obvious, so a second copy of them was a second place for them to
/// drift. Which of the two files is used, and what it says, stays with each of them, because that
/// is the part that differs.
public enum InstructionFile {
    /// Whether a path relative to the worktree is a readable regular file right now.
    ///
    /// A directory answers yes to `isReadableFile` on its own, and an instruction path that
    /// happens to be a folder would otherwise be attached to a prompt as a file the agent is then
    /// told to read and cannot. Anything that is not a plain file is treated as no file at all.
    public static func isFile(_ relative: String, in worktree: String) -> Bool {
        let full = (worktree as NSString).appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        guard manager.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return false }
        return manager.isReadableFile(atPath: full)
    }

    /// The turn that carries a file, with the path in the sentence that asks for it.
    ///
    /// Bloom writes this message rather than the user, so there is no caret to put the file at and
    /// no words of somebody else's to interrupt. It goes at the end, in the one sentence that says
    /// what to do with it: an agent reading "follow the instructions in this file" knows to open
    /// it, where a path listed under a heading is a fact with no verb attached.
    ///
    /// A code span, which is how `AttachmentDraft` writes every path in a prompt: the same form in
    /// a turn Bloom composed and in one somebody typed, so a transcript can draw both the same way.
    public static func asking(_ text: String, toFollow path: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = "Follow the instructions in \(AttachmentDraft.token(for: path))."
        guard !body.isEmpty else { return sentence }
        return "\(body)\n\n\(sentence)"
    }
}
