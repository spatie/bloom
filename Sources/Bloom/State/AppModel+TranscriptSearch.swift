import Foundation
import BloomCore

/// Searching what the agents said, and getting the index that makes it possible built.
///
/// ## The backfill is behind everything
///
/// It starts at the end of `bootstrap`, after `isLoaded`, and nothing waits for it: a database
/// full of months of transcripts must not add a second to a launch, and an index that arrives a
/// few seconds late costs the user nothing because Home says so under the results while it works. One
/// batch at a time with a yield in between, so a turn arriving mid backfill queues behind a batch
/// rather than behind the whole of history, and the loop stops as soon as the store says it is
/// finished. Cancelling it (quitting) loses nothing: the cursor is committed with each batch, so
/// the next launch carries on from where this one stopped. See `Store.indexOlderTranscripts`.
///
/// ## The search itself is a database query, so it is not run on every keystroke
///
/// `WorkspaceSearch` runs over an array already in memory and can afford to be recomputed per
/// character. This cannot: it is a hop onto the store actor, an FTS5 match and a join. So the
/// keystroke schedules it and a short debounce swallows the ones behind it, and a query that
/// arrives while an older one is still running replaces it rather than queueing.
extension AppModel {
    /// Long enough to swallow a burst of typing, short enough that it reads as instant. Measured
    /// against the query itself, which comes back in single digit milliseconds on the owner's
    /// database, so this delay is nearly all of what the user experiences.
    static let transcriptSearchDebounce = Duration.milliseconds(120)

    func startTranscriptIndexBackfill() {
        transcriptBackfillTask?.cancel()
        transcriptBackfillTask = Task { [weak self] in
            guard let store = self?.store else { return }
            while !Task.isCancelled {
                guard let progress = try? await store.indexOlderTranscripts() else { return }
                self?.isTranscriptIndexIncomplete = !progress.isFinished
                if progress.isFinished { return }
                // A yield rather than a sleep. The store actor is the contended resource and it is
                // already handed back between batches; sleeping here would only make the index
                // take longer to become useful.
                await Task.yield()
            }
        }
    }

    /// Runs the transcript half of a search. The name and branch half is `HomeList.build`, over an
    /// array already in memory, so the two halves never wait for each other: the names are on
    /// screen before this has left the main actor.
    func searchTranscripts(_ query: String) {
        transcriptSearchTask?.cancel()
        guard TranscriptSearch.matchExpression(for: query) != nil else {
            transcriptResults = []
            return
        }

        transcriptSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.transcriptSearchDebounce)
            guard !Task.isCancelled, let store = self?.store else { return }
            let results = (try? await store.searchTranscripts(query)) ?? []
            guard !Task.isCancelled else { return }
            self?.transcriptResults = results
        }
    }

    /// Opens the workspace a result is in and asks its transcript to show the row that matched.
    ///
    /// **The target rather than just the workspace is what makes this worth having.** A workspace
    /// has several sessions and thousands of rows, and a search that dropped the reader at the
    /// live end of the wrong session would have found the answer and then hidden it again. The
    /// workspace's model picks the session up in `adopt`, and `TranscriptListView` scrolls to the
    /// row; both read the target and clear it, so it survives the load and fires once.
    func open(_ match: TranscriptMatch) async {
        pendingTranscriptTarget = TranscriptSearchTarget(
            workspaceID: match.workspaceID, sessionID: match.sessionID, seq: match.seq
        )

        // The session is chosen before the selection moves, and through the model rather than
        // through the target, because `reloadSessions` only overrules an active session that is
        // not in the list. Setting it first means the workspace opens on the right conversation
        // instead of opening on its first one and jumping.
        if let workspace = workspaces.first(where: { $0.id == match.workspaceID }) {
            model(for: workspace).activeSessionID = match.sessionID
            selection = .workspace(workspace.id)
            return
        }

        // An archived hit opens the reader, which is the same split Home's rows and the name
        // search make. Old work is most of what this feature is for, so this is the common path
        // rather than the exception.
        guard let archived = await archivedWorkspaces().first(where: { $0.id == match.workspaceID })
        else { return }
        model(for: archived).activeSessionID = match.sessionID
        openArchived(archived)
    }

    /// The target, if it is for this workspace, taken rather than read: whoever acts on it is the
    /// only one who should, and leaving it set would send the reader back there on every reload.
    func takeTranscriptTarget(for workspaceID: WorkspaceID) -> TranscriptSearchTarget? {
        guard let target = pendingTranscriptTarget, target.workspaceID == workspaceID else { return nil }
        pendingTranscriptTarget = nil
        return target
    }
}
