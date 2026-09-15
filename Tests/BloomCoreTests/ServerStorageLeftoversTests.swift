import Foundation
import Testing
import BloomClient
@testable import BloomCore

/// Storage & Cleanup's leftover list, and the removal that rechecks it on the server.
@Suite struct ServerStorageLeftoversTests {
    static let configuration = ServerStorageDocker.Configuration(home: "/home/bloom", uid: 995, supported: true)
    static let usage = """
    {"Type":"Images","TotalCount":"1","Active":"1","Size":"1GB","Reclaimable":"0B (0%)"}
    {"Type":"Containers","TotalCount":"2","Active":"2","Size":"1MB","Reclaimable":"0B (0%)"}
    {"Type":"Local Volumes","TotalCount":"2","Active":"1","Size":"84MB","Reclaimable":"42MB (50%)"}
    {"Type":"Build Cache","TotalCount":"0","Active":"0","Size":"0B","Reclaimable":"0B"}
    """
    private func workspace(_ id: WorkspaceID, name: String, state: WorkspaceState) -> Workspace {
        var value = Workspace(id: id, repoID: RepoID("repo"), name: name, branch: name, path: "/w/" + name, baseBranch: "main")
        value.state = state
        return value
    }

    private func entry(_ id: WorkspaceID, _ kind: WorkspaceDockerResource.Kind, _ name: String) -> WorkspaceDockerInventory.Entry {
        .init(workspaceID: id, resource: .init(kind: kind, name: name))
    }

    @Test func activeWorkspacesAreNeverLeftoversAndArchivedOnesComeBeforeUnknown() {
        let active = WorkspaceDockerOwnershipTests.first
        let archived = WorkspaceDockerOwnershipTests.second
        let gone = WorkspaceID("3f2504e0-4f89-41d3-9a0c-0305e82c3301")
        let leftovers = ServerStorageLeftovers.classify([
            entry(gone, .volume, "gone_db"),
            entry(active, .volume, "active_db"),
            entry(archived, .volume, "old_db"),
            entry(archived, .container, "old-web-1"),
        ], workspaces: [workspace(active, name: "live", state: .active), workspace(archived, name: "Old work", state: .archived)])
        #expect(leftovers.map(\.workspaceID) == [archived, gone])
        #expect(leftovers.map(\.owner) == [.archived, .unknown])
        #expect(leftovers[0].resources.map(\.name) == ["old-web-1", "old_db"])
        #expect(leftovers[0].title == "\u{201C}Old work\u{201D} (archived)")
        #expect(!leftovers.flatMap(\.resources).contains { $0.name == "active_db" })
    }

    @Test func theConfirmationNamesWhatGoesAndWhatStays() {
        let leftover = ServerStorageLeftover(workspaceID: WorkspaceDockerOwnershipTests.second, workspaceName: "Old", owner: .archived,
            resources: [.init(kind: .container, name: "web"), .init(kind: .volume, name: "db"), .init(kind: .volume, name: "redis")])
        let confirmation = ServerStorageLeftoverConfirmation(leftovers: [leftover], serverName: "box")
        #expect(confirmation.title == "Remove this workspace\u{2019}s containers and volumes on box?")
        #expect(confirmation.message.contains("1 container and 2 volumes"))
        #expect(confirmation.message.contains("Shared images and build cache are kept"))
    }

    @Test func removalRechecksAndSparesAWorkspaceRestoredSinceTheReport() async throws {
        let archived = WorkspaceDockerOwnershipTests.second
        let restored = WorkspaceDockerOwnershipTests.first
        let engine = LeftoverEngine()
        let docker = ServerStorageDocker(configuration: Self.configuration,
            run: { arguments, _, _, _ in await engine.run(arguments) }, validateFiles: {})
        let rows = [workspace(archived, name: "Old", state: .archived), workspace(restored, name: "Back", state: .active)]
        let service = ServerStorageService(directory: "/data", docker: docker, disk: { _ in (100, 40) }, workspaces: { rows })
        let result = try await service.removeLeftovers([archived, restored])
        #expect(result.outcomes.map(\.status) == [.completed, .failed])
        let removals = await engine.calls.filter { $0.contains("rm") }
        #expect(removals.allSatisfy { !$0.joined(separator: " ").contains("0f8fad5bd9cb469fa16570867728950e") })
        #expect(removals.contains { $0.contains("tt-7c9e6679742540de944be07fc1f90ae7_database") })
        #expect(result.report?.leftovers != nil)
    }

    @Test func aServiceWithoutWorkspaceRowsListsNoLeftovers() async throws {
        let engine = LeftoverEngine()
        let docker = ServerStorageDocker(configuration: Self.configuration,
            run: { arguments, _, _, _ in await engine.run(arguments) }, validateFiles: {})
        let service = ServerStorageService(directory: "/data", docker: docker, disk: { _ in (100, 40) })
        let report = await service.inspect()
        #expect(report.leftovers == nil)
        #expect(await engine.calls.allSatisfy { !$0.contains("ls") })
        await #expect(throws: ServerFailure.self) { try await service.removeLeftovers([WorkspaceDockerOwnershipTests.second]) }
    }
}

private actor LeftoverEngine {
    var calls: [[String]] = []
    private let fake = FakeEngine()

    func run(_ arguments: [String]) async -> ServerStorageDocker.Output {
        calls.append(arguments)
        if arguments == ["context", "show"] { return .init(status: 0, text: "rootless") }
        if arguments.first == "context" { return .init(status: 0, text: #""unix:///run/user/995/docker.sock""#) }
        let engine = Array(arguments.dropFirst(2))
        if engine.first == "info" { return .init(status: 0, text: #"{"root":"/home/bloom/bloom/docker/data","security":["name=rootless"]}"#) }
        if engine == ["system", "df", "--format", "json"] { return .init(status: 0, text: ServerStorageLeftoversTests.usage) }
        let output = await fake.run(engine)
        return .init(status: output.status, text: output.text)
    }
}
