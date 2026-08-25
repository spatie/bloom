import Foundation

/// What a file chip in a transcript is pointing at: the file the hover card should ask the disk
/// for, and the path a click on it opens.
///
/// The two answers are not the same string, and working out either one needs the worktree, which
/// is why they are decided together rather than at each chip. A transcript names files in three
/// forms and they arrive within lines of each other: an agent writes an absolute path, because
/// Claude Code requires one on every read; the composer writes a worktree relative one, because
/// that is where the agent is standing; and the owner writes whatever he typed. The review only
/// resolves a path against the worktree, so a chip naming a file in another checkout, in the home
/// directory or in a temporary folder has nowhere to open, and `AttachmentCard` needs to be handed
/// no worktree at all for that one or it would look for it inside this one.
///
/// This was worked out inside `ToolRowHeader` and about to be worked out a second time inside
/// `UserTurnRowView` when the pills in a sent bubble were given the same card the tool rows
/// already had. Two copies of it would be two answers to "can this chip be opened", four lines
/// apart in the same transcript.
///
/// **Nothing here touches the disk**, for the reason `FilePathGuess` gives at length: a transcript
/// is hundreds of rows in a lazy list, and whether the file is still there is `AttachmentPreview`'s
/// question, asked once for the one card that is actually up.
public struct FileChipTarget: Equatable, Sendable {
    /// What the card asks for, relative to `worktree` where there is one and absolute where there
    /// is not.
    public var path: String
    /// The worktree `path` is relative to, and empty for a file outside it. Empty rather than the
    /// workspace's own root, because an absolute path joined onto a root is neither.
    public var worktree: String
    /// Where a click goes, worktree relative, and nil where the chip has nowhere to open. The chip
    /// is still drawn and still previews: it simply does not answer to the pointer.
    public var opens: String?

    public static func resolve(_ path: String, in worktree: String) -> FileChipTarget {
        guard let inside = FilePathGuess.relative(path, to: worktree) else {
            return FileChipTarget(path: path, worktree: "", opens: nil)
        }
        return FileChipTarget(path: inside, worktree: worktree, opens: inside)
    }
}
