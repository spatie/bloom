import Foundation
import Observation

/// A create on a server, from the moment Create is pressed until the server answers.
///
/// **Why this is not a `Task` in the view.** It was, with a `defer` clearing a flag, and that is
/// the whole of why the window froze: nothing could reach the task to stop it, and nothing outside
/// the window knew there was one. The owner pressed Create on a server project and was left with a
/// greyed out form, a tiny spinner and no way out. Held here, the window's waiting screen can
/// cancel it, try it again, or close and leave it running: the task holds this object, so closing
/// the window does not end the create, and the new workspace is still selected when it lands.
///
/// **What Cancel does and does not do.** It cancels the client's request, which fails it at once
/// with "may still be running on the server". There is no cancel on the wire for a create, and the
/// server records a mutation before it starts, so work the server has already begun carries on and
/// a workspace that finishes appears in the sidebar. The window says so rather than implying the
/// server stopped. Try Again reuses the same request identity (`ServerWindowModel.perform` keeps an
/// uncertain request), so it returns the recorded outcome rather than creating a second workspace.
@MainActor
@Observable
final class RemoteWorkspaceCreation {
    /// When the attempt that is waiting began, or nil when nothing is.
    private(set) var startedAt: Date?
    var isRunning: Bool { startedAt != nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var work: (@MainActor () async throws -> Void)?
    @ObservationIgnored private var finished: (@MainActor (Error?) -> Void)?
    /// Which attempt's outcome is still wanted. A cancelled or replaced attempt still reaches the
    /// end of its task, and its failure ("the request was cancelled") must not become an alert.
    @ObservationIgnored private var attempt = 0

    func start(_ work: @escaping @MainActor () async throws -> Void, finished: @escaping @MainActor (Error?) -> Void) {
        guard task == nil else { return }
        self.work = work
        self.finished = finished
        run(after: nil)
    }

    /// Stops waiting, and returns the window to its form.
    func cancel() {
        attempt += 1
        task?.cancel()
        task = nil
        startedAt = nil
    }

    /// Asks again, once the attempt it replaces has let go of the connection. Starting at once
    /// would find `ServerWindowModel.isPerformingCommand` still set by the old request and fail
    /// with nothing to say.
    func retry() {
        let previous = task
        previous?.cancel()
        run(after: previous)
    }

    private func run(after previous: Task<Void, Never>?) {
        guard let work else { return }
        attempt += 1
        let current = attempt
        startedAt = Date()
        // Strong on purpose: this is what keeps the create alive after its window has closed.
        task = Task { [self] in
            await previous?.value
            var failure: Error?
            do { try await work() } catch { failure = error }
            guard current == attempt else { return }
            task = nil
            startedAt = nil
            finished?(failure)
        }
    }
}
