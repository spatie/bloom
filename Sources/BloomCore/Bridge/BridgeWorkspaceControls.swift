import Foundation
import BloomClient

/// One backend/model inheritance policy for workspace tools on every execution host.
public enum BridgeWorkspaceControls {
    public static func resolve(
        for order: AgentWorkspaceOrder,
        inheriting inherited: ComposerControls,
        store: Store? = nil
    ) async throws -> ComposerControls {
        var controls = inherited
        let inheritedAgent = controls.agentKind
        // A caller that names a model and no agent has named an agent, because a model id says
        // which CLI runs it. This used to be free: everything inherited Claude Code, so
        // `workspace_start(model: "opus")` could only mean Claude Code. It stopped being free the
        // moment the Models screen could make Codex the default, which would have turned that
        // same call into "opus is not a Codex model". No list is fetched to answer it: the four
        // families `ClaudeModelRank` knows are what the old reading covered, and anything else
        // stays on the backend that was inherited. See `DefaultBackend`.
        let agent = order.agent
            ?? order.model.map {
                DefaultBackend.kind(ofModel: $0, running: inheritedAgent)
            }
            ?? inheritedAgent
        controls.agentKind = agent

        switch agent {
        case .claudeCode:
            let models = Set(ComposerOption.models.map(\.id))
            if let model = order.model {
                guard models.contains(model) else {
                    throw BridgeWorkspaceModelFailure.invalid(
                        model: model,
                        agent: agent,
                        available: models.sorted()
                    )
                }
                controls.model = model
            } else if agent != inheritedAgent {
                controls.model = AppDefaults.fallbackModel
            }
        case .codex, .grok:
            if order.model == nil, agent == inheritedAgent { return controls }
            guard let source = AgentModelSource.live(store: store)[agent] else {
                throw BridgeWorkspaceModelFailure.noneAvailable(agent)
            }
            let models = try await source.models()
            guard let chosen = AgentModel.selection(requested: order.model, from: models) else {
                if let requested = order.model {
                    throw BridgeWorkspaceModelFailure.invalid(model: requested, agent: agent,
                        available: models.filter { !$0.hidden }.map(\.id))
                }
                throw BridgeWorkspaceModelFailure.noneAvailable(agent)
            }
            controls.model = chosen.id
            controls.effort = chosen.resolvedEffort(preferring: controls.effort)
        case .cursor, .openCode:
            throw BridgeWorkspaceModelFailure.noneAvailable(agent)
        }

        return controls
    }

}

private enum BridgeWorkspaceModelFailure: LocalizedError {
    case invalid(model: String, agent: AgentKind, available: [String])
    case noneAvailable(AgentKind)

    var errorDescription: String? {
        switch self {
        case let .invalid(model, agent, available):
            let choices = available.isEmpty ? "none were reported" : available.joined(separator: ", ")
            return "The model '\(model)' is not available for \(agent.label). Available models: \(choices)."
        case .noneAvailable(let agent):
            return "Bloom could not find an available model for \(agent.label)."
        }
    }
}
