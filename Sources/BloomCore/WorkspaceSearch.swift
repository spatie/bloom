import Foundation

/// The one rule for "does this workspace match what was typed".
///
/// It was written three times. `AppModel.search` behind the Search screen matched the workspace
/// name, the branch and the project name. `HomeList` matched the same three and said so in a
/// comment, which is how two of them stayed in step. The Shortcuts entity query matched two of
/// them, silently dropping the project name, so asking Siri for a workspace by its project found
/// nothing while typing the same words into the search field found it.
///
/// Returning the text that matched rather than a Bool is what lets the Search screen say why a
/// row is in the list without matching a second time and possibly disagreeing with itself.
public enum WorkspaceSearch {
    /// Lowercases and trims, so a caller passes what the user typed and nothing else.
    public static func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The field that matched, in the order a person would expect to be answered in: what they
    /// named it, what git calls it, then which project it is in. Nil when nothing matched.
    ///
    /// An empty needle matches nothing. A caller that wants "everything" when the field is empty
    /// checks that itself, because "no filter" and "no matches" are different answers and only the
    /// caller knows which one its list wants.
    public static func match(workspace: Workspace, repo: Repo?, needle: String) -> String? {
        guard !needle.isEmpty else { return nil }
        if workspace.name.lowercased().contains(needle) { return workspace.name }
        if workspace.branch.lowercased().contains(needle) { return workspace.branch }
        if let repo, repo.name.lowercased().contains(needle) { return repo.name }
        return nil
    }

    /// True when the needle is empty, which is the "show everything" reading a filter field wants.
    public static func matchesOrIsUnfiltered(workspace: Workspace, repo: Repo?, needle: String) -> Bool {
        needle.isEmpty || match(workspace: workspace, repo: repo, needle: needle) != nil
    }
}
