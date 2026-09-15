import Foundation
import Testing
import BloomClient
@testable import BloomCore

/// Which Docker resources an archive may delete. Every test here is a volume that either must go
/// with its workspace or must survive somebody else's archive.
@Suite struct WorkspaceDockerOwnershipTests {
    static let first = WorkspaceID("0f8fad5b-d9cb-469f-a165-70867728950e")
    static let second = WorkspaceID("7c9e6679-7425-40de-944b-e07fc1f90ae7")

    @Test func aComposeProjectNamingTheDashlessIdBelongsToThatWorkspace() {
        // The there-there.app shape: `bloom-tt-<id without dashes>`.
        let id = WorkspaceDockerOwnership.workspaceID(composeProject: "bloom-tt-0f8fad5bd9cb469fa16570867728950e", workspaceLabel: "")
        #expect(id == Self.first)
    }

    @Test func aComposeProjectNamingTheDashedIdBelongsToThatWorkspace() {
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: "app_0f8fad5b-d9cb-469f-a165-70867728950e", workspaceLabel: nil) == Self.first)
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: "APP-0F8FAD5BD9CB469FA16570867728950E", workspaceLabel: nil) == Self.first)
    }

    @Test func projectsWithoutAnIdAreNobodysEvenWhenTheyLookLikeBloom() {
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: "bloom-there-there", workspaceLabel: "") == nil)
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: "freekmurze-amundsen-sea", workspaceLabel: "") == nil)
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: nil, workspaceLabel: nil) == nil)
    }

    @Test func aHexRunInsideALongerHashIsNotAnId() {
        // A 40 character commit hash contains 32 hex characters, and is not a workspace.
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: "build-0f8fad5bd9cb469fa16570867728950e12345678", workspaceLabel: nil) == nil)
    }

    @Test func aProjectNamingTwoWorkspacesBelongsToNeither() {
        let project = "shared-0f8fad5bd9cb469fa16570867728950e-7c9e6679742540de944be07fc1f90ae7"
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: project, workspaceLabel: nil) == nil)
    }

    @Test func anExplicitLabelWinsAndIsNeverOverruledByTheProject() {
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: "x-0f8fad5bd9cb469fa16570867728950e",
            workspaceLabel: "7c9e6679-7425-40de-944b-e07fc1f90ae7") == Self.second)
        // A label that is not an id has said who owns the resource, and it is not a workspace.
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: "x-0f8fad5bd9cb469fa16570867728950e", workspaceLabel: "shared") == nil)
        #expect(WorkspaceDockerOwnership.workspaceID(composeProject: "", workspaceLabel: "7c9e6679742540de944be07fc1f90ae7") == Self.second)
    }

    @Test func listingsAreReadWithUnrelatedAndMalformedRowsLeftOut() {
        let containers = """
        bloom-tt-0f8fad5bd9cb469fa16570867728950e-postgres-1\trunning\tbloom-tt-0f8fad5bd9cb469fa16570867728950e\t
        bloom-tt-0f8fad5bd9cb469fa16570867728950e-agent-run-1\texited\tbloom-tt-0f8fad5bd9cb469fa16570867728950e\t
        unrelated\trunning\t\t
        -injected\trunning\tbloom-tt-0f8fad5bd9cb469fa16570867728950e\t
        short\trunning
        """
        let entries = WorkspaceDockerInventory.containers(containers)
        #expect(entries.map(\.resource.name) == [
            "bloom-tt-0f8fad5bd9cb469fa16570867728950e-postgres-1",
            "bloom-tt-0f8fad5bd9cb469fa16570867728950e-agent-run-1",
        ])
        #expect(entries.map(\.resource.isRunning) == [true, false])
        #expect(entries.allSatisfy { $0.workspaceID == Self.first })
        let volumes = WorkspaceDockerInventory.volumes("bloom-tt-7c9e6679742540de944be07fc1f90ae7_database\tbloom-tt-7c9e6679742540de944be07fc1f90ae7\t\nloose\t\t\n")
        #expect(volumes.map(\.resource.name) == ["bloom-tt-7c9e6679742540de944be07fc1f90ae7_database"])
        #expect(volumes.first?.workspaceID == Self.second)
    }

    @Test func sizesComeFromVerboseDiskUsageAndIgnoreTheSharedImage() {
        let json = #"{"Images":[],"Containers":[{"Names":"web-1","Size":"12kB (virtual 1.2GB)"}],"Volumes":[{"Name":"db","Size":"84MB"},{"Name":"odd","Size":"N/A"}]}"#
        let sizes = WorkspaceDockerInventory.sizes(json)
        #expect(sizes == ["container:web-1": "12kB", "volume:db": "84MB"])
        #expect(WorkspaceDockerInventory.sizes("not json").isEmpty)
    }

    @Test func removalListsAgainAndTakesOnlyThisWorkspaceInDockersOrder() async throws {
        let engine = FakeEngine()
        let docker = WorkspaceDocker(run: { arguments, _ in await engine.run(arguments) })
        try await docker.removeResources(of: Self.first)
        let removals = await engine.calls.filter { $0.contains("rm") }
        #expect(removals == [
            ["container", "rm", "--force", "--volumes", "--", "tt-0f8fad5bd9cb469fa16570867728950e-postgres-1"],
            ["volume", "rm", "--", "tt-0f8fad5bd9cb469fa16570867728950e_database"],
            ["network", "rm", "--", "tt-0f8fad5bd9cb469fa16570867728950e_default"],
        ])
        #expect(await engine.calls.allSatisfy { !$0.contains("image") })
    }

    @Test func aFootprintIsOfferedOnlyForContainersOrVolumes() async {
        let engine = FakeEngine()
        let docker = WorkspaceDocker(run: { arguments, _ in await engine.run(arguments) })
        let footprint = await docker.footprint(of: Self.first)
        #expect(footprint?.summary == "1 container and 1 volume")
        #expect(await docker.footprint(of: WorkspaceID("3f2504e0-4f89-41d3-9a0c-0305e82c3301")) == nil)
        let missing = WorkspaceDocker(run: { _, _ in throw CancellationError() })
        #expect(await missing.footprint(of: Self.first) == nil)
    }

    @Test func aRemovalDockerRefusesStopsWithItsReason() async {
        let engine = FakeEngine(failsVolumes: true)
        let docker = WorkspaceDocker(run: { arguments, _ in await engine.run(arguments) })
        await #expect(throws: WorkspaceDocker.Failure.self) { try await docker.removeResources(of: Self.first) }
        #expect(await engine.calls.contains { $0.first == "network" && $0.contains("rm") } == false)
        #expect(WorkspaceDocker.onlyMissing("Error response from daemon: No such container: web-1"))
        #expect(!WorkspaceDocker.onlyMissing("Error response from daemon: remove db: volume is in use"))
    }
}

