import SwiftUI
import BloomCore

/// One backend's worth of the model menu.
struct ComposerModelSection: Identifiable, Equatable {
    var kind: AgentKind
    var options: [ComposerOption]

    var id: String { kind.rawValue }
    var title: String { kind.label }
}

/// What the composer's model and effort menus offer, per backend.
///
/// Claude Code's three are a list in the source, because the CLI has nothing to ask. **Codex's are
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

    // MARK: - The menus

    /// The model menu: one section per backend that can actually run a chat, in `AgentKind` order.
    ///
    /// Cursor and OpenCode are detected and configurable and have no runner, so they are not here.
    /// A backend whose list has not arrived yet is left out rather than shown empty, because an
    /// empty section is a heading over nothing.
    func sections(includingCurrent current: String, on kind: AgentKind) -> [ComposerModelSection] {
        let owner = backend(ofModel: current, current: kind)
        return AgentKind.allCases.filter(\.canRunWorkspaces).compactMap { backend in
            var options = self.options(for: backend)
            // Whatever this chat is set to stays on the list even when nothing recognises it: a
            // settings file can pin an id Bloom has never heard of, and a picker that dropped it
            // would be a one-way door out of the model actually in force.
            if backend == owner {
                options = ComposerOption.adding([current], to: options)
            }
            guard !options.isEmpty else { return nil }
            return ComposerModelSection(kind: backend, options: options)
        }
    }

    func options(for kind: AgentKind) -> [ComposerOption] {
        switch kind {
        case .claudeCode: ComposerOption.models
        case .codex: codexModels.map { ComposerOption(id: $0.id, label: $0.displayName) }
        case .cursor, .openCode: []
        }
    }

    /// Which backend a model id belongs to, so choosing one out of another section is understood
    /// as choosing that backend.
    func backend(ofModel id: String, current: AgentKind) -> AgentKind {
        for kind in AgentKind.allCases where kind.canRunWorkspaces {
            if options(for: kind).contains(where: { $0.id == id }) { return kind }
        }
        // An id nothing recognises belongs to whoever is running now, which is what keeps a pinned
        // id from silently moving a chat to the other backend.
        return current
    }

    /// The efforts one model takes.
    ///
    /// Claude Code's five are the same for every model. Codex's are the model's own, and a level
    /// the chosen model does not take is not on the list: offering `max` on `gpt-5.5`, which stops
    /// at `xhigh`, is offering something the server will refuse.
    func efforts(for kind: AgentKind, model: String) -> [ComposerOption] {
        switch kind {
        case .codex:
            guard let found = codexModels.first(where: { $0.id == model }) else {
                // Not yet fetched, or a pinned id. The flat list is the honest fallback: it is
                // what every one of these models has in common.
                return ComposerOption.efforts
            }
            return found.supportedEfforts.map { ComposerOption(id: $0.id, label: $0.label) }
        case .claudeCode, .cursor, .openCode:
            return ComposerOption.efforts
        }
    }

    /// The effort to keep when the model changes underneath it, which is the model's own default
    /// rather than Bloom's `high`: `gpt-5.6-sol` defaults to `low` and `gpt-5.5` to `medium`.
    func resolvedEffort(_ wanted: String, for kind: AgentKind, model: String) -> String {
        guard kind == .codex, let found = codexModels.first(where: { $0.id == model }) else {
            return wanted
        }
        return found.resolvedEffort(preferring: wanted)
    }
}
