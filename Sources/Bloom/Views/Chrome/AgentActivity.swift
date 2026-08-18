import AppKit
import Foundation
import BloomCore

/// What the rest of macOS is told about the agents: the App Nap assertion while they are working,
/// and the dock badge once they have stopped.
///
/// Both come from the same place, so they are held by one object rather than two that could
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

    private var runningCount = 0
    private var unreadCount = 0
    private var isBadgeEnabled = true

    private init() {}

    /// How many agents are mid turn. Idempotent, so the reporter can call it on every change
    /// without checking whether anything moved.
    ///
    /// This no longer touches the badge. A running agent is not news: the user started it, and it
    /// is on screen in the sidebar. What is news is the one that finished while they were in
    /// another app, which is what `setUnreadCount` counts.
    func setRunningCount(_ newCount: Int) {
        guard newCount != runningCount else { return }
        runningCount = newCount

        if newCount > 0, assertion == nil {
            assertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "Coding agents are running"
            )
        } else if newCount == 0, let held = assertion {
            ProcessInfo.processInfo.endActivity(held)
            assertion = nil
        }
    }

    /// How many workspaces finished something nobody has read. See `DockBadge`.
    func setUnreadCount(_ newCount: Int) {
        guard newCount != unreadCount else { return }
        unreadCount = newCount
        applyBadge()
    }

    /// Whether the user wants a badge at all. Applied immediately in both directions: turning it
    /// off takes the badge away now rather than at the next change, and turning it back on puts
    /// the current count back rather than waiting for one.
    func setBadgeEnabled(_ isEnabled: Bool) {
        guard isEnabled != isBadgeEnabled else { return }
        isBadgeEnabled = isEnabled
        applyBadge()
    }

    private func applyBadge() {
        NSApp?.dockTile.badgeLabel = DockBadge.label(
            unread: unreadCount, isEnabled: isBadgeEnabled
        )
    }

    /// Whether the assertion is currently held. Reachable so the behaviour can be asserted on from
    /// outside rather than only reasoned about.
    var isHoldingActivityAssertion: Bool { assertion != nil }
}
