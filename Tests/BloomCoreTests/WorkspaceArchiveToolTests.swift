import Foundation
import Testing
@testable import BloomCore

struct WorkspaceArchiveToolTests {
    @Test("archive is owner-only and is never self-approved")
    func permissions() {
        let tool = WorkspaceArchiveTool { _ in .archived }
        let toolbox = BridgeToolbox(handlers: [tool])
        #expect(toolbox.handler(named: "workspace_archive", for: .owner) != nil)
        #expect(toolbox.handler(named: "workspace_archive", for: .parent) == nil)
        #expect(toolbox.handler(named: "workspace_archive", for: .child) == nil)
        #expect(!BridgeToolApproval.selfApproved.contains("workspace_archive"))
    }

    @Test("archive requires an exact id and never accepts force or branch deletion")
    func arguments() async throws {
        let (store, workspace) = try await fixture()
        let calls = ArchiveCalls()
        let tool = WorkspaceArchiveTool { workspace in
            await calls.record(workspace.id)
            return .archived
        }
        for arguments: [String: JSONValue] in [
            [:], ["id": .integer(1)], ["id": .string(" ")],
            ["id": .string(workspace.name)],
            ["id": .string(workspace.id.rawValue), "force": .bool(true)],
            ["id": .string(workspace.id.rawValue), "delete_branch": .bool(true)],
        ] {
            let result = await tool.call(request(arguments), as: .owner, store: store)
            #expect(result.isError)
        }
        #expect(await calls.ids.isEmpty)
    }

    @Test("a direct call cannot bypass the role gate")
    func directRoleGate() async throws {
        let (store, workspace) = try await fixture()
        let tool = WorkspaceArchiveTool { _ in
            Issue.record("unauthorised archive reached the app")
            return .archived
        }
        let identity = BridgeIdentity(sessionID: SessionID("parent-session"), workspaceID: workspace.id, role: .parent)
        let result = await tool.call(request(["id": .string(workspace.id.rawValue)]), as: identity, store: store)
        #expect(result.isError)
    }

    @Test("already archived is an idempotent no-op")
    func alreadyArchived() async throws {
        let (store, workspace) = try await fixture(state: .archived)
        let tool = WorkspaceArchiveTool { _ in
            Issue.record("an archived workspace reached the app again")
            return .archived
        }
        let result = await tool.call(request(["id": .string(workspace.id.rawValue)]), as: .owner, store: store)
        #expect(!result.isError)
        #expect(result.text.contains("already archived"))
    }

    @Test("running and waiting sessions prevent archive", arguments: [SessionState.running, .waiting])
    func busySession(_ state: SessionState) async throws {
        let (store, workspace) = try await fixture()
        var session = Session(workspaceID: workspace.id, title: "Busy")
        session.state = state
        try await store.upsert(session)
        let tool = WorkspaceArchiveTool { _ in
            Issue.record("a busy workspace reached the app")
            return .archived
        }
        let result = await tool.call(request(["id": .string(workspace.id.rawValue)]), as: .owner, store: store)
        #expect(result.isError)
    }

    @Test("running setup and queued messages prevent archive", arguments: [true, false])
    func pendingWork(_ setup: Bool) async throws {
        let (store, workspace) = try await fixture()
        if setup {
            var preparing = workspace
            preparing.setupState = .running
            try await store.upsert(preparing)
        } else {
            let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Queued"))
            try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "Work still to do"))
        }
        let tool = WorkspaceArchiveTool { _ in
            Issue.record("pending work reached the archive lifecycle")
            return .archived
        }
        let result = await tool.call(request(["id": .string(workspace.id.rawValue)]), as: .owner, store: store)
        #expect(result.isError)
        #expect(try await store.workspace(id: workspace.id)?.state == .active)
    }

    @Test("app safety and archive failures reach the caller without a success claim")
    func refusal() async throws {
        let (store, workspace) = try await fixture()
        let tool = WorkspaceArchiveTool { _ in .refused("There are uncommitted changes.") }
        let result = await tool.call(request(["id": .string(workspace.id.rawValue)]), as: .owner, store: store)
        #expect(result.isError)
        #expect(result.text.contains("uncommitted changes"))
        #expect(try await store.workspace(id: workspace.id)?.state == .active)
    }

    @Test("completion identifies the archived workspace and retained history")
    func completion() async throws {
        let (store, workspace) = try await fixture()
        let calls = ArchiveCalls()
        let tool = WorkspaceArchiveTool { workspace in
            await calls.record(workspace.id)
            return .archived
        }
        let result = await tool.call(request(["id": .string(workspace.id.rawValue)]), as: .owner, store: store)
        #expect(!result.isError)
        #expect(await calls.ids == [workspace.id])
        #expect(result.text.contains(workspace.name))
        #expect(result.text.contains("branch, notes and chat history were kept"))
    }

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .integer(1), method: "workspace_archive", params: .object(arguments))
    }

    private func fixture(state: WorkspaceState = .active) async throws -> (Store, Workspace) {
        let store = try makeTestStore("archive-tool")
        let repo = try await store.upsert(Repo(name: "Archive tool", path: "/tmp/archive-tool"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Finished review", branch: "review", path: "/tmp/archive-tool-review",
            baseBranch: "main", state: state
        ))
        return (store, workspace)
    }
}

private actor ArchiveCalls {
    var ids: [WorkspaceID] = []
    func record(_ id: WorkspaceID) { ids.append(id) }
}
