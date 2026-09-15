import Foundation

/// How the sidebar arranges the workspaces it draws.
///
/// Two answers to one question, and the question is what the pane is for. Grouped by project it is
/// a map of the work: every project, its workspaces under it, in an order the owner chose by
/// dragging. Grouped by status it is a queue: what is waiting on an answer, what has finished and
/// not been read, what is still going, and what is quiet. Neither is a filter. Every workspace is
/// in both, and nothing is hidden by switching.
///
/// In the core rather than beside the view, because the grouping is read by the rows, by the status
/// bar and by what the drag is allowed to do, and a value three views agree on is a value worth
/// being able to test. See `SidebarStatusGroup` for what the second one sorts rows into.
public enum SidebarGrouping: String, CaseIterable, Sendable, Hashable {
    /// Projects, each with its workspaces under it. What the pane has always been.
    case projects
    /// One run of sections, by what each workspace needs from the person reading.
    case status

    /// Where the choice is kept.
    ///
    /// A preference rather than window state, and the same reasoning `ProjectVisibility.showsHiddenKey`
    /// carries: which shape of the pane somebody works in is a decision they make once, not a
    /// question they answer per window and certainly not one to be asked again on every launch.
    public static let storageKey = "sidebar.grouping"

    /// What the control at the foot of the pane calls it.
    public var title: String {
        switch self {
        case .projects: "Projects"
        case .status: "Status"
        }
    }

    /// Whether rows can be dragged into a new order in this shape.
    ///
    /// Only in `projects`. An order the owner chose by hand has nowhere to live in a pane whose
    /// sections are decided by what each agent is doing: a row dropped between two others would be
    /// moved back by the next turn that ended. The drag is therefore refused rather than accepted
    /// and quietly undone, which is the same judgement `SidebarReorder` makes about a row let go
    /// over another project.
    public var allowsReordering: Bool { self == .projects }
}
