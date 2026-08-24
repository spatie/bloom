import Foundation

/// What the prompt surface is for.
///
/// The composer is the same surface in both places: the same box, the same editor, the same
/// pickers in the same order, the same attachments. Exactly one thing differs, which is what the
/// primary button does and therefore what it should say, so exactly one thing is named here rather
/// than a boolean being threaded through every view that makes up the surface.
///
/// Only two views read it: `ComposerFooterView`, which passes it on, and `ComposerSendButton`,
/// which draws it. Nothing else in the composer knows or needs to know which it is.
enum ComposerIntent {
    /// The next turn of a conversation that already exists.
    case send
    /// The first turn of one that does not, which also cuts a branch and a worktree.
    case create

    var title: String {
        switch self {
        case .send: "Send"
        case .create: "Create"
        }
    }

    var help: String {
        switch self {
        case .send: "Send (Return)"
        case .create: "Create the workspace (Return)"
        }
    }
}
