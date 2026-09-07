import Foundation

/// Owned by the sidebar so an optimistic archive can remove and restore its source row.
public struct SidebarArchivePresentation: Sendable {
    public enum Source: Sendable { case button, menu, row }

    public private(set) var workspaceID: WorkspaceID?
    public private(set) var source = Source.row
    public private(set) var request: ArchiveRequest?
    public private(set) var isRequesting = false
    private var generation = UUID()
    private var isVisible = false
    private var isReturningAfterArchive = false

    public init() {}

    public mutating func begin(workspaceID: WorkspaceID, source: Source) -> UUID {
        generation = UUID()
        self.workspaceID = workspaceID
        self.source = source
        request = nil
        isRequesting = true
        isVisible = true
        isReturningAfterArchive = false
        return generation
    }

    public mutating func present(_ request: ArchiveRequest, generation: UUID) {
        guard self.generation == generation, workspaceID == request.workspace.id,
              isVisible || isReturningAfterArchive else { return }
        self.request = request
    }

    public mutating func finish(generation: UUID) {
        guard self.generation == generation else { return }
        isRequesting = false
    }

    public mutating func rowAppeared(_ id: WorkspaceID) {
        guard workspaceID == id else { return }
        isVisible = true
        isReturningAfterArchive = false
    }

    public mutating func rowDisappeared(_ id: WorkspaceID, isArchiving: Bool) {
        guard workspaceID == id else { return }
        isVisible = false
        isReturningAfterArchive = isArchiving
        if !isArchiving { cancel() }
    }

    /// A second dismissal from SwiftUI must not cancel the archive the confirm button just began.
    public mutating func dismissRequest() {
        guard request != nil else { return }
        cancel()
    }

    public mutating func cancel() {
        generation = UUID()
        request = nil
        isRequesting = false
        isReturningAfterArchive = false
    }
}
