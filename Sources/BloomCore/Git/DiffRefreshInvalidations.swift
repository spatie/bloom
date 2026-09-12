import Foundation

/// A completed Git read can acknowledge only the file events that preceded it. Events that
/// arrived while that read was suspended remain pending for the next pass.
public struct DiffRefreshInvalidations: Sendable {
    public private(set) var pending: Set<WorkspaceID> = []
    private var generations: [WorkspaceID: UInt64] = [:]

    public init() {}

    public mutating func record(_ ids: Set<WorkspaceID>) {
        for id in ids {
            generations[id, default: 0] &+= 1
            pending.insert(id)
        }
    }

    public func generation(for id: WorkspaceID) -> UInt64 { generations[id, default: 0] }

    public mutating func finish(_ id: WorkspaceID, generation: UInt64, succeeded: Bool) {
        if succeeded, generation == self.generation(for: id) {
            pending.remove(id)
        } else {
            pending.insert(id)
        }
    }

    public mutating func retain(_ ids: Set<WorkspaceID>) {
        pending.formIntersection(ids)
        generations = generations.filter { ids.contains($0.key) }
    }
}
