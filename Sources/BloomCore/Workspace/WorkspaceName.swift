import Foundation

/// What a name handed to Bloom from outside is worth, at every door that takes one.
///
/// There are two of those doors now. `workspace_start` takes a name for a workspace it is about
/// to cut, and `workspace_rename` takes one for a workspace that is already there, and they have
/// to agree: a name the first door accepts and the second refuses is a workspace an agent can
/// create and then cannot correct. The rule was written out at the first door and copied nowhere,
/// which is the state a second door is how you find out about.
///
/// It is a trim and nothing more, and the interesting part is what it deliberately is not.
/// `WorkspaceNaming.cleanName` is the stricter rule next door: first line only, wrapping quotes
/// off, control characters to spaces, trailing full stops off, cut at sixty characters. That one
/// is written against a model answering a naming prompt, where every one of those is a defect in
/// the answer rather than something anybody asked for. A name that arrives as an argument was
/// typed on purpose, by an agent that has just told the owner what it was going to call the
/// workspace, so quietly cutting it at sixty characters or eating its full stop would make that
/// sentence wrong. Bloom takes what it was given, or says it cannot.
public enum WorkspaceName {
    /// The name a caller passed, or nil when they passed nothing usable.
    ///
    /// Nil and not an empty string, because the two doors want different things from it: at
    /// `workspace_start` nil means "you name it", and at `workspace_rename` nil is a refusal. A
    /// function that answered "" would leave both of them re-deciding what blank meant.
    public static func given(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
