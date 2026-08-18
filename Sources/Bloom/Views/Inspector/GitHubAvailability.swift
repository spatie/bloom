import SwiftUI
import Observation
import BloomCore

/// Whether gh is installed and signed in.
///
/// Every gh call in the app is a subprocess, and on a machine without gh, or with gh signed out,
/// every one of them fails the same way after paying for a process launch. Asking once and
/// remembering the answer is what lets the sidebar and the inspector show a quiet honest state
/// instead of a stack of shell errors.
///
/// The answer is not permanent. `gh auth login` in a terminal is a normal thing to do while
/// Bloom is open, so a negative answer expires and is asked again rather than disabling GitHub
/// for the rest of the launch.
@MainActor
@Observable
final class GitHubAvailability {
    static let shared = GitHubAvailability()

    enum State: Equatable {
        case unknown
        case ready
        case unavailable
    }

    /// Readable from a view body, which is why it is a stored property rather than the result of
    /// the async probe.
    private(set) var state: State = .unknown

    /// How long a `gh auth status` answer is trusted. A positive answer is worth keeping for the
    /// session; a negative one has to expire, because the fix for it happens outside this app.
    private static let negativeLifetime = Duration.seconds(120)

    private var probe: Task<Bool, Never>?
    private var answeredAt: ContinuousClock.Instant?

    /// Coalesces callers: a dozen sidebar rows waking at once must not launch a dozen probes.
    func isReady() async -> Bool {
        if state == .ready { return true }
        if let answeredAt, answeredAt.duration(to: .now) < Self.negativeLifetime, state == .unavailable {
            return false
        }
        if let probe { return await probe.value }

        let task = Task { await GitHubBridge.isAvailable() }
        probe = task
        let available = await task.value
        probe = nil
        answeredAt = .now
        state = available ? .ready : .unavailable
        return available
    }
}

/// Kept with the type that uses it rather than in the bridge itself, because this is the one gh
/// call whose answer is a UI state rather than data.
extension GitHubBridge {
    static func isAvailable() async -> Bool {
        await GitHub.isAvailable()
    }
}
