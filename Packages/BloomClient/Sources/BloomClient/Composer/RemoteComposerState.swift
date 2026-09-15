import Foundation

/// The execution host supplies the controls and catalogues. Clients never inspect their own CLIs.
public struct RemoteComposerState: Codable, Sendable, Equatable {
    public var controls: ComposerControls
    public var models: [CodexModel]
    public var commands: [SlashCommand]
    public var styles: [OutputStyle]
    public var availableAgents: [AgentKind]?
    public var authentication: [AgentAuthenticationStatus]?
    /// Codex's speed for each catalogue model, read from the server's own Codex configuration
    /// for this checkout. Optional and synthesised with `decodeIfPresent`, so a server that
    /// predates it decodes as nil and the switch stays unavailable rather than guessed.
    public var codexSpeeds: [String: CodexSpeed]?

    public init(controls: ComposerControls, models: [CodexModel] = [], commands: [SlashCommand] = [],
                styles: [OutputStyle] = [], availableAgents: [AgentKind]? = nil, authentication: [AgentAuthenticationStatus]? = nil,
                codexSpeeds: [String: CodexSpeed]? = nil) {
        self.controls = controls; self.models = models; self.commands = commands
        self.styles = styles; self.availableAgents = availableAgents; self.authentication = authentication
        self.codexSpeeds = codexSpeeds
    }

    public var choices: ComposerModelChoices { ComposerModelChoices(codexModels: models, availableAgents: availableAgents) }

    /// The speed switch for the model the controls name, never this machine's Codex.
    public func codexSpeed(for model: String) -> CodexSpeedReading {
        .reported(codexSpeeds, model: model, isLoaded: true)
    }

    public static func decode(_ result: JSONValue) throws -> Self {
        guard let state = result["composer"]?["_0"] else { throw ConnectionFailure("The server did not return composer settings.") }
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(state))
    }
}

public extension RemoteWorkspaceService {
    /// Older servers ignore unknown send fields, so prove support before adding a retry ID.
    func retryAuthenticationPausedPrompt(sessionID: SessionID, deliveryID: DeliveryID, text: String) async throws {
        let state = try await composer(sessionID: sessionID)
        guard state.authentication != nil else {
            throw ConnectionRefusal("Update Bloom Server before retrying a prompt paused for sign-in.")
        }
        _ = try await client.request(.call("send", ["sessionID": .string(sessionID.rawValue),
            "text": .string(text), "retryDeliveryID": .string(deliveryID.rawValue)]))
    }
}
