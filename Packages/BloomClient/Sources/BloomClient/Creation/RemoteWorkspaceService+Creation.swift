import Foundation

public struct RemoteWorkspaceCreated: Decodable, Sendable {
    public let workspace: RemoteWorkspace
    public let session: RemoteSession?
    public let setupSucceeded: Bool?
    public let draft: String?

    public static func decode(_ result: JSONValue) throws -> Self {
        guard let value = result["creation"]?["_0"]?["workspaceStarted"] ?? result["created"] else {
            throw ConnectionFailure("The server did not confirm workspace creation. Retry the saved request.")
        }
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

public extension RemoteWorkspaceService {
    func githubRepositories(query: String, page: Int = 1) async throws -> [GitHubRepositoryListing] {
        guard query.utf8.count <= 256, (1...20).contains(page) else { throw ConnectionRefusal("Use a shorter repository search.") }
        return try decodeCreation(await client.request(creation("githubRepositories", ["query": .string(query), "page": .integer(page)])), field: "repositories", as: [GitHubRepositoryListing].self)
    }

    func importGitHubCommand(_ name: String) -> RemoteCommand { creation("importGitHub", ["_0": .string(name)]) }

    func importedProject(_ result: JSONValue) throws -> RemoteProject {
        try decodeCreation(result, field: "project", as: RemoteProject.self)
    }

    func workspaceContext(projectID: RepoID) async throws -> RemoteWorkspaceContext {
        try decodeCreation(await client.request(creation("workspaceContext", ["_0": .string(projectID.rawValue)])), field: "workspaceContext", as: RemoteWorkspaceContext.self)
    }

    func checkoutOptions(projectID: RepoID) async throws -> WorkspaceCheckoutOptions {
        try decodeCreation(await client.request(creation("checkouts", ["_0": .string(projectID.rawValue)])), field: "checkouts", as: WorkspaceCheckoutOptions.self)
    }

    func resolveReference(_ reference: String, projectID: RepoID) async throws -> WorkspaceCheckoutResolution {
        try decodeCreation(await client.request(creation("resolveReference", ["repoID": .string(projectID.rawValue), "reference": .string(reference)])), field: "reference", as: WorkspaceCheckoutResolution.self)
    }

    func creationCommand(_ request: RemoteCreationRequest, id: UUID = UUID()) throws -> RemoteCommand {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        return RemoteCommand(.object(["create": .object(["_0": value])]), id: id)
    }

    private func creation(_ name: String, _ arguments: [String: JSONValue]) -> RemoteCommand {
        .call("creation", ["_0": .object([name: .object(arguments)])])
    }

    private func decodeCreation<Value: Decodable>(_ result: JSONValue, field: String, as: Value.Type) throws -> Value {
        guard let value = result["creation"]?["_0"]?[field]?["_0"] else {
            throw ConnectionFailure("The server did not return the requested creation information.")
        }
        return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
