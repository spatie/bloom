import Foundation

/// Whether a workspace may be started yet, given what has been written.
///
/// This was a computed property inside `CreateWorkspaceView`, where nothing could test it, and it
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

    /// What a workspace ends up called, from what the caller settled before anything was cut.
    ///
    /// **One rule, three callers, and that is the whole reason it is here.** `cut` said
    /// `name ?? Git.title(from: prompt)` and `open` said `name ?? checkout.workspaceName`, each
    /// inside `WorkspaceManager` where nothing could reach them. `PendingWorkspace` needs the same
    /// answer before either of them runs, and a fourth copy of a two-clause fallback is exactly
    /// how the row drawn during the cut comes to say something other than the row drawn after it.
    ///
    /// - Parameter supplied: the name the request carried, or the codename the namer handed out.
    ///   `WorkspaceManager.start` resolves those two into one value before it gets here.
    /// - Parameter checkout: a pull request or branch being opened, which brings its own name.
    /// - Parameter prompt: the task, with its attachments already taken out of it. The last
    ///   resort, and `Git.title` answers "New workspace" for an empty one rather than nothing.
    public static func name(
        supplied: String?, checkout: WorkspaceCheckout?, prompt: String
    ) -> String {
        if let supplied, !supplied.isEmpty { return supplied }
        if let checkout { return checkout.workspaceName }
        return Git.title(from: prompt)
    }

    /// What a workspace that runs no agent is called, which is a terminal one and a browser one.
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

    // MARK: - Crossing between the modes

    /// What the name field carries over when the create window leaves chat mode.
    ///
    /// This is the whole question the two-button sheet answered silently. Pressing "Just a
    /// terminal" with a sentence in the box did use that sentence: `Git.title(from:)` cut its
    /// first line down to a name, `Git.slug` made the branch out of it, and nothing said so. So
    /// the crossing does exactly what the create was always going to do, and puts the answer in an
    /// editable field where it can be read and disagreed with before anything is cut.
    ///
    /// A name already in the field wins. A mode switch may not overwrite something somebody typed
    /// on purpose, and an empty field has nothing to lose, so no "has been edited" flag is needed
    /// to tell the two apart. Going back and forth therefore keeps the first crossing's answer
    /// rather than re-deriving it from a sentence that has since grown, which is the safer of the
    /// two wrong answers: the field is on screen and one keystroke from being fixed.
    ///
    /// An empty prompt carries an empty name, rather than `Git.title`'s "New workspace". Empty is
    /// what claims a sea, and a sea is a better name than "New workspace" by some distance.
    public static func carriedName(prompt: String, currentName: String) -> String {
        guard currentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return currentName
        }
        let spoken = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return "" }
        return Git.title(from: spoken)
    }

    /// And what the prompt carries back when it returns to chat mode.
    ///
    /// The mirror of the rule above, and it exists because the window now OPENS in terminal mode
    /// for anybody who was last there. Somebody who types a sentence into the name field and then
    /// realises they wanted an agent after all must not have to type it twice: that is the same
    /// silent discard, pointing the other way.
    ///
    /// The draft in the box wins where there is one, for the same reason a typed name does above.
    public static func carriedPrompt(name: String, currentPrompt: String) -> String {
        guard currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return currentPrompt
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - What a mode with no agent says about itself

    /// The line under the name field.
    ///
    /// **It does not mention seas, and that is the point of it living here.** The sheet used to
    /// say "Leave it empty and the workspace is named after a sea", which spends a discovery to
    /// explain a mechanism nobody asked about: the sea catalogue is a thing to find out about from
    /// the chart and from the notice that fires the first time one is claimed, and a create window
    /// that names it beforehand has told the joke before the punchline. What somebody standing in
    /// front of an empty field needs is that the field is optional and that something will fill
    /// it, which is what this says.
    ///
    /// Every branch ends the same way. "Nothing is sent to an agent" is the sentence the two
    /// button sheet never said, and it is the only half here that has to be on screen in every
    /// state: it is the whole difference between the modes that run one and the modes that do not.
    ///
    /// In the core rather than in the view because it is three sentences chosen by two conditions,
    /// which is a decision, and because a rule about what the app may not say is worth a test that
    /// fails when somebody puts it back.
    ///
    /// - Parameter mode: only ever one that runs no agent, because a chat has a box rather than a
    ///   field and says what it is for by being one. Its clause is `openingSentence`, which is on
    ///   the mode so that a fourth of them cannot be added without answering for this sentence.
    public static func startNote(
        mode: WorkspaceStartMode, hasCheckout: Bool, name: String
    ) -> String {
        let agentless = "Nothing is sent to an agent."
        guard !hasCheckout else {
            // A checkout arrives with its own name, so there is no field and nothing to say about
            // one. What is left worth saying is what the workspace will be.
            return "The worktree stands on it and \(mode.openingSentence). " + agentless
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Leave it empty and Bloom names it for you. " + agentless
            : "This names the workspace and its branch. " + agentless
    }
}
