/// The workspace columns worth keeping laid out for an immediate return.
///
/// A workspace switch used to hand one transcript table a different conversation. Even when both
/// conversations were already in memory, the table had to hide itself, replace its rows, restore
/// the reader's place and reveal again. Keeping the workspace being left beside the one being
/// entered gives returning workspaces stable view identities instead.
///
/// Ten covers working across several task workspaces without retaining every column visited in
/// a day. Bart measured roughly half the switching time across eight mixed-pane workspaces,
/// at about 20 MB per extra retained column. The default can be lowered on memory-limited Macs.
public enum WorkspaceColumnCache {
    public static let capacity = 10
    public static let capacityKey = "workspace.columnCache"
    public static let maximumCapacity = 32

    public static func capacity(stated: Int) -> Int {
        stated <= 0 ? capacity : min(max(stated, 1), maximumCapacity)
    }

    /// Most recently visited first, with each workspace present at most once.
    public static func visiting(
        _ id: WorkspaceID, in current: [WorkspaceID], capacity: Int = WorkspaceColumnCache.capacity
    ) -> [WorkspaceID] {
        var next = [id]
        next.append(contentsOf: current.lazy.filter { $0 != id }.prefix(max(capacity, 1) - 1))
        return next
    }

    public static func removing(_ id: WorkspaceID, from current: [WorkspaceID]) -> [WorkspaceID] {
        current.filter { $0 != id }
    }

    /// Keeps surviving view identities in their existing order while applying the membership of
    /// the recency list. A back-and-forth visit then changes no observed collection and SwiftUI
    /// does not move two large AppKit subtrees merely to reverse their order in a `ZStack`.
    public static func stableMembers(
        _ current: [WorkspaceID], from recency: [WorkspaceID]
    ) -> [WorkspaceID] {
        let wanted = Set(recency)
        var members = current.filter(wanted.contains)
        members.append(contentsOf: recency.filter { !members.contains($0) }.reversed())
        return members
    }
}