actor FakeEngine {
    var calls: [[String]] = []
    let failsVolumes: Bool

    init(failsVolumes: Bool = false) { self.failsVolumes = failsVolumes }

    func run(_ arguments: [String]) -> WorkspaceDocker.Output {
        calls.append(arguments)
        let mine = "tt-0f8fad5bd9cb469fa16570867728950e"
        let theirs = "tt-7c9e6679742540de944be07fc1f90ae7"
        switch Array(arguments.prefix(2)) {
        case ["container", "ls"]:
            return .init(status: 0, text: "\(mine)-postgres-1\trunning\t\(mine)\t\n\(theirs)-postgres-1\trunning\t\(theirs)\t\nplain\trunning\t\t\n")
        case ["volume", "ls"]:
            return .init(status: 0, text: "\(mine)_database\t\(mine)\t\n\(theirs)_database\t\(theirs)\t\nshared\t\t\n")
        case ["network", "ls"]:
            return .init(status: 0, text: "\(mine)_default\t\(mine)\t\nbridge\t\t\n")
        case ["system", "df"]:
            return .init(status: 0, text: #"{"Containers":[{"Names":"\#(theirs)-postgres-1","Size":"1MB (virtual 900MB)"}],"Volumes":[{"Name":"\#(theirs)_database","Size":"84MB"}]}"#)
        case ["volume", "rm"] where failsVolumes:
            return .init(status: 1, text: "Error response from daemon: remove volume: volume is in use")
        default:
            return .init(status: 0, text: "")
        }
    }
}
