import Foundation
import Observation
import BloomCore

/// The one list of quick prompts the window draws, kept in step with the table behind it.
///
/// Shared rather than owned by the composer, for the reason `SlashCommandCatalog.shared` gives: the
/// centre pane is destroyed and rebuilt whenever the column changes tab, so a catalogue that came
/// with the composer would read the database again on every switch. There is one flat global list,
/// so unlike that one there is nothing to key it by.
///
/// Every edit is made against the store first and then applied here, so the list on screen is
/// whatever the row says rather than what the form hoped it would say. The writes are narrow:
/// `Store.update(quickPromptID:)` names the three columns a form can change and leaves the order
/// and the creation date alone.
@MainActor
@Observable
final class QuickPromptCatalog {
    static let shared = QuickPromptCatalog()

    private(set) var prompts: [QuickPrompt] = []
    /// Whether the first read has landed. The panel says something different before it than it does
    /// when the list is genuinely empty.
    private(set) var isLoaded = false

    /// The read that is already running, so a second composer opening its panel joins it rather
    /// than seeding the built-ins twice.
    private var loading: Task<Void, Never>?

    /// The subscription that keeps this list honest about writes it did not make.
    ///
    /// Every edit used to come through this type, so the list on screen and the table agreed by
    /// construction. The bridge's four `quick_prompt_*` tools broke that: they write the row
    /// directly, correctly, and this list would have gone on showing whatever it read when the
    /// panel was first opened for the rest of the session, because `load` returns early once
    /// `isLoaded` is set and nothing else re-read it.
    ///
    /// It reads and publishes and never writes, which is the first of the two rules on
    /// `StoreChangeHub`. Its own writes tick the hub and come back through here as one extra read
    /// of a table with a handful of rows in it, which is cheaper than working out how to skip them.
    private var watching: Task<Void, Never>?

    /// Reads the list, seeding the built-ins the first time this database has ever been asked.
    ///
    /// The seeding happens here rather than at launch because this is the only place the list is
    /// wanted, and it costs one settings lookup on a database that has already been seeded. See
    /// `Store.seedQuickPrompts` for why a deleted built-in does not come back.
    func load(from store: Store?) async {
        guard !isLoaded, let store else { return }
        if let loading {
            await loading.value
            return
        }
        let task = Task { @MainActor in
            let loaded = (try? await store.seedQuickPrompts()) ?? []
            prompts = loaded
            isLoaded = true
        }
        loading = task
        await task.value
        loading = nil
        watch(store)
    }

    /// Starts listening for writes to `quick_prompt` made anywhere else in this process.
    ///
    /// Once, after the first read, rather than at init: this type is a shared singleton built
    /// before there is a store to listen to, and the panel is the only thing that wants the list.
    private func watch(_ store: Store) {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            for await _ in store.changes(of: [.quickPrompts]) {
                guard let self else { return }
                await self.reload(from: store)
            }
        }
    }

    /// Re-reads the list, whatever state it is in. What an edit made in another window would need,
    /// and what the panel does when it is opened again.
    func reload(from store: Store?) async {
        guard let store else { return }
        prompts = (try? await store.quickPrompts()) ?? []
        isLoaded = true
    }

    @discardableResult
    func add(
        name: String, symbol: String, text: String, in store: Store?
    ) async -> QuickPrompt? {
        guard let store else { return nil }
        let prompt = QuickPrompt(name: name, symbol: symbol, text: text)
        guard let written = try? await store.insert(prompt) else { return nil }
        prompts.append(written)
        return written
    }

    @discardableResult
    func save(
        id: QuickPromptID, name: String, symbol: String, text: String, in store: Store?
    ) async -> QuickPrompt? {
        guard let store else { return nil }
        let changed = try? await store.update(quickPromptID: id) { prompt in
            prompt.name = name
            prompt.symbol = symbol
            prompt.text = text
        }
        guard let changed else { return nil }
        if let index = prompts.firstIndex(where: { $0.id == id }) {
            prompts[index] = changed
        }
        return changed
    }

    func delete(id: QuickPromptID, in store: Store?) async {
        guard let store else { return }
        try? await store.deleteQuickPrompt(id: id)
        prompts.removeAll { $0.id == id }
    }
}
