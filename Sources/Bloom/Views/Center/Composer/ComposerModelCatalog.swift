import SwiftUI
import BloomCore
import BloomClient

typealias ComposerModelSection = BloomClient.ComposerModelSection

/// What the composer's model and effort menus offer, per backend.
///
/// Claude Code's four are a list in the source, because the CLI has nothing to ask. **Codex's are
/// fetched**, because `model/list` is a real call that answers without an account, because each
/// model brings its own set of reasoning efforts (six for `gpt-5.6-sol`, four for `gpt-5.5`), and
/// because a list written down goes stale between releases: Conductor's hardcoded one still names
/// `gpt-5.4`, which no longer exists, and has none of the three current models.
///
/// A shared object rather than state on the footer, because `ViewThatFits` builds that row three
/// times and three copies would be three fetches. It starts empty and fills in, so a menu opened
/// in the first second shows Claude Code's section alone rather than nothing, and the Codex
/// section arrives without anything having to be reopened.
@MainActor
@Observable
final class ComposerModelCatalog {
    static let shared = ComposerModelCatalog()

    private(set) var availableAgents: [AgentKind]?
    private(set) var codexModels: [CodexModel] = []
    private(set) var isLoading = false
    /// Set when a fetch failed, so a menu can say why its section is short rather than pretending
    /// the account has one model.
    private(set) var lastFailure: String?

    private let catalog: CodexModelCatalog
    private var loadTask: Task<Void, Never>?

    init(catalog: CodexModelCatalog = CodexModelCatalog.live()) {
        self.catalog = catalog
    }

    func receive(_ models: [CodexModel], availableAgents: [AgentKind]? = nil) {
        codexModels = models; self.availableAgents = availableAgents; lastFailure = nil
    }

    func offers(_ kind: AgentKind) -> Bool { availableAgents?.contains(kind) ?? true }

    /// Fetches once, and again only after `refresh()`. Cheap to call on every menu appearance,
    /// which is exactly how the footer calls it.
    func load() {
        guard loadTask == nil, codexModels.isEmpty else { return }
        isLoading = true
        loadTask = Task { [catalog] in
            do {
                let models = try await catalog.pickerModels()
                self.codexModels = models
                self.lastFailure = nil
            } catch {
                // Not an alert. A model menu that cannot reach the CLI is a menu with one section
                // in it, and the section that is there still works.
                self.lastFailure = error.readableMessage
            }
            self.isLoading = false
            self.loadTask = nil
        }
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = nil
        codexModels = []
        Task { await catalog.invalidate(); load() }
    }

    private var choices: ComposerModelChoices {
        ComposerModelChoices(codexModels: codexModels, availableAgents: availableAgents)
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
