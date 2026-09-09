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
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionFailure("Enter a workspace name and a prompt.")
        }
        let result = try await client.request(.call("creation", ["_0": .object([
            "workspaceContext": .object(["_0": .string(project.id.rawValue)])
        ])]))
        guard let context = result["creation"]?["_0"]?["workspaceContext"]?["_0"],
              let composer = context["composer"], let controls = composer["controls"],
              let agent = controls["agentKind"]?.stringValue,
              composer["availableAgents"]?.stringArray.contains(agent) == true,
              let model = controls["model"], let effort = controls["effort"], let mode = controls["permissionMode"] else {
            throw ConnectionFailure("No available agent was advertised. Configure an agent on Bloom Server first.")
        }
        return .call("create", ["_0": .object([
            "repositoryPath": .string(project.path), "name": .string(name), "prompt": .string(prompt),
            "agent": .string(agent), "model": model, "effort": effort, "permissionMode": mode,
            "controls": controls, "mode": .string("chat"), "runSetupScript": .bool(true)
        ])])
    }

    public func transcript(sessionID: SessionID, after sequence: Int) async throws -> RemoteTranscript {
        try await RemoteTranscript.decode(client.request(.call("transcript", [
            "sessionID": .string(sessionID.rawValue), "afterSeq": .integer(sequence)
        ])))
    }
}
