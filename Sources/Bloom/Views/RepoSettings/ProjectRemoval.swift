import Foundation
import BloomCore

/// What removing a project costs, said once.
///
/// Three places ask this question: the project's menu in the sidebar, the Projects pane in
/// Settings, and the project settings window's own Remove button. All three end in the same
/// `removeRepository`, and all three used to word the consequence themselves.
///
/// They had already drifted, which is the whole reason this exists. The sidebar said "Bloom
/// forgets this project and its workspaces. Nothing on disk is deleted."; Settings said "Existing
/// workspace records for this project will also be removed." and drew a dialog with no title at
/// all, because it was the one of the three missing `titleVisibility`; the settings window counted
/// the workspaces, told active apart from archived, and said the worktrees stay checked out. The
/// comment above that last one claimed it was "matching the sidebar's own removal confirmation,
/// which this cannot contradict", and by then it did.
///
/// The counted sentence is the one that survived: it is the only one that answers the question a
/// person actually has, which is what happens to the worktrees on disk.
///
/// **This belongs in `BloomCore`.** It is a rule about what a removal destroys, stated in words a
/// person acts on, and nothing in the test target can reach it here. It is written as a pure
/// function over core values so the move is a rename of the file it sits in, and it is not made
/// yet only because `Confirmation` is in the app target and `BloomCore` was being edited by
/// somebody else at the time. `ArchivedWorkspaceFootprint` is where its neighbour already lives.
enum ProjectRemoval {
    /// - Parameter workspaces: every workspace of this project, active and archived alike.
    static func confirmation(for repo: Repo, workspaces: [Workspace]) -> Confirmation {
        Confirmation(
            title: "Remove \(repo.name)?",
            message: consequences(workspaces: workspaces),
            confirmLabel: "Remove Project",
            cancelLabel: "Cancel"
        )
    }

    /// Says what disappears, named and counted, rather than asking "are you sure?" about nothing
    /// in particular.
    static func consequences(workspaces: [Workspace]) -> String {
        let active = workspaces.filter { $0.state == .active }.count

        var text = "Bloom forgets this project"
        switch active {
        case 0 where workspaces.isEmpty: text += "."
        case 0: text += " and its \(workspaces.count) archived workspace\(workspaces.count == 1 ? "" : "s")."
        default:
            text += ", its \(active) active workspace\(active == 1 ? "" : "s") and their transcripts."
        }
        text += " Nothing on disk is deleted: the repository stays where it is"
        if active > 0 {
            text += ", and the worktrees stay checked out, so they have to be removed with `git worktree remove` if they are no longer wanted"
        }
        return text + "."
    }
}
