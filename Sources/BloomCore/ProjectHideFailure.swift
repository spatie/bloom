import Foundation

/// Why `project_hide` and `project_unhide` would not act on a project, in terms a client can act
/// on.
///
/// Built to the standard `WorkspaceStartTrouble` and `ProjectAddTrouble` set, and for the same
/// reasons. Every sentence says what is true, whether trying again will help, and what to try
/// instead, and none of them quotes an internal path or a command line: the only path either of
/// these tools ever repeats is one the caller handed in.
///
/// `BridgeProjectLookup.refusal` is deliberately not reused. It answers for `workspace_start` and
/// ends by saying Bloom will not start a workspace in a repository it does not know about, which
/// is true and is about a different tool. A refusal that talks about the wrong operation is a
/// refusal a model acts on wrongly.
///
/// There is no case here for a project that is already in the state that was asked for. Hiding a
/// hidden project changes nothing and is not a mistake, so it answers like `project_add` does with
/// a repeat call: successfully, and saying plainly that nothing changed.
public enum ProjectHideTrouble: Sendable, Equatable {
    /// The call arrived with no project named. Both tools need one: neither has a workspace to be
    /// scoped by, because the owner's client is sitting in no workspace at all.
    case noProjectNamed(tool: String)
    /// Bloom has no projects, so there is nothing to hide or to bring back.
    case nothingRegistered(tool: String)
    /// A name, path or id that matches nothing. Carries what Bloom does have, so the next call can
    /// be right rather than another guess.
    case unknown(query: String, known: [String])
    /// More than one project answers to this name. Carries their paths, which are unique.
    case ambiguous(query: String, paths: [String])
    /// Anything else, said plainly.
    case unexplained(tool: String, message: String)

    public var sentence: String {
        switch self {
        case .noProjectNamed(let tool):
            return """
                \(tool) needs the project to act on, named by the name Bloom shows in its \
                sidebar, by the absolute path of the repository, or by the id project_list \
                prints. Call project_list to see them.
                """

        case .nothingRegistered(let tool):
            return """
                Bloom has no projects, so \(tool) has nothing to act on. Retrying will not change \
                that. Register an existing git repository with project_add first.
                """

        case let .unknown(query, known):
            return """
                Bloom has no project called '\(query)', so there is nothing to hide or show under \
                that name. It knows \(BridgeProjectLookup.listing(known)). Retrying with the same \
                name will fail the same way: ask again with one of those, with the repository's \
                absolute path, or with an id from project_list.
                """

        case let .ambiguous(query, paths):
            return """
                Bloom has \(paths.count) projects called '\(query)' and will not guess which one \
                you meant. Ask again with one of these paths instead: \
                \(BridgeProjectLookup.listing(paths)).
                """

        case let .unexplained(tool, message):
            return "Bloom could not \(tool == "project_hide" ? "hide" : "show") that project: \(message)"
        }
    }

    /// What is wrong with this call, or nil when the lookup found exactly one project.
    ///
    /// Diagnosed by asking Bloom's own project list rather than by reading the words off an error,
    /// which is the standard the other two sets set: the list answers "no such project", "two of
    /// them" and "none at all" as three different facts, where a thrown error would be one.
    public static func diagnose(
        query: String,
        outcome: BridgeProjectLookup.Outcome,
        projects: [Repo],
        tool: String
    ) -> ProjectHideTrouble? {
        switch outcome {
        case .found:
            return nil
        case .ambiguous(let matches):
            return .ambiguous(query: query, paths: matches.map(\.path))
        case .unknown:
            guard !projects.isEmpty else { return .nothingRegistered(tool: tool) }
            return .unknown(query: query, known: projects.map(\.name))
        }
    }
}
