import AppKit
import Foundation
import BloomCore

/// What the rest of macOS is told about the agents: the activity assertion while they are working,
/// and the dock badge once they have stopped.
///
/// Both come from the same place, so they are held by one object rather than two that could
/// disagree. A singleton because there is one process and one dock tile.
@MainActor
final class AgentActivity {
    static let shared = AgentActivity()

    /// The assertion, held only while at least one agent is mid turn. Nil is the normal state.
    ///
    /// It does two jobs, and they are two different bits of the same option set.
    ///
    /// **App Nap.** Without the assertion macOS naps Bloom the moment the user switches to their
    /// editor, which is exactly when the agents are streaming: timers coalesce, and the pumps that
    /// read the agent's stdout are throttled. That reads as an agent that has stalled. This half
    /// is not optional and is held whatever the sleep preference says, because a throttled pump is
    /// a bug rather than a taste.
    ///
    /// **Idle sleep.** `NSActivityUserInitiated` is `0xFFFFFF`, and
    /// `NSActivityIdleSystemSleepDisabled` is `1 << 20`, so the plain `.userInitiated` set has
    /// always carried it: measured with `pmset -g assertions`, a process holding
    /// `.userInitiated` owns a `PreventUserIdleSystemSleep`. That was never a decision anybody
    /// made, it came along with the App Nap fix, and it is what the sleep preference now controls
    /// deliberately. `.userInitiatedAllowingIdleSystemSleep` is the same set with that one bit
    /// cleared, which is why turning the preference off costs the App Nap protection nothing.
    ///
    /// **Not the display.** Neither set contains `NSActivityIdleDisplaySleepDisabled` (`1 << 40`),
    /// and nothing here adds it. Agents do not need the screen on, and a coding tool that quietly
    /// stops a laptop's display from ever sleeping is a battery complaint and a burn-in complaint
    /// waiting to be filed.
    ///
    /// It is released the moment the last agent finishes. An app that never naps is the same bad
    /// citizen from the other side: it would keep the machine awake through a whole idle afternoon.
    private var assertion: (any NSObjectProtocol)?

    /// What the held assertion was taken with, so a preference changed mid turn can be noticed and
    /// the assertion retaken. `beginActivity` has no way to widen or narrow one in place.
    private var heldOptions: ProcessInfo.ActivityOptions?

    private var runningCount = 0
    private var unreadCount = 0
    private var isBadgeEnabled = true
    private var preventsSleep = SleepPrevention.isOnByDefault

    private init() {
        // Belt and braces. The kernel drops every assertion a process owns when it exits, so a
        // crash cannot leave one behind (which is the entire reason this is not a `caffeinate`
        // child process). Quitting cleanly goes through `shutdownEverything`, which stops the
        // agents and drives the running count to zero through the reporter. This covers the gap
        // between those two: a quit that beats SwiftUI to the last update pass still releases
        // here, so the release is provable rather than inferred from process death.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AgentActivity.shared.releaseAssertion() }
        }
    }

    /// How many agents are mid turn. Idempotent, so the reporter can call it on every change
    /// without checking whether anything moved.
    ///
    /// This no longer touches the badge. A running agent is not news: the user started it, and it
    /// is on screen in the sidebar. What is news is the one that finished while they were in
    /// another app, which is what `setUnreadCount` counts.
    func setRunningCount(_ newCount: Int) {
        guard newCount != runningCount else { return }
        runningCount = newCount
        applyAssertion()
    }

    /// Whether the user wants the Mac held awake while agents work. See `SleepPrevention`.
    ///
    /// Applied immediately in both directions rather than at the next change of running count.
    /// Turning it off in the middle of a six agent run has to let the machine sleep now, which is
    /// the only moment somebody would think to reach for it.
    func setPreventsSleep(_ isOn: Bool) {
        guard isOn != preventsSleep else { return }
        preventsSleep = isOn
        applyAssertion()
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

    /// The one place the assertion is taken, retaken or dropped, so the three things that move it
    /// (an agent starting, the last one finishing, the preference changing) cannot each grow their
    /// own version of the rule.
    private func applyAssertion() {
        let wanted: ProcessInfo.ActivityOptions? = runningCount > 0 ? wantedOptions : nil
        guard wanted != heldOptions else { return }

        releaseAssertion()
        guard let wanted else { return }

        assertion = ProcessInfo.processInfo.beginActivity(
            options: wanted,
            // Shown verbatim by `pmset -g assertions`, so it is written for somebody looking at
            // that list wondering what is holding their Mac open.
            reason: "Coding agents are running"
        )
        heldOptions = wanted
    }

    private func releaseAssertion() {
        guard let held = assertion else { return }
        ProcessInfo.processInfo.endActivity(held)
        assertion = nil
        heldOptions = nil
    }

    private var wantedOptions: ProcessInfo.ActivityOptions {
        preventsSleep ? .userInitiated : .userInitiatedAllowingIdleSystemSleep
    }
}
