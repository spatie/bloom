import SwiftUI
import BloomCore
import BloomClient

typealias ComposerModelSection = BloomClient.ComposerModelSection

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

    private var choices: ComposerModelChoices {
        ComposerModelChoices(models: models, availableAgents: availableAgents)
    }

    func sections(includingCurrent current: String, on kind: AgentKind) -> [ComposerModelSection] {
        choices.sections(includingCurrent: current, on: kind)
    }
    func options(for kind: AgentKind) -> [ComposerOption] { choices.options(for: kind) }
    func backend(ofModel id: String, current: AgentKind) -> AgentKind { choices.backend(ofModel: id, current: current) }
    func efforts(for kind: AgentKind, model: String) -> [ComposerOption] { choices.efforts(for: kind, model: model) }
    func resolvedEffort(_ wanted: String, for kind: AgentKind, model: String) -> String {
        choices.resolvedEffort(wanted, for: kind, model: model)
    }
    func selecting(_ model: String, in controls: ComposerControls) -> ComposerControls { choices.selecting(model, in: controls) }
}
