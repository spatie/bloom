import Testing
@testable import BloomCore

struct WorkspaceColumnCacheTests {
    @Test func keepsTheCurrentAndPreviousWorkspace() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")
        let third = WorkspaceID("third")

        var columns = WorkspaceColumnCache.visiting(first, in: [], capacity: 2)
        columns = WorkspaceColumnCache.visiting(second, in: columns, capacity: 2)
        columns = WorkspaceColumnCache.visiting(third, in: columns, capacity: 2)

        #expect(columns == [third, second])
    }

    @Test func keepsTheTenMostRecentlyVisitedWorkspacesByDefault() {
        let workspaces = (1...12).map { WorkspaceID("workspace-\($0)") }
        var columns: [WorkspaceID] = []
        for workspace in workspaces {
            columns = WorkspaceColumnCache.visiting(workspace, in: columns)
        }

        #expect(columns == Array(workspaces.dropFirst(2).reversed()))
    }

    @Test(arguments: [(-1, 10), (0, 10), (1, 1), (2, 2), (32, 32), (500, 32)])
    func resolvesStatedCapacity(stated: Int, expected: Int) {
        #expect(WorkspaceColumnCache.capacity(stated: stated) == expected)
    }

    @Test(arguments: [-1, 0, 1])
    func alwaysRetainsTheCurrentWorkspace(capacity: Int) {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")

        let columns = WorkspaceColumnCache.visiting(second, in: [first], capacity: capacity)

        #expect(columns == [second])
    }

    @Test func loweringCapacityEvictsOlderWorkspacesOnTheNextVisit() {
        let workspaces = (1...10).map { WorkspaceID("workspace-\($0)") }

        let columns = WorkspaceColumnCache.visiting(workspaces[4], in: workspaces, capacity: 2)

        #expect(columns == [workspaces[4], workspaces[0]])
    }

    @Test func revisitingMakesAWorkspaceCurrentWithoutDuplicatingIt() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")

        let columns = WorkspaceColumnCache.visiting(first, in: [second, first])

        #expect(columns == [first, second])
    }

    @Test func removesAWorkspaceThatNoLongerHasAModel() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")

        let columns = WorkspaceColumnCache.removing(first, from: [second, first])

        #expect(columns == [second])
    }

    @Test func keepsRetainedViewsInPlaceWhenRecencyReverses() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")

        let columns = WorkspaceColumnCache.stableMembers(
            [first, second], from: [second, first]
        )

        #expect(columns == [first, second])
    }

    @Test func replacesOnlyTheEvictedView() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")
        let third = WorkspaceID("third")

        let columns = WorkspaceColumnCache.stableMembers(
            [first, second], from: [third, second]
        )

        #expect(columns == [second, third])
    }
}
