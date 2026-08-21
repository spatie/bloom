import Foundation

/// Makes one piece of asynchronous work non-reentrant: a caller that arrives while it is already
/// under way waits for the run in flight rather than starting a second one.
///
/// This exists because of a transcript that would only draw its prose while the scroller was being
/// dragged, and went blank again the moment it was let go. `TranscriptModel.load()` is reached from
/// two places, and has been since the app layer was first written: the workspace reads a session
/// eagerly the moment it builds a model for it, and the list view reads it again from its own task
/// when the pane draws. Both used to run the whole read. That was survivable while emptying the row
/// list and refilling it was one synchronous block, because the second reader simply rebuilt what
/// the first had built. The moment an await went in the middle of that block, both readers emptied
/// the list and then both filled it: sixteen rows for eight messages, duplicate identifiers under a
/// `ForEach`, and a lazy stack that laid out whichever of them it liked.
///
/// A flag on the work itself cannot close that gap, because a flag saying "this has been done" can
/// only be raised on the last line, and both callers are already past the guard by then. Holding on
/// to the task is what closes it, since a task exists from the first line rather than the last.
///
/// Deliberately coalescing rather than replacing. The second caller is handed the first run's
/// outcome and no second run happens at all, which is the right answer when both callers are asking
/// the same question of the same data, and that is the only case here. Work whose newest caller
/// carries fresh arguments wants cancel and restart instead, and should not be built on this.
@MainActor
public final class SingleFlight {
    private var task: Task<Void, Never>?

    public init() {}

    /// Runs `work`, or, when a run is already under way, returns once that run has finished.
    public func run(_ work: @escaping @Sendable @MainActor () async -> Void) async {
        if let task {
            await task.value
            return
        }

        let task = Task { await work() }
        self.task = task
        await task.value
        // Cleared only when it is still the run this call started. Nothing can put a second run in
        // the slot while this one is in flight, which is the whole point of the type, but a caller
        // that starts a fresh run the instant this one ends must not have it wiped by the call
        // that is on its way out.
        if self.task == task { self.task = nil }
    }

    /// Returns once any run under way has finished, and returns at once when there is none.
    ///
    /// For the caller that must not start the work itself but must not act on half of its results
    /// either. `TranscriptModel` appends rows arriving from the agent's event stream, and appending
    /// to a list that the first read is still building is how the read comes to overwrite them.
    public func wait() async {
        await task?.value
    }
}
