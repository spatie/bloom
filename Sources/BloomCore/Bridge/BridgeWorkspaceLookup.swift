import Foundation

/// Turning the workspace a client named into a workspace Bloom already has.
///
/// `BridgeProjectLookup` one door over, for the same reason and in the same shape. A tool scoped
/// to the caller's own workspace never names one, because the token says which; the owner's
/// standalone client is sitting in no workspace at all, so it has to name one out loud, and the
/// moment a name crosses the socket there is a thing to get wrong.
///
/// Two ways to say the same workspace: the id `workspace_list` and `reveal` print, and the name in
/// the sidebar. The id is unique in the database so it cannot be ambiguous; the name is not,
/// because `AgentWorkspaceOrder.name` deliberately does not dedupe and the create window does not
/// either, and an ambiguous name is refused rather than resolved to whichever row sorted first.
///
/// It is one function rather than one per tool because `reveal` had it and `workspace_rename`
/// wanted the same answer, and two functions that resolve a name against the same rows are two
/// functions that will one day disagree about which workspace the owner meant.
///
/// The id is compared case insensitively, which is a widening `reveal` did not have and
/// `BridgeProjectLookup` always did. An id is a string a model copies out of an earlier answer and
/// a copy that came back capitalised is still the same row; there is no second workspace it could
/// mean.
public enum BridgeWorkspaceLookup: Sendable {
    public enum Outcome: Sendable, Equatable {
        case found(Workspace)
        case unknown
        /// More than one workspace answers to this name. Carries them so the refusal can say
        /// where each of them is rather than only how many there are.
        case ambiguous([Workspace])
    }

    public static func find(_ query: String, among workspaces: [Workspace]) -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if let byID = workspaces.first(where: {
            $0.id.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .found(byID)
        }

        let byName = workspaces.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        switch byName.count {
        case 0: return .unknown
        case 1: return .found(byName[0])
        default: return .ambiguous(byName)
        }
    }

    /// How many names a refusal prints before it stops and points at `workspace_list`.
    ///
    /// A refusal goes straight into the model's context, and somebody with four hundred
    /// workspaces would otherwise spend the whole of it being told "not that one".
    static let listLimit = 10

    /// Names, comma separated, cut off before a refusal turns into a directory listing.
    static func list(_ names: [String]) -> String {
        guard !names.isEmpty else { return "nothing" }
        let shown = names.prefix(listLimit).joined(separator: ", ")
        let rest = names.count - listLimit
        return rest > 0 ? shown + " and \(rest) more" : shown
    }
}
