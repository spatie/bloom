import Foundation

/// Picker decisions shared by local Mac sessions and every remote client.
public struct ComposerModelChoices: Sendable {
    public var models: [AgentKind: [AgentModel]]
    public var availableAgents: [AgentKind]?

    public init(codexModels: [CodexModel] = [], availableAgents: [AgentKind]? = nil) {
        self.models = [.codex: codexModels.map(\.agentModel)]; self.availableAgents = availableAgents
    }

    public init(models: [AgentKind: [AgentModel]], availableAgents: [AgentKind]? = nil) {
        self.models = models; self.availableAgents = availableAgents
    }

    public func offers(_ kind: AgentKind) -> Bool { availableAgents?.contains(kind) ?? true }

    public func selecting(_ model: String, in controls: ComposerControls) -> ComposerControls {
        var selected = controls
        let identity = ModelIdentifier.resolve(model, models: models)
        selected.model = identity.model
        selected.agentKind = identity.kind ?? controls.agentKind
        selected.effort = resolvedEffort(controls.effort, for: selected.agentKind, model: selected.model)
        return selected
    }

    // MARK: - The menus

    /// The model menu: one section per backend that can actually run a chat, in `AgentKind` order.
    ///
    /// Cursor and OpenCode are detected and configurable and have no runner, so they are not here.
    /// A backend whose list has not arrived yet is left out rather than shown empty, because an
    /// empty section is a heading over nothing.
    public func sections(includingCurrent current: String, on kind: AgentKind) -> [ComposerModelSection] {
        let owner = backend(ofModel: current, current: kind)
        return AgentKind.allCases.filter { $0.canRunWorkspaces && offers($0) }.compactMap { backend in
            var options = self.options(for: backend)
            // Whatever this chat is set to stays on the list even when nothing recognises it: a
            // settings file can pin an id Bloom has never heard of, and a picker that dropped it
            // would be a one-way door out of the model actually in force.
            if backend == owner {
                options = ComposerOption.adding([current], to: options)
            }
            // After the pinned id is in, not before: `adding` puts whatever the chat is set to at
            // the end of the list, which is how `claude-opus-5[1m]` came to be drawn under Haiku.
            // Codex's list arrives ranked by `CodexModelRank`, so only this one needs sorting.
            if backend == .claudeCode {
                options = ComposerOption.ranked(options)
            }
            guard !options.isEmpty else { return nil }
            return ComposerModelSection(kind: backend, options: options)
        }
    }

    public func options(for kind: AgentKind) -> [ComposerOption] {
        if kind == .claudeCode { return ComposerOption.models }
        return (models[kind] ?? []).filter { !$0.hidden }
            .map { ComposerOption(id: $0.id, label: $0.displayName) }
    }

    /// Which backend a model id belongs to, so choosing one out of another section is understood
    /// as choosing that backend.
    ///
    /// The rule itself is `DefaultBackend`, in the core, because Settings, Models now asks the
    /// same question of a stored default and two answers to "whose model is this" is exactly the
    /// drift this file exists to avoid. An id nothing recognises belongs to whoever is running
    /// now, which is what keeps a pinned id from silently moving a chat to the other backend.
    public func backend(ofModel id: String, current: AgentKind) -> AgentKind {
        DefaultBackend.kind(ofModel: id, running: current, models: models)
    }

    /// The efforts one model takes.
    ///
    /// Claude Code's five are the same for every model. Codex's are the model's own, and a level
    /// the chosen model does not take is not on the list: offering `max` on `gpt-5.5`, which stops
    /// at `xhigh`, is offering something the server will refuse.
    public func efforts(for kind: AgentKind, model: String) -> [ComposerOption] {
        if kind == .claudeCode { return ComposerOption.efforts }
        guard let found = models[kind]?.first(where: { $0.id == model }) else {
            return kind == .codex ? ComposerOption.efforts : []
        }
        return found.supportedEfforts.map { ComposerOption(id: $0.id, label: $0.label) }
    }

    /// The effort to keep when the model changes underneath it, which is the model's own default
    /// rather than Bloom's `high`: `gpt-5.6-sol` defaults to `low` and `gpt-5.5` to `medium`.
    public func resolvedEffort(_ wanted: String, for kind: AgentKind, model: String) -> String {
        DefaultBackend.effort(wanted, on: kind, model: model, models: models)
    }
}
