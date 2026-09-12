import Foundation

/// All creation choices originate on the execution host. No client guesses installed agents,
/// model defaults, repository paths or setup commands from its own device.
public struct RemoteWorkspaceService: Sendable {
    public let client: any RemoteRequesting
    public init(client: any RemoteRequesting) { self.client = client }

    public func catalogue() async throws -> RemoteCatalogue {
        try await RemoteCatalogue.decode(client.request(.call("catalogue")))
    }

    public func diagnostics() async throws -> ServerDiagnostics {
        try await ServerDiagnostics.decode(client.request(.call("diagnostics")))
    }

    public func workspaceCommand(project: RemoteProject, name: String, prompt: String) async throws -> RemoteCommand {
        let context = try await workspaceContext(projectID: project.id)
        let request = try RemoteCreationRequest.planned(project: project, name: name, prompt: prompt, mode: .chat,
            context: context, controls: context.composer.controls, baseBranch: project.defaultBranch,
            checkout: nil, runSetupScript: true)
        return try creationCommand(request)
    }

    public func transcript(sessionID: SessionID, after sequence: Int) async throws -> RemoteTranscript {
        try await RemoteTranscript.decode(client.request(.call("transcript", [
            "sessionID": .string(sessionID.rawValue), "afterSeq": .integer(sequence)
        ])))
    }
}
