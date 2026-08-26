import Foundation

/// Which of GitHub's three ways of landing a branch this project uses, and what the button that
/// lands it says.
///
/// All three are real here rather than aspirational: `MergePromptContext` renders the method into
/// the turn as a phrase and as the `gh pr merge` flag that performs it, and `WorkspaceMergeTool`
/// accepts the same three from an agent. So there is something to choose between, which is what
/// makes a split button worth drawing at all.
///
/// **Per project, and that is the argument worth having.** Squash versus merge commit is a
/// repository's convention: a team either keeps a linear history or it does not, and the answer
/// does not change because a different person, or a different worktree, is doing the landing.
/// Per workspace would ask the same question again on every branch and answer it wrong by default
/// on the second one; app-wide would carry one repository's convention into every other
/// repository the owner opens. Neither is what the reader means when they pick Squash.
///
/// It is kept in Bloom's own store rather than in the repository's `.bloom/settings.toml`, and
/// that is deliberate too. A settings file is a file in somebody's working tree: writing to it
/// from a menu would dirty a branch, land in a commit, and reach a teammate who never asked. This
/// is a preference about how the owner presses a button, so it lives where the app's other
/// preferences live.
public enum MergeMethodChoice {
    /// What the button does before anybody has chosen.
    ///
    /// Squash, because that is what the Merge button proposed for the whole time it was one button
    /// with a fixed method, so nobody's next press changes meaning under them.
    public static let fallback = GitHub.MergeMethod.squash

    /// The three, in GitHub's own order, which is the order the web UI lists them in.
    public static let offered = GitHub.MergeMethod.allCases

    /// Per project. `Store`'s key value table, the way fast mode and the output style are kept per
    /// session: no column, no migration, and a missing row means "never chosen".
    public static func key(repoID: RepoID) -> String {
        "repo.\(repoID).mergeMethod"
    }

    /// What a stored string means. Anything unreadable falls back rather than failing: a value
    /// written by a later version of this app, or by a hand editing the database, must not leave
    /// the strip with no method to merge by.
    public static func resolve(_ stored: String?) -> GitHub.MergeMethod {
        guard let stored, let method = GitHub.MergeMethod(rawValue: stored) else { return fallback }
        return method
    }

    public static func load(repoID: RepoID, from store: Store) async -> GitHub.MergeMethod {
        resolve((try? await store.setting(key(repoID: repoID))) ?? nil)
    }

    /// The chosen method, written whole even when it is the fallback, so that a project where
    /// somebody deliberately picked squash keeps squash if the fallback is ever changed.
    public static func save(_ method: GitHub.MergeMethod, repoID: RepoID, to store: Store) async {
        try? await store.setSetting(key(repoID: repoID), method.rawValue)
    }
}

public extension GitHub.MergeMethod {
    /// What the split button says it will do when this method is the one in force.
    ///
    /// Not `label`, which is GitHub's own menu wording and is what the menu and the confirmation
    /// use. A button is a promise about the next press, and "Merge commit" reads as a noun where
    /// the other two read as verbs, so the plain merge says "Merge": the same word GitHub puts on
    /// the button under the same menu.
    var buttonLabel: String {
        switch self {
        case .merge: "Merge"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}
