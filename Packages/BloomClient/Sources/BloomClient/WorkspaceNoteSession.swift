import Foundation
import Observation

/// Shared editing lifetime. Views supply transport adapters, never their own debounce or writer.
@MainActor @Observable
public final class WorkspaceNoteSession {
    public typealias Read = @MainActor () async throws -> String
    public typealias Write = @MainActor (String) async throws -> Void
    public private(set) var text: String
    public private(set) var baseline: String?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    public private(set) var draftError: String?
    public var canEdit: Bool { baseline != nil }
    public var hasChanges: Bool { WorkspaceNote.needsSave(stored: baseline, typed: text) }
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    public func observe(_ changed: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = changed; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
    private func notify() { for observer in Array(observers.values) { observer() } }

    private let persist: (String?, String?) throws -> Void
    private var hasDraft: Bool
    private var editRevision = 0
    private var readGeneration = 0
    private var loading: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    init(text: String?, baseline: String?, persist: @escaping (String?, String?) throws -> Void) {
        self.text = text ?? ""; self.baseline = baseline; self.persist = persist; hasDraft = text != nil
    }

    public func load(using read: @escaping Read) async {
        if let loading { await loading.value; return }
        guard !isSaving else { return }
        readGeneration += 1
        let generation = readGeneration, revision = editRevision
        isLoading = true; loadError = nil; notify()
        let task = Task { @MainActor [self] in
            defer { if generation == readGeneration { isLoading = false; loading = nil; notify() } }
            do {
                let stored = try await read()
                guard !Task.isCancelled, generation == readGeneration else { return }
                if !hasDraft, editRevision == revision { text = stored }
                baseline = stored
                if hasDraft || editRevision != revision { persistCurrentDraft() }
                loadError = nil
            } catch {
                if !Task.isCancelled, generation == readGeneration { loadError = error.localizedDescription }
            }
        }
        loading = task
        // A pane is a subscriber, not the owner of this shared read. Hiding it must not
        // cancel another pane’s initial load. A newer save still invalidates the read above.
        await task.value
    }

    /// Import a previous device-only draft without replacing a newer shared-session edit.
    public func importLegacyDraft(_ value: String) {
        guard !hasDraft, editRevision == 0 else { return }
        text = value; hasDraft = true; editRevision += 1
        persistCurrentDraft(); notify()
    }

    public func edit(_ value: String, using write: @escaping Write) {
        guard canEdit, value != text else { return }
        text = value; hasDraft = true; editRevision += 1
        persistCurrentDraft(); notify()
        debounce?.cancel()
        guard draftError == nil else { return }
        debounce = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: WorkspaceNote.autosaveDelay) } catch { return }
            self?.save(using: write)
        }
    }

    /// One writer drains the latest draft. Leaving a pane may request a flush, never a second writer.
    public func save(using write: @escaping Write) {
        debounce?.cancel(); debounce = nil
        guard canEdit, hasChanges else { return }
        persistCurrentDraft()
        guard draftError == nil, saving == nil else { notify(); return }
        readGeneration += 1; loading?.cancel(); loading = nil; isLoading = false
        isSaving = true; saveError = nil; notify()
        saving = Task { @MainActor [self] in
            defer { isSaving = false; saving = nil; notify() }
            while hasChanges {
                persistCurrentDraft()
                guard draftError == nil else { return }
                let submitted = text
                guard submitted.utf8.count <= 1_048_576 else { saveError = "Notes exceed 1 MB. Your draft stays on this device."; return }
                do {
                    try await write(WorkspaceNote.storable(submitted))
                    // New text typed during I/O is still a draft. Only its baseline advances.
                    baseline = WorkspaceNote.storable(submitted)
                    saveError = nil
                    persistCurrentDraft()
                    notify()
                } catch {
                    saveError = error.localizedDescription
                    return
                }
            }
        }
    }

    /// Useful for an explicit flush and deterministic tests; it does not cancel a durable write.
    public func waitForSave() async { await saving?.value }

    private func persistCurrentDraft() {
        do {
            let dirty = baseline == nil || hasChanges
            try persist(dirty ? text : nil, baseline)
            hasDraft = dirty
            draftError = nil
        } catch { draftError = "Could not save the draft on this device: " + error.localizedDescription }
    }
}
