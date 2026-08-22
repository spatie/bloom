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
/// for the rest of the launch. Signing in through Bloom's own sheet does not wait for that: it
/// calls `check(force:)`, which throws the cached answer away.
@MainActor
@Observable
final class GitHubAvailability {
    static let shared = GitHubAvailability()

    /// The same three answers `GitHubAccess` gives, plus the one before anybody has asked.
    ///
    /// Not one `unavailable` case: a machine with no gh and a machine with gh signed out need
    /// different sentences and different buttons, and a view cannot write either from a boolean.
    enum State: Equatable {
        case unknown
        case ready
        case notInstalled
        case signedOut

        init(_ access: GitHubAccess) {
            switch access {
            case .ready: self = .ready
            case .notInstalled: self = .notInstalled
            case .signedOut: self = .signedOut
            }
        }

        /// Whether gh can be asked anything at all. `unknown` counts as usable, because the app is
        /// optimistic until the probe says otherwise: a button that flickers through a disabled
        /// state on every launch is worse than one that occasionally raises the sign in sheet.
        var isUsable: Bool { self != .notInstalled && self != .signedOut }
    }

    /// Readable from a view body, which is why it is a stored property rather than the result of
    /// the async probe.
    private(set) var state: State = .unknown

    /// How long a `gh auth status` answer is trusted. A positive answer is worth keeping for the
    /// session; a negative one has to expire, because the fix for it happens outside this app.
    private static let negativeLifetime = Duration.seconds(120)

    private var probe: Task<State, Never>?
    private var answeredAt: ContinuousClock.Instant?

    /// Coalesces callers: a dozen sidebar rows waking at once must not launch a dozen probes.
    func isReady() async -> Bool {
        await check() == .ready
    }

    /// The full answer, with the same coalescing and the same cache.
    ///
    /// - Parameter force: throw away a remembered answer and ask gh again. Used the moment a sign
    ///   in finishes, where waiting out the two minute expiry would mean asking the user to press
    ///   the button they just pressed.
    @discardableResult
    func check(force: Bool = false) async -> State {
        if force {
            probe?.cancel()
            probe = nil
            answeredAt = nil
        } else {
            if state == .ready { return .ready }
            if let answeredAt, answeredAt.duration(to: .now) < Self.negativeLifetime,
               !state.isUsable {
                return state
            }
            if let probe { return await probe.value }
        }

        let task = Task { State(await GitHubBridge.access()) }
        probe = task
        let answer = await task.value
        // Only the probe still on duty writes back. A forced check cancels the one in flight,
        // and cancellation makes `gh` read as signed out, so the original awaiter used to stamp
        // a stale `.signedOut` over the forced probe's `.ready` and tear down its coalescing.
        guard probe == task else { return answer }
        probe = nil
        answeredAt = .now
        state = answer
        return answer
    }
}

/// Kept with the type that uses it rather than in the bridge itself, because this is the one gh
/// call whose answer is a UI state rather than data.
extension GitHubBridge {
    static func access() async -> GitHubAccess {
        await GitHub.access()
    }

    static func isAvailable() async -> Bool {
        await GitHub.isAvailable()
    }
}
