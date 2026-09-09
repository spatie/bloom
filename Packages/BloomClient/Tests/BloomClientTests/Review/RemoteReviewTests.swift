import Testing
@testable import BloomClient

struct RemoteReviewTests {
    @Test(arguments: [JSONValue.object([:]), .object(["files": .object(["_0": .array([.integer(2)])])])])
    func missingOrMalformedListingIsNotAnEmptyWorkspace(result: JSONValue) async {
        let service = RemoteWorkspaceService(client: ReviewReply(result: result))
        await #expect(throws: ConnectionFailure.self) {
            try await service.files(workspaceID: WorkspaceID("workspace"))
        }
    }

    @Test func malformedChangedFilesCannotDisappearSilently() async {
        let service = RemoteWorkspaceService(client: ReviewReply(result: .object([
            "reviewSnapshot": .object(["_0": .object([
                "revision": .string("revision"), "files": .array([.object(["path": .string("README.md")])]),
            ])]),
        ])))
        await #expect(throws: ConnectionFailure.self) {
            try await service.changes(workspaceID: WorkspaceID("workspace"))
        }
    }

    @Test func aDifferentFileIsNeverDisplayedUnderTheRequestedPath() async {
        let service = RemoteWorkspaceService(client: ReviewReply(result: .object([
            "file": .object(["_0": .object([
                "path": .string("another-file"), "text": .string("content"), "revision": .string("revision"),
            ])]),
        ])))
        await #expect(throws: ConnectionFailure.self) {
            try await service.readFile(workspaceID: WorkspaceID("workspace"), path: "README.md")
        }
    }

    @Test func transportFailureStaysVisible() async {
        let service = RemoteWorkspaceService(client: ReviewRefusal())
        do {
            _ = try await service.files(workspaceID: WorkspaceID("workspace"))
            Issue.record("Expected the server refusal")
        } catch {
            #expect(error.localizedDescription == "Workspace is unavailable.")
        }
    }
}

private struct ReviewReply: RemoteRequesting {
    let result: JSONValue
    func request(_ command: RemoteCommand) async throws -> JSONValue { result }
}

private struct ReviewRefusal: RemoteRequesting {
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        throw ConnectionRefusal("Workspace is unavailable.")
    }
}
