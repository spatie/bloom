import Foundation
import BloomClient

/// Which Docker resources on this server are left over from workspaces that are not active.
///
/// Only what `WorkspaceDockerOwnership` attributes to a workspace is ever a candidate. An
/// unlabelled container, a volume from a project that never put the workspace id in its compose
/// project, and the shared dev image are not listed, because a panel with a Remove All button is
/// the last place a guess belongs.
///
/// "Unknown" is a workspace id this server has no row for. The private rootless engine belongs to
/// this one server account, so an id it does not know is a workspace removed with its project,
/// not somebody else's. That reasoning does not hold on a Mac, where Bloom and Bloom Dev share
/// Docker Desktop and each would call the other's workspaces unknown, which is why there is no
/// local equivalent of this panel.
enum ServerStorageLeftovers {
    static func classify(_ entries: [WorkspaceDockerInventory.Entry], workspaces: [Workspace]) -> [ServerStorageLeftover] {
        let known = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [WorkspaceID: [WorkspaceDockerResource]] = [:]
        for entry in entries where known[entry.workspaceID]?.state != .active {
            grouped[entry.workspaceID, default: []].append(entry.resource)
        }
        return grouped.map { id, resources in
            let workspace = known[id]
            return ServerStorageLeftover(workspaceID: id, workspaceName: workspace?.name,
                owner: workspace == nil ? .unknown : .archived,
                resources: resources.sorted { ($0.kind.sortOrder, $0.name) < ($1.kind.sortOrder, $1.name) })
        }
        .sorted { lhs, rhs in
            if lhs.owner != rhs.owner { return lhs.owner == .archived }
            return (lhs.workspaceName ?? "", lhs.workspaceID.rawValue) < (rhs.workspaceName ?? "", rhs.workspaceID.rawValue)
        }
    }
}

private extension WorkspaceDockerResource.Kind {
    var sortOrder: Int {
        switch self {
        case .container: 0
        case .volume: 1
        case .network: 2
        }
    }
}
