import Foundation

/// Attachments written before there was a worktree to write them into.
///
/// The composer copies an attached file into the worktree the agent will stand in, because a path
/// outside it is a path the agent may not be allowed to read. The create sheet is a composer for a
/// worktree that does not exist yet, so it writes into a staging directory laid out exactly like
/// one: `.bloom/attachments/<id>/<name>`, relative to the staging root. That is what makes the
/// handover a move and not a rewrite. Every stored path is already the path it will have in the
/// worktree, so nothing in the prompt has to be edited after the fact.
struct StagedAttachments: Sendable {
    /// The staging root the paths are relative to.
    var directory: String
    var attachments: [PromptAttachment]
}

/// Where a draft's attachments live between being dropped and the worktree being cut.
enum AttachmentStaging {
    /// Under the system temporary directory rather than in Bloom's application support, because
    /// everything here is either moved within seconds or abandoned, and abandoned is exactly what
    /// the temporary directory is for. A draft the user closed without creating leaves nothing
    /// anybody has to clean up by hand.
    static func directory(draftID: String) -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("bloom-drafts")
        return (root as NSString).appendingPathComponent(draftID)
    }

    /// Takes a cancelled or completed draft's staging directory away.
    ///
    /// Safe to call when nothing was ever attached, which is the usual case: there is no directory
    /// and removing it is a no-op.
    static func discard(draftID: String) {
        try? FileManager.default.removeItem(atPath: directory(draftID: draftID))
    }
}
