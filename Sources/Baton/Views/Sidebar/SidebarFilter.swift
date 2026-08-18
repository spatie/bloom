import BatonCore

/// What the Projects filter is currently letting through. Kept deliberately small: the sidebar is
/// a place to find one workspace fast, not a query builder.
enum SidebarFilter: String, CaseIterable, Hashable {
    case all = "All workspaces"
    case unread = "Unread"
    case changed = "With changes"

    func accepts(_ workspace: Workspace) -> Bool {
        switch self {
        case .all: true
        case .unread: workspace.unread
        case .changed: workspace.hasDiff
        }
    }

    var icon: String {
        switch self {
        case .all: "line.3.horizontal.decrease"
        case .unread: "circle.fill"
        case .changed: "plusminus"
        }
    }
}
