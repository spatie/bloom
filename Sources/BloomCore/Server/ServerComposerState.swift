import Foundation

/// Presentation choices are read on the host that will execute the next turn.
public struct ServerComposerState: Codable, Sendable {
    public var controls: ComposerControls
    public var models: [CodexModel]
    public var commands: [SlashCommand]
    public var styles: [OutputStyle]
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
