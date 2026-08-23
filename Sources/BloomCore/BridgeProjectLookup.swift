import Foundation

/// Turning the name a client typed into a project Bloom already has.
///
/// The whole point is the last four words. A workspace agent never names a project, because its
/// own workspace says which one it is in; the owner's standalone client has no workspace, so it
/// has to name one, and the moment a name crosses the socket there is a thing to get wrong. This
/// resolves only against rows that exist, so the worst a wrong name can do is be refused.
///
/// Three ways to say the same project, in the order a person is likeliest to mean them: the id
/// Bloom printed, the path on disk, the name in the sidebar. The id and the path are unique in the
/// database, so they cannot be ambiguous; the name is not, because two projects may be called the
/// same thing, and an ambiguous name is refused rather than resolved to whichever row sorted
/// first. Silently picking one would put a worktree in the wrong repository.
public enum BridgeProjectLookup: Sendable {
    public enum Outcome: Sendable, Equatable {
        case found(Repo)
        case unknown
        /// More than one project answers to this name. Carries them so the refusal can say which.
        case ambiguous([Repo])
    }

    public static func find(_ query: String, in projects: [Repo]) -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if let byID = projects.first(where: { $0.id.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .found(byID)
        }

        // Standardised on both sides, so `~/dev/bloom`, `/Users/x/dev/bloom` and a path with a
        // trailing slash are one project rather than three misses.
        let wanted = standardised(trimmed)
        if let byPath = projects.first(where: { standardised($0.path) == wanted }) {
            return .found(byPath)
        }

        let byName = projects.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        switch byName.count {
        case 0: return .unknown
        case 1: return .found(byName[0])
        default: return .ambiguous(byName)
        }
    }

    /// The refusal for a query that matched nothing or matched too much, or nil when it resolved.
    ///
    /// Written to the standard `WorkspaceStartTrouble` sets: it says what is true, it says whether
    /// trying again will help, and it hands over the material to try again with rather than
    /// leaving the caller to guess. A client that is told "no such project" and nothing else
    /// guesses, and every guess is another call.
    public static func refusal(for query: String, outcome: Outcome, projects: [Repo]) -> String? {
        switch outcome {
        case .found:
            return nil

        case .ambiguous(let matches):
            return "Bloom has \(matches.count) projects called '\(query)'. Ask again with one of "
                + "these paths instead: " + listing(matches.map(\.path)) + "."

        case .unknown:
            guard !projects.isEmpty else {
                return "Bloom has no projects yet, so there is nowhere to start a workspace. Add "
                    + "an existing git repository with project_add first."
            }
            return "Bloom has no project called '\(query)'. It knows "
                + listing(projects.map(\.name))
                + ". Ask again with one of those, or add the repository with project_add first. "
                + "Bloom will not start a workspace in a repository it does not know about."
        }
    }

    /// Named things, capped. Somebody with two hundred projects would otherwise spend the whole
    /// refusal listing them, and the caller only needs enough to pick one.
    static func listing(_ items: [String]) -> String {
        let shown = items.prefix(10).map { "'\($0)'" }
        let rest = items.count - shown.count
        var text = shown.count == 1
            ? shown[0]
            : shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
        if rest > 0 { text += ", and \(rest) more" }
        return text
    }

    static func standardised(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standard = (expanded as NSString).standardizingPath
        guard standard.count > 1, standard.hasSuffix("/") else { return standard }
        return String(standard.dropLast())
    }
}
