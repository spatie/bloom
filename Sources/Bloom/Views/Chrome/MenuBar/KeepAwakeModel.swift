import Foundation
import BloomCore

/// The one Keep Awake session, if there is one, and the timer that ends it.
///
/// Observable so the panel's card and the status item's menu read the same session. The rule for
/// what holds the assertion is `KeepAwake.holdsAwake` and the assertion itself is `AgentActivity`'s;
/// this only starts, stops and persists the session and hands it over.
@MainActor
@Observable
final class KeepAwakeModel {
    static let shared = KeepAwakeModel()

    private(set) var session: KeepAwakeSession?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    private init() {
        session = KeepAwake.load()
    }

    var isActive: Bool { session?.isActive(at: Date()) ?? false }

    /// Keep awake for a number of seconds, or until stopped when `seconds` is nil.
    func start(for seconds: TimeInterval?) {
        session = seconds.map { .lasting($0, from: Date()) } ?? .indefinitely(from: Date())
        apply()
    }

    func start(until date: Date) {
        session = KeepAwakeSession(startedAt: Date(), until: date)
        apply()
    }

    func stop() {
        session = nil
        apply()
    }

    /// Hands the saved session to the assertion again. Idempotent, for the launch path.
    func restore() {
        if let session, !session.isActive(at: Date()) { self.session = nil }
        apply()
    }

    private func apply() {
        KeepAwake.save(session)
        AgentActivity.shared.setKeepAwakeSession(session)
        expiry?.cancel()
        expiry = nil
        guard let until = session?.until else { return }
        // `Task.sleep(for:)` runs on the continuous clock, so a lid closed through the deadline
        // still ends the session the moment the Mac wakes rather than an hour late.
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
}
