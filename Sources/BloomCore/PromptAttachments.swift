import Foundation

/// The rules about attachments that are pure: what the agent is told, where a copy goes, and what
/// an id looks like.
///
/// Split out from the views and from the file system on purpose. These are the parts worth
/// asserting on, and this file's own note said they would move into `BloomCore` once the sending
/// path was free to be edited. It is, and they have: `safeFilename` is a path-safety policy for
/// files written into the owner's checkout, and the `..` reasoning in its comment is exactly the
/// kind of claim that wants a test rather than a paragraph.
public enum PromptAttachments {
    /// Where a copy lands inside the worktree.
    ///
    /// Inside, rather than in Bloom's application support directory, because the agent has to be
    /// able to read it. Claude Code will not read a path outside its working directory without
    /// asking, Bloom has nothing that can answer that question, and a turn that stalls on an
    /// unanswerable permission prompt is worse than no attachments at all. Inside the worktree the
    /// read is ordinary.
    ///
    /// Under `.bloom`, which is already Bloom's corner of a repository, and made invisible to git
    /// by `WorktreeScratch`. See that type for why an untracked folder here would be a bug rather
    /// than a detail.
    public static let folder = WorktreeScratch.attachments

    /// Six characters, in the alphabet a URL would accept.
    ///
    /// Short because the whole of it is read: it is a directory in the path chip above the file
    /// and in the prompt the agent is handed, and a UUID there is thirty six characters of noise
    /// in both places. Six is enough that two attachments in one worktree colliding is not
    /// something that happens.
    public static func newShortID() -> String {
        let alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in alphabet.randomElement() ?? "a" })
    }

    /// The name a copy is written under: the file's own, with anything that would change what the
    /// path means taken out.
    ///
    /// A slash would silently put the file somewhere else, and a leading dot would hide it from
    /// the person who came looking for it in Finder. Everything else is left alone, spaces and
    /// accents included, because the name is the one part of an attachment the user recognises.
    public static func safeFilename(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Every leading dot, not just the first: `..` is a name git and Finder both refuse, and
        // one pass over a name of nothing but dots leaves another dot in front.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        guard !cleaned.isEmpty else { return "attachment" }
        return cleaned
    }

    /// Where a copy of `filename` goes, relative to the worktree.
    public static func destination(filename: String, id: String) -> String {
        "\(folder)/\(id)/\(safeFilename(filename))"
    }
}
