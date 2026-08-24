import Foundation

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
/// It lives here now, and the `Confirmation` it is wrapped in is an extension in the app target,
/// which is what the note left in its old home asked for. What forced the move was the running
/// agent sentence below: a rule about what a removal destroys, in words a person acts on, is
/// exactly the thing that has to be testable.
public enum ProjectRemoval {
    /// Says what disappears, named and counted, rather than asking "are you sure?" about nothing
    /// in particular.
    ///
    /// - Parameter workspaces: every workspace of this project, active and archived alike.
    /// - Parameter runningAgents: how many of them have an agent mid turn, right now.
    public static func consequences(workspaces: [Workspace], runningAgents: Int) -> String {
        let active = workspaces.filter { $0.state == .active }.count

        var text = "Bloom forgets this project"
        switch active {
        case 0 where workspaces.isEmpty: text += "."
        case 0: text += " and its \(workspaces.count) archived workspace\(workspaces.count == 1 ? "" : "s")."
        default:
            text += ", its \(active) active workspace\(active == 1 ? "" : "s") and their transcripts."
        }

        // The sentence the owner was missing. He removed a project with an agent still working in
        // it, and the first he knew of it was a modal about a foreign key. Archiving has said this
        // since it was written, and refuses to go ahead without asking; removing a project takes
        // every one of its workspaces at once and said nothing at all.
        if runningAgents == 1 {
            text += " An agent is working in one of them right now, and it is stopped."
        } else if runningAgents > 1 {
            text += " Agents are working in \(runningAgents) of them right now, and they are stopped."
        }

        text += " Nothing on disk is deleted: the repository stays where it is"
        if active > 0 {
            text += ", and the worktrees stay checked out, so they have to be removed with `git worktree remove` if they are no longer wanted"
        }
        return text + "."
    }
}
