import Foundation

/// Which workspaces the six second refresh actually asks git about on this tick.
///
/// # The measurement that forced this
///
/// The loop used to walk every workspace on every tick. One pass over one worktree is six `git`
/// processes: `baseline` resolves the local base and the remote-tracking base, and `changedFiles`
/// then runs `diff --name-status`, `diff --numstat` and `ls-files --others`, each of which walks
/// the worktree. `IdleProbe` over seventeen of this machine's real worktrees, seven passes,
/// median: 104 processes and 2,864ms of process time for one pass.
///
/// **A pass every six seconds is therefore 48% of a core, continuously, on a machine where
/// nothing is happening.** That is what put Bloom under "Using Significant Energy" in the battery
/// menu, and it only runs while the window is frontmost, which is why the app looks innocent when
/// sampled from another application: measured in the background it was 0.1% of a core.
///
/// The same probe over the three worktrees a tick now hands it: 12 processes and 651ms, which is
/// 11% of a core. Nothing about one pass got faster; there are simply five times fewer of them.
///
/// # Why a tier rather than a longer interval
///
/// The six seconds are not wasted everywhere. A workspace with an agent writing in it changes
/// several times a minute, and the one on screen is the one whose numbers a reader is watching.
/// Those two keep the old cadence exactly. What was wrong was applying it to the rest, where the
/// only thing that can move the count is the user editing files outside Bloom, and a minute-old
/// number is indistinguishable from a six-second-old one.
///
/// # Why a slice rather than "every idle workspace, once a minute"
///
/// Letting them all come due together would trade a steady two seconds of process time per tick
/// for twenty seconds of it in one tick, ten times a minute apart, which is worse: the burst is
/// what a reader feels. So each tick takes the few oldest instead, sized so that one whole round
/// of the idle workspaces takes `idleMaxAge`. Twenty idle workspaces at a six second tick and a
/// sixty second age is two per tick.
///
/// A workspace nothing has asked about yet this launch is due immediately whatever the slice says.
/// That is one burst at launch, which the loop used to do on every tick anyway, and it is the
/// moment the stored counts are most likely to be stale: the machine may have been asleep for a
/// day and the worktrees edited from a terminal in between.
public enum DiffRefreshSchedule {
    /// How often the loop wakes.
    public static let tick: TimeInterval = 6

    /// How stale a workspace nothing is writing to is allowed to get.
    ///
    /// **Five minutes rather than one, because this is no longer how a change is noticed.**
    /// `WorktreeWatcher` reports a worktree the moment anything inside it is written, and the
    /// caller puts what it reports into `busy`, so a real edit is asked about on the next tick
    /// whatever this says. What is left for the age to cover is the cases the file system cannot
    /// tell us about: a volume FSEvents does not report on, and a stream that failed to start. A
    /// backstop wants to be cheap, not prompt.
    public static let idleMaxAge: TimeInterval = 300

    /// How stale the workspace on screen is allowed to get.
    ///
    /// Shorter than the backstop above and no longer every tick. The workspace somebody is looking
    /// at used to be refreshed on all of them, which is six or seven `git` processes every six
    /// seconds for as long as a window sits open on it, and every one of those runs answered "no
    /// change" on an idle worktree. The watcher answers that question for nothing, so what is left
    /// here is how long a reader could be looking at a stale number if the watcher ever missed
    /// one, and half a minute is short enough that nobody would notice it happening.
    public static let selectedMaxAge: TimeInterval = 30

    /// - Parameters:
    ///   - workspaces: every workspace the loop could ask about, in sidebar order.
    ///   - busy: the ones that keep the old cadence. The caller puts the workspaces with a running
    ///     agent, and the ones `WorktreeWatcher` says have changed, in here.
    ///   - selected: the workspace on screen, which is asked about on its own shorter age rather
    ///     than on every tick. Nil where nothing is selected.
    ///   - lastRefreshed: when each was last asked about, for this launch only. An absent entry
    ///     means never.
    /// - Returns: the workspaces to refresh on this tick, busy ones first.
    public static func due(
        workspaces: [WorkspaceID],
        busy: Set<WorkspaceID>,
        selected: WorkspaceID? = nil,
        lastRefreshed: [WorkspaceID: Date],
        now: Date,
        tick: TimeInterval = tick,
        idleMaxAge: TimeInterval = idleMaxAge,
        selectedMaxAge: TimeInterval = selectedMaxAge
    ) -> [WorkspaceID] {
        var due: [WorkspaceID] = []
        var stale: [(id: WorkspaceID, age: TimeInterval, place: Int)] = []

        for (place, id) in workspaces.enumerated() {
            if busy.contains(id) {
                due.append(id)
                continue
            }
            guard let last = lastRefreshed[id] else {
                due.append(id)
                continue
            }
            let age = now.timeIntervalSince(last)
            if id == selected {
                // The one on screen is never part of the trickle: it is due on its own age or not
                // at all, so a sidebar with twenty workspaces in it cannot push the workspace
                // somebody is reading to the back of a rotation.
                if age >= selectedMaxAge { due.append(id) }
                continue
            }
            guard age >= idleMaxAge else { continue }
            stale.append((id, age, place))
        }

        guard !stale.isEmpty else { return due }

        // Sized off every idle workspace rather than off the ones that have come due, so the slice
        // is a steady two or three rather than jumping about as a backlog drains. At least one,
        // because a sidebar of two workspaces would otherwise round down to none and never refresh.
        let idleCount = workspaces.count { !busy.contains($0) && $0 != selected }
        let perTick = max(1, Int((Double(idleCount) * tick / idleMaxAge).rounded(.up)))

        // Oldest first, so nothing at the back of a backlog is starved by a shorter list in front
        // of it. Sidebar order breaks a tie, because `sorted(by:)` is not stable and two
        // workspaces refreshed in the same tick have exactly equal ages: without the second key
        // the same input could answer two different ways, and a schedule that is not a function of
        // its input is one nothing can test.
        let oldest = stale
            .sorted { $0.age == $1.age ? $0.place < $1.place : $0.age > $1.age }
            .prefix(perTick)
        due.append(contentsOf: oldest.map(\.id))
        return due
    }
}
