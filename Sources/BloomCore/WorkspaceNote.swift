import Foundation

/// The scratch text a workspace carries, and the rules about when it is written down.
///
/// A note is the thing you notice at eleven at night and want the morning agent to fix. It belongs
/// to the worktree rather than to any one conversation, it is not transcript, and nothing sends it
/// anywhere on its own: the only way it reaches an agent is the button that copies it into the
/// composer, where the user can still read it before pressing send.
///
/// **It is a row of its own rather than a column on `workspaces`, and that is the whole design.**
/// A workspace row is written by a diff stat refresh every six seconds, by a finishing turn, by an
/// archive that takes seconds of disk work, and by automatic naming. A pane somebody types in for a
/// minute is exactly the slow writer that used to roll all of those back, and `update(workspaceID:)`
/// only makes a whole-value write safe for the caller that remembers to use it. A table keyed by
/// workspace has one writer and no columns anybody else wants, so the race cannot be written. See
/// `Tests/BloomCoreTests/WorkspaceWriteIsolationTests.swift` for the bug this sidesteps, and
/// `drafts`, which is the same shape a session deep.
///
/// The foreign key is `ON DELETE CASCADE`, so a note dies when the workspace row does and not
/// before. Archiving does not delete that row, it moves `state` and stamps `archivedAt`, so an
/// archived workspace keeps its note. That is deliberate: a note is most often about why the work
/// was abandoned, which is precisely what you want to read when you come back to an archive.
public struct WorkspaceNote: Sendable, Hashable {
    public var workspaceID: WorkspaceID
    public var body: String
    public var updatedAt: Date

    public init(workspaceID: WorkspaceID, body: String, updatedAt: Date = Date()) {
        self.workspaceID = workspaceID
        self.body = body
        self.updatedAt = updatedAt
    }

    /// How long the pane waits after the last keystroke before writing.
    ///
    /// Every keystroke would be a row rewritten and an update hook fired per character, on the same
    /// actor an agent turn and the diff stat refresh are queueing on, and `StoreChangeHub` would
    /// announce every one of them. Blur alone is the other extreme and loses the case that actually
    /// matters, which is typing a note and walking away from the machine with the pane still open.
    /// So it is a debounce, and it is the same three quarters of a second the composer's own draft
    /// uses, for the same reason: a fast typist writes one row instead of forty, and the worst a
    /// crash mid sentence can cost is the last word. The pane writes immediately on top of this
    /// whenever the text field loses focus or the pane goes away, so the only window that is ever
    /// open is one where the user is still typing.
    public static let autosaveDelay: Duration = .milliseconds(750)

    /// Whether a note that has been typed is worth a write.
    ///
    /// Identical text is skipped rather than written, which is the same rule `updateDiffStat`
    /// follows for the same reason: SQLite does not care that the value is unchanged, it rewrites
    /// the row, grows the WAL and fires the update hook, and everything listening reloads for a
    /// change that did not happen. A debounce started by an arrow key would do that forever.
    ///
    /// Whitespace only counts as nothing, so a note somebody emptied down to a stray newline is
    /// stored as no note at all and the pane comes back to its placeholder rather than to a blank
    /// that looks like a bug.
    public static func needsSave(stored: String, typed: String) -> Bool {
        storable(typed) != storable(stored)
    }

    /// What actually goes in the row: the text as typed, or nothing at all when it is blank.
    ///
    /// Only the blank case is normalised. Trimming a note on every save would delete the newline
    /// the user just pressed while they were in the middle of pressing it, which is a text field
    /// that fights back.
    public static func storable(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : body
    }

    /// The sentence this note becomes when it is handed to the composer, or nothing when there is
    /// nothing to hand over.
    ///
    /// The text goes across as written, with no framing added. A note is already addressed to the
    /// agent, and a preamble bolted on here would be one more thing to delete before sending. The
    /// trailing whitespace goes because it arrives at the end of a draft that may already have a
    /// sentence in it.
    public static func handoff(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
