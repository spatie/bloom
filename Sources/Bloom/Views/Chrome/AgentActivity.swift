import AppKit
import Foundation

/// What the rest of macOS is told while agents are working: the App Nap assertion and the dock
/// badge.
///
/// Both answer the same question, so they are held by one object rather than two that could
/// disagree. A singleton because there is one process and one dock tile.
@MainActor
final class AgentActivity {
    static let shared = AgentActivity()

    /// The assertion, held only while at least one agent is mid turn. Nil is the normal state.
    ///
    /// Without it macOS naps Bloom the moment the user switches to their editor, which is exactly
    /// when the agents are streaming: timers coalesce, and the pumps that read the agent's stdout
    /// are throttled. That reads as an agent that has stalled. `.userInitiated` rather than
    /// `.background`, because the turns really were started by hand and the user is waiting on
    /// them. It is released the moment the last agent finishes, because an app that never naps is
    /// the same bad citizen from the other side: it would keep the machine awake through a whole
    /// idle afternoon.
    private var assertion: (any NSObjectProtocol)?

    private var count = 0

    private init() {}

    /// How many agents are mid turn. Idempotent, so the reporter can call it on every change
    /// without checking whether anything moved.
    func setRunningCount(_ newCount: Int) {
        guard newCount != count else { return }
        count = newCount

        if newCount > 0, assertion == nil {
            assertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "Coding agents are running"
            )
        } else if newCount == 0, let held = assertion {
            ProcessInfo.processInfo.endActivity(held)
            assertion = nil
        }

        // Nil, never "0". An empty badge is a red dot on the dock icon saying nothing happened,
        // which is worse than no badge at all.
        NSApp?.dockTile.badgeLabel = newCount > 0 ? "\(newCount)" : nil
    }

    /// Whether the assertion is currently held. Reachable so the behaviour can be asserted on from
    /// outside rather than only reasoned about.
    var isHoldingActivityAssertion: Bool { assertion != nil }
}
