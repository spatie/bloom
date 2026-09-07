import Testing
@testable import BloomCore

@Suite("Sidebar archive presentation")
struct SidebarArchivePresentationTests {
    @Test("a repeat safety question survives the archive removing and restoring its row")
    func optimisticRemoval() {
        var presentation = SidebarArchivePresentation()
        let request = request()
        let generation = presentation.begin(workspaceID: request.workspace.id, source: .menu)

        presentation.rowDisappeared(request.workspace.id, isArchiving: true)
        presentation.present(request, generation: generation)
        presentation.finish(generation: generation)
        presentation.rowAppeared(request.workspace.id)

        #expect(presentation.request?.id == request.id)
        #expect(presentation.source == .menu)
        #expect(!presentation.isRequesting)
    }

    @Test("filtering or collapsing the source row discards a delayed safety question")
    func voluntaryRemoval() {
        var presentation = SidebarArchivePresentation()
        let request = request()
        let generation = presentation.begin(workspaceID: request.workspace.id, source: .button)

        presentation.rowDisappeared(request.workspace.id, isArchiving: false)
        presentation.rowAppeared(request.workspace.id)
        presentation.present(request, generation: generation)

        #expect(presentation.request == nil)
        #expect(!presentation.isRequesting)
    }

    @Test("leaving the sidebar cancels even a question waiting for an archived row to return")
    func leavingSidebar() {
        var presentation = SidebarArchivePresentation()
        let request = request()
        let generation = presentation.begin(workspaceID: request.workspace.id, source: .row)

        presentation.rowDisappeared(request.workspace.id, isArchiving: true)
        presentation.cancel()
        presentation.present(request, generation: generation)
        presentation.rowAppeared(request.workspace.id)

        #expect(presentation.request == nil)
    }

    @Test("the newest archive action owns its source and pending report")
    func supersededAction() {
        var presentation = SidebarArchivePresentation()
        let first = request()
        let second = request()
        let oldGeneration = presentation.begin(workspaceID: first.workspace.id, source: .button)
        let generation = presentation.begin(workspaceID: second.workspace.id, source: .row)

        presentation.present(first, generation: oldGeneration)
        presentation.finish(generation: oldGeneration)
        #expect(presentation.request == nil)
        #expect(presentation.isRequesting)

        presentation.present(second, generation: generation)
        #expect(presentation.request?.id == second.id)
        #expect(presentation.source == .row)
    }

    @Test("a second dismissal does not cancel the action started by confirming")
    func duplicateDismissal() {
        var presentation = SidebarArchivePresentation()
        let request = request()
        let initial = presentation.begin(workspaceID: request.workspace.id, source: .button)
        presentation.present(request, generation: initial)
        presentation.dismissRequest()

        let confirmed = presentation.begin(workspaceID: request.workspace.id, source: .button)
        presentation.dismissRequest()
        presentation.present(request, generation: confirmed)

        #expect(presentation.request?.id == request.id)
        #expect(presentation.isRequesting)
    }

    @Test("another row leaving the list cannot cancel this workspace's confirmation")
    func unrelatedRow() {
        var presentation = SidebarArchivePresentation()
        let request = request()
        let generation = presentation.begin(workspaceID: request.workspace.id, source: .button)

        presentation.rowDisappeared(.new(), isArchiving: false)
        presentation.present(request, generation: generation)

        #expect(presentation.request?.workspace.id == request.workspace.id)
    }

    private func request() -> ArchiveRequest {
        ArchiveRequest(
            workspace: Workspace(
                repoID: .new(), name: "Archive example", branch: "example",
                path: "/tmp/archive-example", baseBranch: "main"
            ),
            report: WorkspaceSafetyReport()
        )
    }
}
