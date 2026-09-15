import Foundation

/// Adapts discovery to model selection. Register a fetched backend here; the composer and bridge
/// consume the same description without knowing which protocol supplied it.
public struct AgentModelSource: Sendable {
    public let models: @Sendable () async throws -> [AgentModel]
    public let invalidate: @Sendable () async -> Void

    public init(
        models: @escaping @Sendable () async throws -> [AgentModel],
        invalidate: @escaping @Sendable () async -> Void
    ) {
        self.models = models
        self.invalidate = invalidate
    }

    public static func live(store: Store? = nil) -> [AgentKind: AgentModelSource] {
        let codex = CodexModelCatalog.live()
        let grok = GrokModelCatalog.live(store: store)
        return [
            .codex: AgentModelSource(
                models: { try await codex.models().map(\.agentModel) },
                invalidate: { await codex.invalidate() }
            ),
            .grok: AgentModelSource(
                models: { try await grok.models().map(\.agentModel) },
                invalidate: { await grok.invalidate() }
            ),
        ]
    }
}
