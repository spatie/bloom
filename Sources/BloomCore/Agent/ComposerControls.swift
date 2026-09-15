import Foundation
import BloomClient

public typealias ComposerControls = BloomClient.ComposerControls

// Session and persistence adaptation belongs to the execution host.
extension ComposerControls {
    public init(
        session: Session,
        isFastMode: Bool,
        outputStyle: String,
        codexContextWindow: Int = CodexContextWindow.modelDefault,
        codexFastMode: Bool? = nil
    ) {
        self.init(
            model: session.model,
            effort: session.effort,
            agentKind: session.agentKind,
            permissionMode: session.permissionMode,
            isFastMode: isFastMode,
            outputStyle: outputStyle,
            codexContextWindow: codexContextWindow,
            // Read off the row rather than passed in, so the one caller that has a chat with no
            // worktree cannot forget to say so.
            hasWorktree: session.workspaceID != nil,
            codexFastMode: codexFastMode,
            interactionMode: session.interactionMode
        )
    }

    /// What a session that does not exist yet should start out as, by the rules in
    /// `ComposerDefaults` plus the one thing those rules do not cover.
    public init(
        defaults: ComposerDefaults,
        isFastMode: Bool,
        outputStyle: String,
        codexContextWindow: Int = CodexContextWindow.modelDefault,
        codexFastMode: Bool? = nil
    ) {
        self.init(
            model: defaults.model,
            effort: defaults.effort,
            // The backend comes with the model, so a Codex model set as the default opens a Codex
            // chat. It used to be left at `.claudeCode` here and in `AppModel.resolvedControls`,
            // which is what made the Models screen a Claude Code screen however it was set.
            agentKind: defaults.backend,
            permissionMode: defaults.permissionMode,
            isFastMode: isFastMode,
            outputStyle: outputStyle,
            codexContextWindow: codexContextWindow,
            codexFastMode: codexFastMode,
            interactionMode: defaults.interactionMode
        )
    }

    /// Writes the parts of these choices that a `Session` row cannot hold, and marks the session
    /// settled. The other four go on the row itself, wherever it is being written.
    ///
    /// Codex speed preserves an explicit off value because absence inherits external settings.
    public func store(sessionID: SessionID, in store: Store) async {
        try? await store.saveComposerControls(self, sessionID: sessionID)
    }

    func settings(sessionID: SessionID) -> [(String, String?)] {
        [
            (Self.fastModeKey(sessionID: sessionID), isFastMode ? "1" : nil),
            (CodexSpeed.key(sessionID: sessionID), codexFastMode.map { $0 ? "1" : "0" }),
            (Self.outputStyleKey(sessionID: sessionID), OutputStyle.isDefault(outputStyle) ? nil : outputStyle),
            (Self.contextWindowKey(sessionID: sessionID), CodexContextWindow.stored(codexContextWindow)),
            (Self.defaultsAppliedKey(sessionID: sessionID), "1"),
        ]
    }
}
