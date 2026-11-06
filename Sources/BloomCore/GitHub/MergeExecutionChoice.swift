import Foundation

/// Whether Bloom sends a merge turn or executes the chosen gh or glab command itself.
public enum MergeExecution: String, CaseIterable, Sendable {
    case direct
    case agent

    public func label(on forge: Forge) -> String {
        switch self {
        case .direct: "Merge with \(forge.name) CLI"
        case .agent: "Ask agent to merge"
        }
    }
}

/// A per-project UI preference, kept out of the repository's tracked settings file.
public enum MergeExecutionChoice {
    public static let fallback = MergeExecution.direct

    public static func key(repoID: RepoID) -> String {
        "repo.\(repoID).mergeExecution"
    }

    public static func resolve(_ stored: String?) -> MergeExecution {
        stored.flatMap(MergeExecution.init(rawValue:)) ?? fallback
    }

    public static func load(repoID: RepoID, from store: Store) async -> MergeExecution {
        resolve(try? await store.setting(key(repoID: repoID)))
    }

    public static func save(_ choice: MergeExecution, repoID: RepoID, to store: Store) async {
        try? await store.setSetting(key(repoID: repoID), choice.rawValue)
    }
}
