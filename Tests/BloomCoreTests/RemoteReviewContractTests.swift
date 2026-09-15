import Foundation
import Testing
import BloomClient
@testable import BloomCore

struct RemoteReviewContractTests {
    @Test(arguments: [false, true])
    func snapshotsKeepRevisionAndUnchangedSemantics(unchanged: Bool) async throws {
        var file = ChangedFile(path: "app/New.swift", oldPath: "app/Old.swift", change: .renamed, additions: 4, deletions: 2)
        file.contentRevision = "content-2"
        let client = try ReviewContractClient(.reviewSnapshot(.init(revision: "revision-2", files: unchanged ? nil : [file])))
        let result = try await RemoteWorkspaceService(client: client).changes(
            workspaceID: WorkspaceID("workspace"), scope: .uncommitted, knownRevision: "revision-1", wait: true
        )
        #expect(result.revision == "revision-2")
        #expect(result.files == (unchanged ? nil : [file]))
        let operation = try await client.operation()
        #expect(operation == .reviewSnapshot(workspaceID: WorkspaceID("workspace"), scope: .uncommitted, knownRevision: "revision-1", wait: true))
        #expect(operation.mutates == false)
    }

    @Test(arguments: [false, true])
    func patchesDecodeWithoutDroppingRevision(unchanged: Bool) async throws {
        let patch = "@@ -1 +1 @@\n-old\n+new\n"
        let client = try ReviewContractClient(.reviewPatch(.init(revision: "patch-2", patch: unchanged ? nil : patch)))
        let result = try await RemoteWorkspaceService(client: client).diff(
            workspaceID: WorkspaceID("workspace"), path: "README.md", knownRevision: "patch-1"
        )
        #expect(result.revision == "patch-2")
        #expect(result.patch == (unchanged ? nil : patch))
        let operation = try await client.operation()
        #expect(operation == .reviewPatch(workspaceID: WorkspaceID("workspace"), path: "README.md", scope: .branch, knownRevision: "patch-1"))
        #expect(operation.mutates == false)
    }

    @Test func fileTreeUsesTheServerListingAndSharedHierarchy() async throws {
        let paths = ["README.md", "app/Models/User.php", "app/Models/Team.php"]
        let client = try ReviewContractClient(.files(paths))
        let service = RemoteWorkspaceService(client: client)
        let files = try await service.files(workspaceID: WorkspaceID("workspace"))
        #expect(files == paths)
        let tree = try await service.fileTree(workspaceID: WorkspaceID("workspace"))
        #expect(tree == FileTreeNode.index(paths))
        #expect(tree[""]?.first?.isDirectory == true)
        let operation = try await client.operation()
        #expect(operation == .workspace(workspaceID: WorkspaceID("workspace"), action: .files))
        #expect(operation.mutates == false)
    }

    @Test func readFilePreservesSourceAndServerRevision() async throws {
        let file = ServerTextFile(path: "README.md", text: "# Café\n\nHello 👋\n")
        let client = try ReviewContractClient(.file(file))
        let result = try await RemoteWorkspaceService(client: client).readFile(workspaceID: WorkspaceID("workspace"), path: file.path)
        #expect(result.path == file.path)
        #expect(result.text == file.text)
        #expect(result.revision == file.revision)
        let operation = try await client.operation()
        #expect(operation == .file(workspaceID: WorkspaceID("workspace"), path: file.path))
        #expect(operation.mutates == false)
    }
}

private actor ReviewContractClient: RemoteRequesting {
    private let result: BloomClient.JSONValue
    private var command: RemoteCommand?

    init(_ result: ServerResult) throws {
        self.result = try JSONDecoder().decode(BloomClient.JSONValue.self, from: JSONEncoder().encode(result))
    }

    func request(_ command: RemoteCommand) async throws -> BloomClient.JSONValue {
        self.command = command
        return result
    }

    func operation() throws -> ServerOperation {
        let command = try #require(command)
        return try JSONDecoder().decode(ServerRequest.self, from: JSONEncoder().encode(command)).operation
    }
}
