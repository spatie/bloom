import Foundation
import BloomClient

public typealias ServerComposerState = BloomClient.RemoteComposerState

enum ServerComposer {
    /// Reads back every key `save` writes. Codex's speed override was written and never read, so
    /// the next `setComposer` or `configure` carried nil into `save`, which deletes the row: a
    /// model change from any client quietly turned fast mode back to the server's default.
    static func controls(session: Session, store: Store) async throws -> ComposerControls {
        ComposerControls(session: session,
            isFastMode: try await store.setting(ComposerControls.fastModeKey(sessionID: session.id)) == "1",
            outputStyle: try await store.setting(ComposerControls.outputStyleKey(sessionID: session.id)) ?? OutputStyle.defaultName,
            codexContextWindow: CodexContextWindow.normalised(try await store.setting(ComposerControls.contextWindowKey(sessionID: session.id))),
            codexFastMode: CodexSpeed.override(stored: try await store.setting(CodexSpeed.key(sessionID: session.id))))
    }

    /// The server's own Codex speeds for a checkout, or nil when there is nothing true to report:
    /// Codex is not installed here, it could not be read, or the checkout wraps its agents in an
    /// execution command, where the Codex that runs the turn is not the one this process can ask.
    static func codexSpeeds(cwd: String, available: [AgentKind], wrapped: Bool,
                            read: @Sendable (String) async throws -> [String: CodexSpeed] = CodexSpeed.readAll) async -> [String: CodexSpeed]? {
        guard available.contains(.codex), !wrapped else { return nil }
        return try? await read(cwd)
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
