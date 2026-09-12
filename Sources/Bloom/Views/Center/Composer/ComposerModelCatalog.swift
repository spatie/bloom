import SwiftUI
import BloomCore

/// One backend's worth of the model menu.
struct ComposerModelSection: Identifiable, Equatable {
    var kind: AgentKind
    var options: [ComposerOption]

    var id: String { kind.rawValue }
    var title: String { kind.label }
}

/// The composer and Settings share one discovery state. Backend sources supply common model
/// descriptions, so another fetched agent does not need its own array or loading branch here.
@MainActor
@Observable
final class ComposerModelCatalog {
    static let shared = ComposerModelCatalog()

    private(set) var availableAgents: [AgentKind]?
    private(set) var models: [AgentKind: [AgentModel]] = [:]
    private(set) var isLoading = false
    private(set) var lastFailure: String?

    private var sources: [AgentKind: AgentModelSource]
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()

    init(sources: [AgentKind: AgentModelSource] = AgentModelSource.live()) {
        self.sources = sources
    }

    func configure(store: Store) {
        Task { await ComposerPlanningSupport.shared.refresh(from: store) }
        sources = AgentModelSource.live(store: store)
        refresh()
    }

    func receive(_ models: [CodexModel], availableAgents: [AgentKind]? = nil) {
        // Remote discovery is authoritative. An earlier local fetch must not replace it.
        loadTask?.cancel()
        loadTask = nil
        loadGeneration = UUID()
        sources = [:]
        self.models = [.codex: models.map(\.agentModel)]
        self.availableAgents = availableAgents
        isLoading = false
        lastFailure = nil
    }

    func offers(_ kind: AgentKind) -> Bool { availableAgents?.contains(kind) ?? true }

    func load() {
        guard loadTask == nil else { return }
        let needed = AgentKind.runnable.filter { sources[$0] != nil && (models[$0] ?? []).isEmpty }
        guard !needed.isEmpty else { return }
        isLoading = true
        let generation = loadGeneration
        loadTask = Task { [sources] in
            var failure: String?
            for kind in needed {
                guard generation == self.loadGeneration else { return }
                guard let source = sources[kind] else { continue }
                do {
                    let fetched = try await source.models()
                    guard generation == self.loadGeneration else { return }
                    self.models[kind] = fetched
                } catch {
                    if failure == nil { failure = error.readableMessage }
                }
            }
            guard generation == self.loadGeneration else { return }
            self.lastFailure = failure
            self.isLoading = false
            self.loadTask = nil
        }
    }

    func refresh() {
        loadTask?.cancel()
        loadGeneration = UUID()
        let generation = loadGeneration
        models = [:]
        isLoading = true
        loadTask = Task { [sources] in
            for source in sources.values { await source.invalidate() }
            guard generation == self.loadGeneration else { return }
            self.loadTask = nil
            self.isLoading = false
            load()
        }
    }

    // MARK: - The menus

    /// The model menu: one section per backend that can actually run a chat, in `AgentKind` order.
    ///
    /// Cursor and OpenCode are detected and configurable and have no runner, so they are not here.
    /// A backend whose list has not arrived yet is left out rather than shown empty, because an
    /// empty section is a heading over nothing.
    func sections(includingCurrent current: String, on kind: AgentKind) -> [ComposerModelSection] {
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

    func options(for kind: AgentKind) -> [ComposerOption] {
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
    func backend(ofModel id: String, current: AgentKind) -> AgentKind {
        DefaultBackend.kind(
            ofModel: id,
            running: current,
            models: models
        )
    }

    /// The efforts one model takes.
    ///
    /// Claude Code's five are the same for every model. Codex's are the model's own, and a level
    /// the chosen model does not take is not on the list: offering `max` on `gpt-5.5`, which stops
    /// at `xhigh`, is offering something the server will refuse.
    func efforts(for kind: AgentKind, model: String) -> [ComposerOption] {
        guard kind != .claudeCode, let found = models[kind]?.first(where: { $0.id == model }) else {
            return ComposerOption.efforts
        }
        return found.supportedEfforts.map { ComposerOption(id: $0.id, label: $0.label) }
    }

    /// The effort to keep when the model changes underneath it, which is the model's own default
    /// rather than Bloom's `high`: `gpt-5.6-sol` defaults to `low` and `gpt-5.5` to `medium`.
    func resolvedEffort(_ wanted: String, for kind: AgentKind, model: String) -> String {
        DefaultBackend.effort(
            wanted,
            on: kind,
            model: model,
            models: models
        )
    }
}
