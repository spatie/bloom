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
    @ObservationIgnored private var wasHoldingLidClosed = false

    private init() {
        session = KeepAwake.load()
    }

    var isActive: Bool { session?.isActive(at: Date()) ?? false }

    /// Whether a session should hold the Mac open with the lid shut. See `KeepAwake.lidKey`: this
    /// is the only part of Keep Awake that no assertion can do, so it is the only part that needs
    /// a privileged helper.
    var keepsLidClosed: Bool {
        get { UserDefaults.standard.bool(forKey: KeepAwake.lidKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: KeepAwake.lidKey)
            // Asking is what registers the daemon and, the first time, what sends somebody to
            // System Settings to allow it.
            if newValue { Task { await SleepSwitch.shared.enable() } }
            apply()
        }
    }

    /// Keep awake for a number of seconds, or until stopped when `seconds` is nil.
    func start(for seconds: TimeInterval?) {
        session = seconds.map { .lasting($0, from: Date()) } ?? .indefinitely(from: Date())
        apply()
    }

    /// Pushes a running session's end back. Nothing to do for one that has no end.
    func extend(by seconds: TimeInterval) {
        guard let session, session.isActive(at: Date()) else { return }
        self.session = session.extended(by: seconds, at: Date())
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
        // The lid is the one part no assertion can hold. Checking the helper's service status
        // blocked the main thread twice at launch even with no Keep Awake session. The helper
        // watches the requesting process and releases a hold if it exits, so a fresh launch with
        // no hold has nothing to clear. Once this process has asked for a hold, it must still send
        // the matching release.
        let holdsLidClosed = KeepAwake.holdsLidClosed(
            session: session, lidEnabled: keepsLidClosed, at: Date()
        )
        if holdsLidClosed || wasHoldingLidClosed {
            SleepSwitch.shared.setHoldingLidClosed(holdsLidClosed)
        }
        wasHoldingLidClosed = holdsLidClosed
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
