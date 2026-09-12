import Foundation

/// Both the desktop runtime and the standalone server launch the same agent implementations.
/// Ownership stays with the caller, which must keep exactly one runner per session.
public enum SessionRunnerFactory {
    public static func make(
        session: Session,
        workspacePath: String,
        store: Store,
        bridge: BridgeHandle? = nil
    ) -> any SessionRunner {
        switch session.agentKind {
        case .codex:
            CodexRunner(workspacePath: workspacePath, session: session, store: store, bridge: bridge?.attachment)
        case .grok:
            GrokRunner(workspacePath: workspacePath, session: session, store: store, bridge: bridge?.attachment)
        case .claudeCode, .cursor, .openCode:
            AgentRunner(workspacePath: workspacePath, session: session, store: store, mcpConfigPath: bridge?.mcpConfigPath)
        }
    }
}
