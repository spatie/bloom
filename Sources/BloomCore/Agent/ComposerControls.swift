import Foundation
import BloomClient

public typealias ComposerControls = BloomClient.ComposerControls

// Session and persistence adaptation belongs to the execution host.
extension ComposerControls {
    public init(
        session: Session,
        isFastMode: Bool,
        outputStyle: String,
        codexContextWindow: Int = CodexContextWindow.modelDefault
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
            hasWorktree: session.workspaceID != nil
        )
    }

    /// What a session that does not exist yet should start out as, by the rules in
    /// `ComposerDefaults` plus the one thing those rules do not cover.
    public init(
        defaults: ComposerDefaults,
        isFastMode: Bool,
        outputStyle: String,
        codexContextWindow: Int = CodexContextWindow.modelDefault
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
            codexContextWindow: codexContextWindow
        )
    }

    /// Writes the parts of these choices that a `Session` row cannot hold, and marks the session
    /// settled. The other four go on the row itself, wherever it is being written.
    ///
    /// All three store nil for their off state rather than a word for it, so a session that was
    /// never asked and one that was asked and said no read back the same. `AgentRunner` and
    /// `CodexRunner` treat them the same too, which is what keeps the two ends from disagreeing.
    public func store(sessionID: SessionID, in store: Store) async {
        try? await store.saveComposerControls(self, sessionID: sessionID)
    }

    func settings(sessionID: SessionID) -> [(String, String?)] {
        [
            (Self.fastModeKey(sessionID: sessionID), isFastMode ? "1" : nil),
            (Self.outputStyleKey(sessionID: sessionID), OutputStyle.isDefault(outputStyle) ? nil : outputStyle),
            (Self.contextWindowKey(sessionID: sessionID), CodexContextWindow.stored(codexContextWindow)),
            (Self.defaultsAppliedKey(sessionID: sessionID), "1"),
        ]
    }
}
