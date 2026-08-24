import Foundation

/// Whether a workspace may be started yet, given what has been written.
///
/// This was a computed property inside `CreateWorkspaceSheet`, where nothing could test it, and it
/// is the reason "just give me a worktree" could not be asked for: the sheet disabled Create on an
/// empty box for every route at once. Words are the right requirement for a chat and the wrong one
/// for a shell, and one condition covering both is how the wrong one gets applied.
public enum WorkspaceStartPlan {
    /// Whether Create may be pressed.
    ///
    /// Words are required for a chat, and for nothing else.
    ///
    /// A chat workspace with an empty box has no opening turn to send, nothing for the namer to
    /// read and no branch to cut: `Git.slug` would call it `workspace`, and the sidebar would fill
    /// up with rows saying nothing. A checkout arrives with a name, a branch and a base already
    /// chosen by whoever opened the pull request. A terminal workspace is a worktree and a shell,
    /// which is a complete intention on its own: it is named after the sea it claims rather than
    /// after a sentence, so there is nothing an empty box would leave undecided.
    ///
    /// `isBusy` is the create already in flight. It belongs in the same answer rather than beside
    /// it, because a second press while the first worktree is being cut is the one way two
    /// workspaces end up racing for the same branch name.
    public static func canStart(
        hasProject: Bool,
        prompt: String,
        hasCheckout: Bool,
        isChatWorkspace: Bool,
        isBusy: Bool
    ) -> Bool {
        guard hasProject, !isBusy else { return false }
        guard isChatWorkspace, !hasCheckout else { return true }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a terminal workspace is called.
    ///
    /// A branch somebody typed is the name, because they have already said what this is. Otherwise
    /// it is the sea claimed for it, which is the whole reason a promptless start can have a name
    /// at all: the catalogue produces a word and a slug without being told anything. Nil hands the
    /// question back to `Git.title(from:)`, which answers "New workspace" for an empty prompt and
    /// is the honest fallback for a machine whose catalogue is exhausted.
    ///
    /// Nothing renames it afterwards. A chat's sea is a placeholder a model replaces once the
    /// first turn says what the work is; there is no first turn here, so the sea is the name until
    /// the owner types another one over it.
    public static func terminalName(userSuppliedBranch: String?, claimedSea: String?) -> String? {
        if let userSuppliedBranch, !userSuppliedBranch.isEmpty { return userSuppliedBranch }
        return claimedSea
    }
}
