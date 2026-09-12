import Foundation

/// Presentation choices are read on the host that will execute the next turn.
public struct ServerComposerState: Codable, Sendable {
    public var controls: ComposerControls
    public var models: [CodexModel]
    public var commands: [SlashCommand]
    public var styles: [OutputStyle]
    public var availableAgents: [AgentKind]?
}

enum ServerComposer {
    static func controls(session: Session, store: Store) async throws -> ComposerControls {
        ComposerControls(session: session,
            isFastMode: try await store.setting(ComposerControls.fastModeKey(sessionID: session.id)) == "1",
            outputStyle: try await store.setting(ComposerControls.outputStyleKey(sessionID: session.id)) ?? OutputStyle.defaultName,
            codexContextWindow: CodexContextWindow.normalised(try await store.setting(ComposerControls.contextWindowKey(sessionID: session.id))))
    }

    static func save(_ controls: ComposerControls, session: Session, store: Store) async throws {
        try await store.updateSessionPreferences(id: session.id, model: controls.model, effort: controls.effort,
            permissionMode: controls.permissionMode, agentKind: controls.agentKind)
        for (key, value) in controls.settings(sessionID: session.id) { try await store.setSetting(key, value) }
    }
}

/// Executable availability belongs to the machine that launches the turn.
public enum ServerAgentAvailability {
    public static func installed(store: Store) async -> [AgentKind] {
        let overrides = await AgentCatalog.executablePathOverrides(in: store)
        return AgentCatalog.installedKinds(overrides: overrides).filter(\.canRunWorkspaces)
    }

    public static func require(_ agent: AgentKind, in available: [AgentKind]) throws {
        guard available.contains(agent) else {
            throw ServerFailure("\(agent.label) is not installed on this server. Choose an installed agent in the model menu, or install and sign in to \(agent.label) on the server.")
        }
    }

    /// Only new-workspace defaults may fall back. Existing conversations keep their chosen agent.
    public static func defaults(_ preferred: ComposerControls, available: [AgentKind], models: [CodexModel]) -> ComposerControls {
        guard !available.contains(preferred.agentKind) else { return preferred }
        var controls = preferred
        if available.contains(.codex), let model = models.first(where: { $0.isDefault && !$0.hidden }) ?? models.first(where: { !$0.hidden }) {
            controls.agentKind = .codex
            controls.model = model.id
            controls.effort = model.resolvedEffort(preferring: preferred.effort)
        } else if available.contains(.claudeCode) {
            controls.agentKind = .claudeCode
            controls.model = AppDefaults.fallbackModel
            controls.effort = AppDefaults.fallbackEffort
        }
        return controls
    }
}
