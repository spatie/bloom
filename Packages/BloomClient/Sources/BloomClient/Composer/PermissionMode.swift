import Foundation

public enum PermissionMode: String, Sendable, Codable, CaseIterable {
    case auto
    case acceptEdits
    /// Approvals answered by the agent's own reviewer instead of by the person at the keyboard.
    ///
    /// **Added because Bloom had no row for it and a user said so.** Codex's four presets are
    /// `read-only`, `workspace`, `auto` and `full-access`, and Bloom offered three of them:
    /// `acceptEdits` sends the pair the Codex app labels "Ask for approval", so the preset that
    /// app labels "Approve for me" was not reachable from any row in the menu. On the wire it is
    /// `approvalsReviewer: auto_review`, which nothing in Bloom had ever sent.
    ///
    /// Codex only, and Claude Code loses nothing by that: `auto` already is this mode there, which
    /// is why `nearest(on:)` sends a chat carrying this one back to `auto` when it moves.
    case autoReview
    case bypassPermissions
    case plan

    /// The name with no backend said, which is Claude Code's, because that is what a chat is
    /// until somebody picks a model out of another section. `label(on:)` is the one to reach for
    /// wherever the agent is known.
    public var label: String { label(on: .claudeCode) }
}
